package aithing

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import stbi "vendor:stb/image"

// Pasted images. Claude Code reads images off disk, so a paste is written to
// the cache directory and the path is handed to the prompt; the decoded pixels
// only exist so the window can show what is attached. The path itself is never
// drawn anywhere — see text_without_images and draw_editor_line — because it
// is a cache name with a nanosecond in it, and what it names is the only part
// worth looking at.

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
// goes out to Claude. Delete the path and the picture goes with it.
capture_images :: proc(app: ^App, allocator := context.temp_allocator) -> []Attachment {
	return text_images(app, editor_text(&app.capture), allocator)
}

// The pictures a piece of writing names, which is the same question wherever
// it is asked: of the box while it is being typed into, and of a card once the
// words have been cut out of it and given a thread of their own.
text_images :: proc(app: ^App, text: string, allocator := context.temp_allocator) -> []Attachment {
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

// --- where a picture sits in a line of prose ----------------------------------

// Where the image path around byte `at` starts and stops, if what `at` falls
// inside is one. It is the same test capture_images makes of every word —
// absolute, and named like a picture — asked of one position instead, so the
// box that draws a picture, the arrow key that steps over it and the card that
// prints the words without it cannot disagree about where it begins and ends.
image_word :: proc(text: string, at: int) -> (start, end: int, ok: bool) {
	if at < 0 || at > len(text) do return 0, 0, false
	start, end = at, at
	for start > 0 && !is_space(text[start - 1]) do start -= 1
	for end < len(text) && !is_space(text[end]) do end += 1
	if end <= start do return 0, 0, false
	word := text[start:end]
	if word[0] != '/' || !path_is_image(word) do return 0, 0, false
	return start, end, true
}

is_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// Whether a picture's path starts at exactly this byte. Only asked at a word
// boundary, which is the only place one can start.
image_at :: proc(text: string, at: int) -> (end: int, ok: bool) {
	if at > 0 && !is_space(text[at - 1]) do return 0, false
	start, e, is_img := image_word(text, at)
	if !is_img || start != at do return 0, false
	return e, true
}

// The prose without the pictures in it. A path is what the harness is handed
// and what says which card carries which picture, and it is nothing anyone
// wants to read: every place that prints a person's words back at them —
// a card on the grid, the line under the pointer, a turn in the transcript —
// prints them through this, and shows the picture itself instead.
text_without_images :: proc(text: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	word := 0 // the start of the run being copied
	for i <= len(text) {
		if i == len(text) {
			strings.write_string(&b, text[word:i])
			break
		}
		if end, ok := image_at(text, i); ok {
			strings.write_string(&b, text[word:i])
			// The space in front of the path goes with it, or the words left
			// behind end in a gap the width of the picture that was there.
			for len(b.buf) > 0 && is_space(b.buf[len(b.buf) - 1]) do pop(&b.buf)
			i = end
			word = i
			continue
		}
		i += 1
	}
	return strings.trim_space(strings.to_string(b))
}

// The picture a stone on the path is holding, if it is holding one: the paste
// a turn carried, and the file a tool opened when that file is a picture.
// Reading a screenshot used to say `/tmp/g-paste.png` and `nothing back`,
// which is the two things about it worth knowing least — the harness hands the
// pixels to the model and has nothing to print, and the panel had the path and
// stopped there.
//
// A tool counts only when the whole of its argument is one path: `cat
// /tmp/a.png` is a command that mentions a picture, not a picture.
block_picture :: proc(b: ^Block) -> string {
	if b.kind == .Image do return b.image
	if b.kind != .Tool do return ""
	start, end, ok := image_word(b.arg, 0)
	if !ok || start != 0 || end != len(b.arg) do return ""
	return b.arg
}

// A person's turn as the transcript shows it: the pictures they named become
// stones of their own and the paths come out of the words. Both the message
// just typed and the one read back off a session file come through here, so a
// paste looks the same a second later and a year later.
msg_write_user :: proc(chat: ^Chat, m: int, text: string) {
	if body := text_without_images(text); body != "" {
		ref := msg_append_block(chat, m, Block{kind = .Text})
		strings.write_string(&chat_block(chat, ref).text, body)
	}
	i := 0
	for i < len(text) {
		end, ok := image_at(text, i)
		if !ok {
			i += 1
			continue
		}
		msg_append_block(chat, m, Block{kind = .Image, image = strings.clone(text[i:end])})
		i = end
	}
}
