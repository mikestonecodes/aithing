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
	home := os.get_env("HOME", context.temp_allocator)
	dir, _ := filepath.join({home, ".cache", "aithing"}, allocator)
	os.make_directory_all(dir)
	return dir
}

cache_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	path, _ := filepath.join({cache_dir(context.temp_allocator), name}, allocator)
	return path
}

// Writes an encoded image to the cache and decodes it for the thumbnail.
attachment_make :: proc(g: ^Gpu, data: []byte, mime: string) -> (a: Attachment, ok: bool) {
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
	path := cache_path(name, context.allocator)
	if os.write_entire_file(path, data) != nil {
		delete(path)
		return {}, false
	}

	a.path = path
	a.tex = WHITE_TEX

	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return a, true // still attachable; just no preview
	defer stbi.image_free(pixels)

	a.width, a.height = int(w), int(h)
	if !bindless_full(g) {
		a.tex = texture_upload(g, pixels[:int(w) * int(h) * 4], int(w), int(h), 4)
	}
	return a, true
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
