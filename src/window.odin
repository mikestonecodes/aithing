package aithing

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"
import "core:time"
import wl "./wayland"

BTN_LEFT :: 0x110
BTN_RIGHT :: 0x111
BTN_MIDDLE :: 0x112

Mod :: enum {
	Shift,
	Ctrl,
	Alt,
	Super,
}
Mods :: bit_set[Mod]

// A key as the UI sees it: the evdev code plus whatever was held with it.
Key :: struct {
	code: u32,
	mods: Mods,
}

Input :: struct {
	mouse:        [2]f32,
	has_mouse:    bool,
	down:         [3]bool,
	pressed:      [3]bool,
	released:     [3]bool,
	click_count:  int, // 2 on a double click, 3 on a triple
	// Wheel notches (~10 per click, so a click scrolls a few rows) and the
	// pixels a touchpad travelled, which move content 1:1. Both axes: a
	// touchpad swiped sideways is how a canvas gets panned.
	scroll:       f32,
	scroll_px:    f32,
	scroll_x:     f32,
	scroll_x_px:  f32,
	// The compositor says when the fingers left the touchpad, which is the
	// only honest moment to turn their speed into a glide.
	scroll_end:   bool,
	// Keys that fired this frame, including synthesised repeats, and the text
	// they produced. Both are cleared at the top of every poll.
	keys:         [dynamic]Key,
	text:         [dynamic]u8,
	// Where in `text` this frame's synthesised repeats start: everything from
	// here on is a key still being held rather than a key pressed again. A
	// held key is one press, and the grid has to be able to tell the two
	// apart — see grid_command.
	repeat_at:    int,
	mods:         Mods,
}

Window :: struct {
	display:      ^wl.wl_display,
	registry:     ^wl.wl_registry,
	compositor:   ^wl.wl_compositor,
	wm_base:      ^wl.xdg_wm_base,
	seat:         ^wl.wl_seat,
	deco_manager: ^wl.zxdg_decoration_manager_v1,
	blur_manager: ^wl.ext_background_effect_manager_v1,
	blur_surface: ^wl.ext_background_effect_surface_v1,

	surface:      ^wl.wl_surface,
	xdg_surface:  ^wl.xdg_surface,
	toplevel:     ^wl.xdg_toplevel,
	decoration:   ^wl.zxdg_toplevel_decoration_v1,
	pointer:      ^wl.wl_pointer,
	keyboard:     ^wl.wl_keyboard,
	data_manager: ^wl.wl_data_device_manager,
	data_device:  ^wl.wl_data_device,

	// The clipboard, as offered by whoever owns the selection. The mime list
	// arrives before the offer itself is announced as the selection, so it is
	// accumulated on the pending offer and swapped over on `selection`.
	offer:         ^wl.wl_data_offer,
	offer_mimes:   [dynamic]string,
	pending_offer: ^wl.wl_data_offer,
	pending_mimes: [dynamic]string,
	copy_source:  ^wl.wl_data_source,
	copy_text:    string,
	serial:       u32, // most recent input serial, for set_selection

	// Key repeat. The compositor tells us the rate it wants; we synthesise the
	// repeats ourselves because nothing else is watching the key.
	keymap:       Keymap, // what the compositor says the keys mean
	repeat_key:   Key,
	repeat_rate:  f64, // keys per second, 0 disables
	repeat_delay: f64, // seconds before the first repeat
	repeat_next:  time.Time,
	last_click:   time.Time,
	click_count:  int,

	// Sizes are logical (what xdg-shell configures); multiply by scale for the
	// pixel size the swapchain and the UI actually work in.
	width:        int,
	height:       int,
	new_width:    int,
	new_height:   int,
	scale:        int,
	configured:   bool,
	resized:      bool,
	should_close: bool,
	input:        Input,
	last_mouse:   [2]f32,

	// Outstanding wl_surface.frame request: the compositor answers it when it
	// is ready for the next frame, which is what paces animations.
	frame_cb:     ^wl.wl_callback,
	axis_source:  u32,
}

@(private = "file")
g_win_ctx: runtime.Context

