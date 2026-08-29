package aithing

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import wl "./wayland"

// The Wayland clipboard, spoken directly. Whoever owns the selection announces
// an offer with a list of mime types; to read it you hand the offer a pipe and
// the type you want, then read until the other end hangs up. Pasting an image
// is the same dance with `image/png` instead of `text/plain`.

TEXT_MIMES :: [?]string{"text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING"}
IMAGE_MIMES :: [?]string{"image/png", "image/jpeg", "image/webp", "image/bmp"}

@(private = "file")
g_clip_ctx: runtime.Context

@(private = "file")
data_device_listener: wl.wl_data_device_listener
@(private = "file")
data_offer_listener: wl.wl_data_offer_listener
@(private = "file")
data_source_listener: wl.wl_data_source_listener

clipboard_init :: proc(w: ^Window) {
	if w.data_manager == nil || w.seat == nil do return
	g_clip_ctx = context

	data_offer_listener = {
		offer = proc "c" (data: rawptr, self: ^wl.wl_data_offer, mime_type: cstring) {
			context = g_clip_ctx
			w := cast(^Window)data
			append(&w.pending_mimes, strings.clone(string(mime_type)))
		},
		source_actions = proc "c" (data: rawptr, self: ^wl.wl_data_offer, actions: u32) {},
		action = proc "c" (data: rawptr, self: ^wl.wl_data_offer, action: u32) {},
	}

	data_device_listener = {
		data_offer = proc "c" (data: rawptr, self: ^wl.wl_data_device, id: ^wl.wl_data_offer) {
			context = g_clip_ctx
			w := cast(^Window)data
			// A fresh offer starts a fresh mime list; the types arrive next.
			clear_mimes(&w.pending_mimes)
			w.pending_offer = id
			wl.wl_data_offer_add_listener(id, &data_offer_listener, w)
		},
		selection = proc "c" (data: rawptr, self: ^wl.wl_data_device, id: ^wl.wl_data_offer) {
			context = g_clip_ctx
			w := cast(^Window)data
			if w.offer != nil do wl.wl_data_offer_destroy(w.offer)
			clear_mimes(&w.offer_mimes)
			w.offer = id
			if id != nil && id == w.pending_offer {
				w.offer_mimes, w.pending_mimes = w.pending_mimes, w.offer_mimes
			}
			w.pending_offer = nil
		},
		enter = proc "c" (data: rawptr, self: ^wl.wl_data_device, serial: u32, surface: ^wl.wl_surface, x, y: wl.Fixed, id: ^wl.wl_data_offer) {},
		leave = proc "c" (data: rawptr, self: ^wl.wl_data_device) {},
		motion = proc "c" (data: rawptr, self: ^wl.wl_data_device, time: u32, x, y: wl.Fixed) {},
		drop = proc "c" (data: rawptr, self: ^wl.wl_data_device) {},
	}

	w.data_device = wl.wl_data_device_manager_get_data_device(w.data_manager, w.seat)
	wl.wl_data_device_add_listener(w.data_device, &data_device_listener, w)
}

@(private = "file")
clear_mimes :: proc(list: ^[dynamic]string) {
	for m in list do delete(m)
	clear(list)
}

clipboard_has :: proc(w: ^Window, mimes: []string) -> (string, bool) {
	if w.offer == nil do return "", false
	for want in mimes {
		for have in w.offer_mimes {
			if have == want do return want, true
		}
	}
	return "", false
}

// Reads the selection as `mime`. Blocks until the owner is done writing, which
// for a clipboard-sized payload is immediate; a pathological owner that never
// writes would stall the window, so the read gives up after a second.
clipboard_read :: proc(w: ^Window, mime: string) -> ([]byte, bool) {
	if w.offer == nil do return nil, false

	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE do return nil, false
	defer linux.close(fds[0])

	cmime := strings.clone_to_cstring(mime, context.temp_allocator)
	wl.wl_data_offer_receive(w.offer, cmime, i32(fds[1]))
	wl.display_flush(w.display)
	linux.close(fds[1]) // the compositor holds the only writer now

	out := make([dynamic]byte)
	buf: [64 * 1024]byte
	for {
		poll_fds := []linux.Poll_Fd{{fd = fds[0], events = {.IN}}}
		n, perr := linux.poll(poll_fds, 1000)
		if perr != .NONE || n <= 0 do break
		got, rerr := linux.read(fds[0], buf[:])
		if rerr != .NONE || got <= 0 do break
		append(&out, ..buf[:got])
	}
	if len(out) == 0 {
		delete(out)
		return nil, false
	}
	return out[:], true
}

clipboard_text :: proc(w: ^Window) -> (string, bool) {
	mimes := TEXT_MIMES
	mime, ok := clipboard_has(w, mimes[:])
	if !ok do return "", false
	data, read_ok := clipboard_read(w, mime)
	if !read_ok do return "", false
	return string(data), true
}

// The pasted image, still encoded; the caller decodes it for a thumbnail and
// writes it somewhere Claude can read.
clipboard_image :: proc(w: ^Window) -> (data: []byte, mime: string, ok: bool) {
	mimes := IMAGE_MIMES
	mime, ok = clipboard_has(w, mimes[:])
	if !ok do return nil, "", false
	data, ok = clipboard_read(w, mime)
	return
}

// Takes ownership of the selection and serves `text` to whoever asks for it.
clipboard_set_text :: proc(w: ^Window, text: string) {
	if w.data_device == nil || w.data_manager == nil do return

	if w.copy_source != nil do wl.wl_data_source_destroy(w.copy_source)
	delete(w.copy_text)
	w.copy_text = strings.clone(text)

	data_source_listener = {
		send = proc "c" (data: rawptr, self: ^wl.wl_data_source, mime_type: cstring, fd: i32) {
			context = g_clip_ctx
			w := cast(^Window)data
			bytes := transmute([]byte)w.copy_text
			for sent := 0; sent < len(bytes); {
				n, err := linux.write(linux.Fd(fd), bytes[sent:])
				if err != .NONE || n <= 0 do break
				sent += n
			}
			linux.close(linux.Fd(fd))
		},
		cancelled = proc "c" (data: rawptr, self: ^wl.wl_data_source) {
			context = g_clip_ctx
			w := cast(^Window)data
			if w.copy_source == self {
				wl.wl_data_source_destroy(self)
				w.copy_source = nil
			}
		},
		target = proc "c" (data: rawptr, self: ^wl.wl_data_source, mime_type: cstring) {},
		dnd_drop_performed = proc "c" (data: rawptr, self: ^wl.wl_data_source) {},
		dnd_finished = proc "c" (data: rawptr, self: ^wl.wl_data_source) {},
		action = proc "c" (data: rawptr, self: ^wl.wl_data_source, dnd_action: u32) {},
	}

	w.copy_source = wl.wl_data_device_manager_create_data_source(w.data_manager)
	wl.wl_data_source_add_listener(w.copy_source, &data_source_listener, w)
	for m in TEXT_MIMES {
		wl.wl_data_source_offer(w.copy_source, strings.clone_to_cstring(m, context.temp_allocator))
	}
	wl.wl_data_device_set_selection(w.data_device, w.copy_source, w.serial)
	wl.display_flush(w.display)
}
