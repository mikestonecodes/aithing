package aithing

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import stbi "vendor:stb/image"

// Pasted images. Claude Code reads images off disk, so a paste is written to
// the cache directory and the path is handed to the prompt; the decoded pixels
// only exist so the composer can show a thumbnail of what is attached.

Attachment :: struct {
	path:   string, // where it was written, and what goes in the prompt
	tex:    u32, // bindless slot, WHITE_TEX until it is uploaded
	width:  int,
	height: int,
}

cache_dir :: proc(allocator := context.temp_allocator) -> string {
	// AITHING_CACHE points the lot somewhere else, the way AITHING_CONFIG
	// does for the saved state: the worktree tests make and remove real
	// checkouts, and a test run must not go anywhere near the trees the
	// window someone is using has work in.
	if dir := os.get_env("AITHING_CACHE", context.temp_allocator); dir != "" {
		os.make_directory_all(dir)
		return strings.clone(dir, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	dir, _ := filepath.join({home, ".cache", "aithing"}, allocator)
	os.make_directory_all(dir)
	return dir
}

cache_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	path, _ := filepath.join({cache_dir(context.temp_allocator), name}, allocator)
	return path
}

// Writes an encoded image to the cache and hands back where it landed. This
// is the whole of what Claude ever gets — the harness opens the file itself —
// so it is also the whole of what a paste needs when there is nowhere to draw
// a thumbnail.
attachment_write :: proc(data: []byte, mime: string, allocator := context.allocator) -> (string, bool) {
	ext := "png"
	switch mime {
	case "image/jpeg":
		ext = "jpg"
	case "image/webp":
		ext = "webp"
	case "image/bmp":
		ext = "bmp"
	}
	name := fmt.tprintf("paste-%d.%s", time.now()._nsec, ext)
	path := cache_path(name, allocator)
	if os.write_entire_file(path, data) != nil {
		delete(path, allocator)
		return "", false
	}
	return path, true
}

// The same write, plus the decode the composer needs to show what is attached.
attachment_make :: proc(g: ^Gpu, data: []byte, mime: string) -> (a: Attachment, ok: bool) {
	path, wrote := attachment_write(data, mime)
	if !wrote do return {}, false

	a.path = path
	a.tex = WHITE_TEX
	attachment_decode(g, &a, data) // still attachable if it will not decode
	return a, true
}

// The picture a path names, read back off disk. This is how the box under the
// grid gets a thumbnail: what was pasted there is a path in the text and
// nothing else, so the only way to show it is to open the file the text names.
attachment_load :: proc(g: ^Gpu, path: string) -> Attachment {
	a := Attachment {
		tex = WHITE_TEX,
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return a
	attachment_decode(g, &a, data)
	return a
}

// Width, height and a slot on the GPU. The measuring happens whether or not
// there is a device to upload to: how tall a preview wants to be is a fact
// about the pixels, and the tests have the pixels and no Vulkan.
@(private = "file")
attachment_decode :: proc(g: ^Gpu, a: ^Attachment, data: []byte) {
	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return
	defer stbi.image_free(pixels)

	a.width, a.height = int(w), int(h)
	if g.device != nil && !bindless_full(g) {
		a.tex = texture_upload(g, pixels[:int(w) * int(h) * 4], int(w), int(h), 4)
	}
}

attachment_destroy :: proc(a: ^Attachment) {
	delete(a.path)
	a^ = {}
}

// Images are handed to Claude the way a person would: by naming the file in
// the prompt, which the harness then reads with its own tools.
attachments_prompt :: proc(text: string, list: []Attachment, allocator := context.allocator) -> string {
	if len(list) == 0 do return strings.clone(text, allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, text)
	for a in list {
		strings.write_string(&b, "\n\n")
		strings.write_string(&b, a.path)
	}
	return strings.to_string(b)
}

// --- what the boxes show ------------------------------------------------------

// How many pictures the window keeps decoded at once. Every path the box has
// ever held gets an answer remembered for it, wrong ones included, so a long
// evening of typing must not grow this without end.
PREVIEW_MAX :: 64

// The picture a path names, decoded once and found again by the path. This is
// the one funnel: nothing else opens a file to draw it.
//
// It is a cache and it is allowed to be one because it cannot be wrong. A path
// under the cache directory names the same bytes forever — a paste writes a
// new name every time, down to the nanosecond — so there is no event that
// would have to invalidate an entry, and the only thing kept here is work
// already done. What it saves is not small: decoding a full-screen PNG is
// several milliseconds, and a thumbnail is drawn on every frame the box is on
// screen. A path that does not open is remembered as a failure for the same
// reason, or every frame would go looking for a file that is not there.
app_preview :: proc(app: ^App, path: string) -> Attachment {
	if a, ok := app.previews[path]; ok do return a
	a := attachment_load(&app.gpu, path)
	if len(app.previews) < PREVIEW_MAX do app.previews[strings.clone(path)] = a
	return a
}

app_previews_destroy :: proc(app: ^App) {
	for path in app.previews do delete(path)
	delete(app.previews)
}

// Whether a path names a picture this can decode. The box under the grid holds
// text, so a path in it is only a paste if it reads like one.
path_is_image :: proc(path: string) -> bool {
	buf: [8]u8
	ext := filepath.ext(path)
	if len(ext) == 0 || len(ext) > len(buf) do return false
	for i in 0 ..< len(ext) {
		c := ext[i]
		buf[i] = c >= 'A' && c <= 'Z' ? c + 32 : c
	}
	switch string(buf[:len(ext)]) {
	case ".png", ".jpg", ".jpeg", ".webp", ".bmp":
		return true
	}
	return false
}

// The pictures the box under the grid is showing, worked out from what is
// written in it and nothing else.
//
// The composer keeps an attachment list because it has a send of its own to
// hang one off. The grid's box has no such thing — what is typed there is cut
// into cards and joined back up again — so a list beside the text would be a
// second thing to keep in step through every split and backspace, and the
// answer to "which pictures is this card carrying" would have two places to
// come from. It has one: the paths in the text, which is also exactly what
// goes out to Claude. Delete the path and the thumbnail goes with it.
capture_images :: proc(app: ^App, allocator := context.temp_allocator) -> []Attachment {
	text := editor_text(&app.capture)
	if len(text) == 0 do return nil
	out := make([dynamic]Attachment, allocator)
	for word in strings.fields(text, context.temp_allocator) {
		// Absolute only: a paste writes one, and a bare word that happens to
		// end in .png is prose.
		if len(word) == 0 || word[0] != '/' do continue
		if !path_is_image(word) do continue
		a := app_preview(app, word)
		if a.width > 0 do append(&out, a)
	}
	return out[:]
}