@(private = "file")
registry_listener: wl.wl_registry_listener
@(private = "file")
wm_base_listener: wl.xdg_wm_base_listener
@(private = "file")
xdg_surface_listener: wl.xdg_surface_listener
@(private = "file")
toplevel_listener: wl.xdg_toplevel_listener
@(private = "file")
surface_listener: wl.wl_surface_listener
@(private = "file")
seat_listener: wl.wl_seat_listener
@(private = "file")
pointer_listener: wl.wl_pointer_listener
@(private = "file")
keyboard_listener: wl.wl_keyboard_listener
@(private = "file")
frame_listener: wl.wl_callback_listener

window_open :: proc(w: ^Window, title: string, width, height: int) -> bool {
	g_win_ctx = context
	g_log_keys = os.get_env("AITHING_KEYS", context.temp_allocator) != ""
	w.width, w.height = width, height
	w.scale = 1

	w.display = wl.display_connect(nil)
	if w.display == nil {
		fmt.eprintln("cannot connect to a Wayland compositor (is WAYLAND_DISPLAY set?)")
		return false
	}

	registry_listener = {
		global        = on_global,
		global_remove = proc "c" (data: rawptr, self: ^wl.wl_registry, name: u32) {},
	}
	w.registry = wl.wl_display_get_registry(w.display)
	wl.wl_registry_add_listener(w.registry, &registry_listener, w)
	wl.display_roundtrip(w.display)

	if w.compositor == nil || w.wm_base == nil {
		fmt.eprintln("compositor is missing wl_compositor or xdg_wm_base")
		return false
	}

	clipboard_init(w)

	wm_base_listener = {
		ping = proc "c" (data: rawptr, self: ^wl.xdg_wm_base, serial: u32) {
			wl.xdg_wm_base_pong(self, serial)
		},
	}
	wl.xdg_wm_base_add_listener(w.wm_base, &wm_base_listener, w)

	w.surface = wl.wl_compositor_create_surface(w.compositor)
	surface_listener = {
		enter = proc "c" (data: rawptr, self: ^wl.wl_surface, output: ^wl.wl_output) {},
		leave = proc "c" (data: rawptr, self: ^wl.wl_surface, output: ^wl.wl_output) {},
		preferred_buffer_scale = proc "c" (data: rawptr, self: ^wl.wl_surface, factor: i32) {
			win := cast(^Window)data
			if factor < 1 || int(factor) == win.scale do return
			win.scale = int(factor)
			wl.wl_surface_set_buffer_scale(self, factor)
			win.resized = true
		},
		preferred_buffer_transform = proc "c" (data: rawptr, self: ^wl.wl_surface, transform: u32) {},
	}
	wl.wl_surface_add_listener(w.surface, &surface_listener, w)
	w.xdg_surface = wl.xdg_wm_base_get_xdg_surface(w.wm_base, w.surface)

	xdg_surface_listener = {
		configure = proc "c" (data: rawptr, self: ^wl.xdg_surface, serial: u32) {
			win := cast(^Window)data
			wl.xdg_surface_ack_configure(self, serial)
			if win.new_width > 0 && win.new_height > 0 {
				if win.new_width != win.width || win.new_height != win.height {
					win.width, win.height = win.new_width, win.new_height
					win.resized = true
				}
			}
			win.configured = true
		},
	}
	wl.xdg_surface_add_listener(w.xdg_surface, &xdg_surface_listener, w)

	w.toplevel = wl.xdg_surface_get_toplevel(w.xdg_surface)
	toplevel_listener = {
		configure = proc "c" (data: rawptr, self: ^wl.xdg_toplevel, width, height: i32, states: ^wl.Array) {
			win := cast(^Window)data
			win.new_width, win.new_height = int(width), int(height)
		},
		close = proc "c" (data: rawptr, self: ^wl.xdg_toplevel) {
			(cast(^Window)data).should_close = true
		},
		configure_bounds = proc "c" (data: rawptr, self: ^wl.xdg_toplevel, width, height: i32) {},
		wm_capabilities = proc "c" (data: rawptr, self: ^wl.xdg_toplevel, capabilities: ^wl.Array) {},
	}
	wl.xdg_toplevel_add_listener(w.toplevel, &toplevel_listener, w)

	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	wl.xdg_toplevel_set_title(w.toplevel, ctitle)
	wl.xdg_toplevel_set_app_id(w.toplevel, "aithing")

	// Ask for server-side decorations so we don't have to draw a title bar.
	if w.deco_manager != nil {
		w.decoration = wl.zxdg_decoration_manager_v1_get_toplevel_decoration(
			w.deco_manager,
			w.toplevel,
		)
		wl.zxdg_toplevel_decoration_v1_set_mode(
			w.decoration,
			wl.zxdg_toplevel_decoration_v1_mode_server_side,
		)
	}

	// Blur whatever shows through the window. The region is not optional: a
	// NULL one removes the effect rather than covering everything, so hand it
	// a rectangle far larger than the window and let the compositor clip it —
	// that way it stays right across every resize without being reset.
	if w.blur_manager != nil {
		w.blur_surface = wl.ext_background_effect_manager_v1_get_background_effect(
			w.blur_manager,
			w.surface,
		)
		region := wl.wl_compositor_create_region(w.compositor)
		wl.wl_region_add(region, 0, 0, 1 << 20, 1 << 20)
		wl.ext_background_effect_surface_v1_set_blur_region(w.blur_surface, region)
		wl.wl_region_destroy(region)
		if os.get_env("AITHING_PROFILE", context.temp_allocator) != "" {
			fmt.eprintln("background blur requested")
		}
	} else if os.get_env("AITHING_PROFILE", context.temp_allocator) != "" {
		fmt.eprintln("compositor offers no background blur")
	}

	// The surface must be committed without a buffer, then configured, before
	// anything (including the Vulkan swapchain) can attach to it.
	wl.wl_surface_commit(w.surface)
	for !w.configured {
		if wl.display_dispatch(w.display) < 0 do return false
	}
	return true
}

