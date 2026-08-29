package aithing

import "core:fmt"
import "core:os"
import tt "vendor:stb/truetype"

FIRST_CHAR :: 32
NUM_CHARS :: 224 // printable ASCII plus Latin-1: quotes, dashes, accents
ATLAS_SIZE :: 2048

Font :: struct {
	chars:      [NUM_CHARS]tt.bakedchar,
	tex:        u32,
	bake_px:    f32,
	ascent:     f32,
	descent:    f32,
	line_gap:   f32,
}

// Bakes one glyph atlas and parks it in the bindless table. Text is drawn at
// any size by scaling the baked quads, so a whole UI needs two atlases.
font_load :: proc(g: ^Gpu, path: string, px: f32) -> (font: Font, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read font %s: %v", path, err)
		return {}, false
	}
	defer delete(data)

	bitmap := make([]byte, ATLAS_SIZE * ATLAS_SIZE)
	defer delete(bitmap)

	res := tt.BakeFontBitmap(
		raw_data(data),
		0,
		px,
		raw_data(bitmap),
		ATLAS_SIZE,
		ATLAS_SIZE,
		FIRST_CHAR,
		NUM_CHARS,
		raw_data(font.chars[:]),
	)
	if res == 0 {
		fmt.eprintfln("font atlas too small for %s at %.0fpx", path, px)
		return {}, false
	}

	tt.GetScaledFontVMetrics(raw_data(data), 0, px, &font.ascent, &font.descent, &font.line_gap)
	font.bake_px = px
	font.tex = texture_upload(g, bitmap, ATLAS_SIZE, ATLAS_SIZE, 1)
	return font, true
}

// The atlas is one contiguous run of codepoints, so anything above Latin-1
// falls back to the nearest ASCII that means the same thing. Claude's prose is
// full of curly quotes, em dashes and bullets, and rendering all of them as `?`
// makes an otherwise fine answer look broken.
glyph_index :: proc "contextless" (r: rune) -> int {
	r := r
	switch r {
	case '\u2018', '\u2019', '\u201b': r = '\''
	case '\u201c', '\u201d', '\u201e': r = '"'
	case '\u2010' ..= '\u2015': r = '-'
	case '\u2022', '\u25cf', '\u25aa', '\u2043': r = '*'
	case '\u2192': r = '>'
	case '\u2190': r = '<'
	case '\u2713', '\u2714': r = 'v'
	case '\u00a0', '\u2007', '\u202f', '\u2009': r = ' '
	case '\u2026': r = '.' // an ellipsis collapses to one dot; close enough inline
	}
	i := int(r) - FIRST_CHAR
	if i < 0 || i >= NUM_CHARS do i = int('?') - FIRST_CHAR
	return i
}

font_scale :: proc(f: ^Font, size: f32) -> f32 {
	return size / f.bake_px
}

font_width :: proc(f: ^Font, text: string, size: f32) -> f32 {
	scale := font_scale(f, size)
	w: f32
	for ch in text {
		w += f.chars[glyph_index(ch)].xadvance
	}
	return w * scale
}

// Trims text to fit `max_width`, appending an ellipsis when it has to cut.
// The result is written into `buf`, which the caller keeps on the stack: this
// runs for every visible row of every frame, and none of it should reach the
// allocator.
font_ellipsize :: proc(f: ^Font, text: string, size: f32, max_width: f32, buf: []u8) -> string {
	if font_width(f, text, size) <= max_width do return text

	ell := font_width(f, "...", size)
	scale := font_scale(f, size)
	w: f32
	for ch, byte_index in text {
		next := w + f.chars[glyph_index(ch)].xadvance * scale
		if next + ell > max_width {
			cut := min(byte_index, max(len(buf) - 3, 0))
			n := copy(buf, text[:cut])
			n += copy(buf[n:], "...")
			return string(buf[:n])
		}
		w = next
	}
	return text
}