@(private = "file")
on_global :: proc "c" (
	data: rawptr,
	registry: ^wl.wl_registry,
	name: u32,
	interface: cstring,
	version: u32,
) {
	context = g_win_ctx
	w := cast(^Window)data
	switch string(interface) {
	case "wl_compositor":
		w.compositor = cast(^wl.wl_compositor)wl.wl_registry_bind(
			registry,
			name,
			&wl.wl_compositor_interface,
			min(version, 6), // v6 tells us the scale the output wants
		)
	case "xdg_wm_base":
		w.wm_base = cast(^wl.xdg_wm_base)wl.wl_registry_bind(
			registry,
			name,
			&wl.xdg_wm_base_interface,
			min(version, 3),
		)
	case "wl_seat":
		w.seat = cast(^wl.wl_seat)wl.wl_registry_bind(
			registry,
			name,
			&wl.wl_seat_interface,
			min(version, 5),
		)
		seat_listener = {
			capabilities = on_seat_capabilities,
			name         = proc "c" (data: rawptr, self: ^wl.wl_seat, name: cstring) {},
		}
		wl.wl_seat_add_listener(w.seat, &seat_listener, w)
	case "ext_background_effect_manager_v1":
		// niri and friends can blur whatever shows through a translucent
		// window. Optional: without it the window is simply see-through.
		w.blur_manager = cast(^wl.ext_background_effect_manager_v1)wl.wl_registry_bind(
			registry,
			name,
			&wl.ext_background_effect_manager_v1_interface,
			1,
		)
	case "wl_data_device_manager":
		w.data_manager = cast(^wl.wl_data_device_manager)wl.wl_registry_bind(
			registry,
			name,
			&wl.wl_data_device_manager_interface,
			min(version, 3),
		)
	case "zxdg_decoration_manager_v1":
		w.deco_manager = cast(^wl.zxdg_decoration_manager_v1)wl.wl_registry_bind(
			registry,
			name,
			&wl.zxdg_decoration_manager_v1_interface,
			1,
		)
	}
}

@(private = "file")
on_seat_capabilities :: proc "c" (data: rawptr, self: ^wl.wl_seat, capabilities: u32) {
	context = g_win_ctx
	w := cast(^Window)data

	if capabilities & wl.wl_seat_capability_pointer != 0 && w.pointer == nil {
		w.pointer = wl.wl_seat_get_pointer(self)
		pointer_listener = {
			enter = proc "c" (data: rawptr, self: ^wl.wl_pointer, serial: u32, surface: ^wl.wl_surface, x, y: wl.Fixed) {
				w := cast(^Window)data
				w.input.has_mouse = true
				w.input.mouse = {f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y))}
			},
			leave = proc "c" (data: rawptr, self: ^wl.wl_pointer, serial: u32, surface: ^wl.wl_surface) {
				(cast(^Window)data).input.has_mouse = false
			},
			motion = proc "c" (data: rawptr, self: ^wl.wl_pointer, time: u32, x, y: wl.Fixed) {
				w := cast(^Window)data
				w.input.mouse = {f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y))}
			},
			button = on_pointer_button,
			axis = proc "c" (data: rawptr, self: ^wl.wl_pointer, time: u32, axis: u32, value: wl.Fixed) {
				w := cast(^Window)data
				v := f32(wl.fixed_to_f64(value))
				horiz := axis == wl.wl_pointer_axis_horizontal_scroll
				switch w.axis_source {
				case wl.wl_pointer_axis_source_finger, wl.wl_pointer_axis_source_continuous:
					if horiz do w.input.scroll_x_px -= v
					else do w.input.scroll_px -= v
				case:
					if horiz do w.input.scroll_x -= v
					else do w.input.scroll -= v
				}
			},
			// The source arrives once per pointer frame, before its axis
			// events, and resets to the wheel afterwards so a stray axis
			// without one still scrolls.
			frame = proc "c" (data: rawptr, self: ^wl.wl_pointer) {
				(cast(^Window)data).axis_source = wl.wl_pointer_axis_source_wheel
			},
			axis_source = proc "c" (data: rawptr, self: ^wl.wl_pointer, axis_source: u32) {
				(cast(^Window)data).axis_source = axis_source
			},
			// Fingers off the pad. Whatever they were doing keeps going.
			axis_stop = proc "c" (data: rawptr, self: ^wl.wl_pointer, time: u32, axis: u32) {
				(cast(^Window)data).input.scroll_end = true
			},
			axis_discrete = proc "c" (data: rawptr, self: ^wl.wl_pointer, axis: u32, discrete: i32) {},
			axis_value120 = proc "c" (data: rawptr, self: ^wl.wl_pointer, axis: u32, value120: i32) {},
			axis_relative_direction = proc "c" (data: rawptr, self: ^wl.wl_pointer, axis: u32, direction: u32) {},
		}
		wl.wl_pointer_add_listener(w.pointer, &pointer_listener, w)
	}

	if capabilities & wl.wl_seat_capability_keyboard != 0 && w.keyboard == nil {
		w.keyboard = wl.wl_seat_get_keyboard(self)
		keyboard_listener = {
			keymap = on_keymap,
			enter = proc "c" (data: rawptr, self: ^wl.wl_keyboard, serial: u32, surface: ^wl.wl_surface, keys: ^wl.Array) {
				(cast(^Window)data).serial = serial
			},
			leave = proc "c" (data: rawptr, self: ^wl.wl_keyboard, serial: u32, surface: ^wl.wl_surface) {
				w := cast(^Window)data
				w.serial = serial
				w.repeat_key = {}
			},
			key = on_key,
			modifiers = on_modifiers,
			repeat_info = proc "c" (data: rawptr, self: ^wl.wl_keyboard, rate, delay: i32) {
				w := cast(^Window)data
				w.repeat_rate = f64(rate)
				w.repeat_delay = f64(delay) / 1000
			},
		}
		wl.wl_keyboard_add_listener(w.keyboard, &keyboard_listener, w)
	}
}

@(private = "file")
on_pointer_button :: proc "c" (
	data: rawptr,
	self: ^wl.wl_pointer,
	serial: u32,
	time_ms: u32,
	button: u32,
	state: u32,
) {
	context = g_win_ctx
	w := cast(^Window)data
	w.serial = serial
	idx := -1
	switch button {
	case BTN_LEFT:
		idx = 0
	case BTN_RIGHT:
		idx = 1
	case BTN_MIDDLE:
		idx = 2
	}
	if idx < 0 do return

	down := state == wl.wl_pointer_button_state_pressed
	if down && !w.input.down[idx] {
		w.input.pressed[idx] = true
		if idx == 0 {
			// Multi-click, for the word/line selection the composer needs.
			if time.duration_milliseconds(time.since(w.last_click)) < 400 {
				w.click_count += 1
			} else {
				w.click_count = 1
			}
			w.last_click = time.now()
			w.input.click_count = w.click_count
		}
	}
	if !down && w.input.down[idx] do w.input.released[idx] = true
	w.input.down[idx] = down
}

@(private = "file")
on_key :: proc "c" (
	data: rawptr,
	self: ^wl.wl_keyboard,
	serial: u32,
	time_ms: u32,
	key: u32,
	state: u32,
) {
	context = g_win_ctx
	w := cast(^Window)data
	w.serial = serial
	if state != wl.wl_keyboard_key_state_pressed {
		if w.repeat_key.code == key do w.repeat_key = {}
		return
	}
	k := Key{key, w.input.mods}
	emit_key(w, k)
	if keymap_repeats(&w.keymap, key) {
		if w.repeat_rate <= 0 do return
		w.repeat_key = k
		w.repeat_next = time.time_add(time.now(), time.Duration(w.repeat_delay * f64(time.Second)))
	}
}

// The keymap arrives as xkb source text on a file descriptor. keys.odin picks
// the two sections it needs out of it; a keymap it cannot make sense of just
// leaves the built-in US table in place.
@(private = "file")
on_keymap :: proc "c" (
	data: rawptr,
	self: ^wl.wl_keyboard,
	format: u32,
	fd: i32,
	size: u32,
) {
	context = g_win_ctx
	defer linux.close(linux.Fd(fd))
	w := cast(^Window)data
	if format != wl.wl_keyboard_keymap_format_xkb_v1 || size == 0 do return

	addr, err := linux.mmap(0, uint(size), {.READ}, {.PRIVATE}, linux.Fd(fd), 0)
	if err != .NONE do return
	defer linux.munmap(addr, uint(size))

	text := strings.string_from_ptr(cast(^byte)addr, int(size - 1))
	// AITHING_KEYMAP=<path> writes out exactly what arrived, which is what the
	// parser's test is checked against.
	if path := os.get_env("AITHING_KEYMAP", context.temp_allocator); path != "" {
		_ = os.write_entire_file(path, transmute([]byte)text)
	}
	km, ok := keymap_parse(text)
	if !ok do return
	keymap_destroy(&w.keymap)
	w.keymap = km
	free_all(context.temp_allocator)
}

@(private = "file")
on_modifiers :: proc "c" (
	data: rawptr,
	self: ^wl.wl_keyboard,
	serial, depressed, latched, locked, group: u32,
) {
	w := cast(^Window)data
	w.serial = serial
	// Without the keymap there is no way to look up which bit is which, but
	// every layout xkb ships puts the four we care about in the same places.
	m := depressed | latched
	mods: Mods
	if m & 1 != 0 do mods += {.Shift}
	if m & 4 != 0 do mods += {.Ctrl}
	if m & 8 != 0 do mods += {.Alt}
	if m & 64 != 0 do mods += {.Super}
	if locked & 2 != 0 do mods ~= {.Shift} // caps lock, for letters
	w.input.mods = mods
	w.repeat_key.mods = mods
}

// Appends a key press and the text it types, if any.
@(private = "file")
emit_key :: proc(w: ^Window, k: Key, repeat := false) {
	// The one place a keycode becomes a key. What it types is still read off
	// the code it arrived on; which key it is comes from the keymap, because
	// a keymap that is not a keyboard puts its keys wherever it likes.
	code := keymap_code(&w.keymap, k.code)
	append(&w.input.keys, Key{code, k.mods})
	r: rune
	if !(.Ctrl in k.mods || .Alt in k.mods || .Super in k.mods) {
		r = keymap_char(&w.keymap, k.code, .Shift in k.mods)
		if r != 0 {
			bytes, n := utf8.encode_rune(r)
			append(&w.input.text, ..bytes[:n])
		}
	}
	// AITHING_KEYS=1 prints what arrived: the only way to tell a key the
	// compositor never sent from one this program mistranslated.
	if g_log_keys {
		// Both codes, because the whole of this bug was invisible with only
		// the first: a synthetic keyboard sends code 1 meaning Insert, and a
		// log that printed 1 and stopped looked like somebody pressed Escape.
		fmt.eprintfln(
			"key code=%d as=%d mods=%v types=%q%s",
			k.code,
			code,
			k.mods,
			r,
			repeat ? " (repeat)" : "",
		)
	}
}

@(private = "file")
g_log_keys: bool

// Drains compositor events and clears the one-frame input. `timeout_ms` is how
// long to wait for something to happen: 0 to return immediately, -1 to block
// until the compositor says something.
window_poll :: proc(w: ^Window, timeout_ms: i32 = 0) {
	w.last_mouse = w.input.mouse
	w.input.pressed = {}
	w.input.released = {}
	w.input.scroll = 0
	w.input.scroll_px = 0
	w.input.scroll_x = 0
	w.input.scroll_x_px = 0
	w.input.scroll_end = false
	w.input.click_count = 0
	clear(&w.input.keys)
	clear(&w.input.text)
	w.resized = false

	wl.display_flush(w.display)

	if wl.display_prepare_read(w.display) == 0 {
		fds := []linux.Poll_Fd {
			{fd = linux.Fd(wl.display_get_fd(w.display)), events = {.IN}},
		}
		n, _ := linux.poll(fds, timeout_ms)
		if n > 0 {
			wl.display_read_events(w.display)
		} else {
			wl.display_cancel_read(w.display)
		}
	}
	wl.display_dispatch_pending(w.display)

	// Everything typed up to here came from a key going down. What the
	// repeat loop adds below did not.
	w.input.repeat_at = len(w.input.text)

	// Held keys repeat on our own clock, so a held backspace empties the
	// composer at the rate the compositor asked for. The catch-up is capped:
	// after a stall — the window was hidden, or the GPU took its time — a
	// held key must not suddenly fire fifty times at once.
	if w.repeat_key.code != 0 && w.repeat_rate > 0 {
		period := time.Duration(f64(time.Second) / w.repeat_rate)
		fired := 0
		for time.since(w.repeat_next) >= 0 && fired < 3 {
			emit_key(w, w.repeat_key, true)
			w.repeat_next = time.time_add(w.repeat_next, period)
			fired += 1
		}
		if time.since(w.repeat_next) >= 0 {
			w.repeat_next = time.time_add(time.now(), period)
		}
	}
}

// How long the loop may sleep before a pending key repeat is due.
window_repeat_timeout :: proc(w: ^Window) -> (ms: i32, pending: bool) {
	if w.repeat_key.code == 0 || w.repeat_rate <= 0 do return 0, false
	left := time.duration_milliseconds(time.diff(time.now(), w.repeat_next))
	return i32(max(left, 0)), true
}

// Asks the compositor to say when it wants the next frame. Called before the
// present so the request rides on that commit; `window_frame_pending` is true
// until the compositor answers, and an animation frame drawn before then
// would only be dropped or shown late.
window_request_frame :: proc(w: ^Window) {
	if w.frame_cb != nil do return
	w.frame_cb = wl.wl_surface_frame(w.surface)
	frame_listener = {
		done = proc "c" (data: rawptr, self: ^wl.wl_callback, callback_data: u32) {
			w := cast(^Window)data
			wl.wl_callback_destroy(self)
			if w.frame_cb == self do w.frame_cb = nil
		},
	}
	wl.wl_callback_add_listener(w.frame_cb, &frame_listener, w)
}

window_frame_pending :: proc(w: ^Window) -> bool {
	return w.frame_cb != nil
}

// Forgets a request whose commit never happened, so it cannot hold the next
// frame hostage.
window_cancel_frame :: proc(w: ^Window) {
	if w.frame_cb == nil do return
	wl.wl_callback_destroy(w.frame_cb)
	w.frame_cb = nil
}

window_pixel_size :: proc(w: ^Window) -> (int, int) {
	return w.width * w.scale, w.height * w.scale
}

// True if anything happened this frame that the UI should react to.
window_has_input :: proc(w: ^Window) -> bool {
	return(
		w.input.pressed != {} ||
		w.input.released != {} ||
		w.input.scroll != 0 ||
		w.input.scroll_px != 0 ||
		w.input.scroll_x != 0 ||
		w.input.scroll_x_px != 0 ||
		w.input.scroll_end ||
		len(w.input.keys) > 0 ||
		w.input.mouse != w.last_mouse \
	)
}

window_close :: proc(w: ^Window) {
	keymap_destroy(&w.keymap)
	delete(w.input.keys)
	delete(w.input.text)
	if w.blur_surface != nil do wl.ext_background_effect_surface_v1_destroy(w.blur_surface)
	if w.decoration != nil do wl.zxdg_toplevel_decoration_v1_destroy(w.decoration)
	if w.toplevel != nil do wl.xdg_toplevel_destroy(w.toplevel)
	if w.xdg_surface != nil do wl.xdg_surface_destroy(w.xdg_surface)
	if w.surface != nil do wl.wl_surface_destroy(w.surface)
	if w.display != nil do wl.display_disconnect(w.display)
}
