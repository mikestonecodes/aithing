package aithing

import "core:fmt"
import "core:mem"
import stbi "vendor:stb/image"

// Text is drawn from one multi-channel signed distance field, baked ahead of
// time by tools/gen_font_atlas.sh and carried in the binary. The sheet stores
// the distance to each glyph's outline rather than its coverage, so the
// fragment shader rebuilds a sharp edge at whatever size the quad happens to
// be — one sheet serves a 13px timestamp and a 24px heading equally, which a
// bitmap baked at a single size cannot.
//
// All three fonts share the sheet and therefore one bindless slot. Everything
// below is in em units, so a size in pixels is a multiplication: `font_scale`
// is pixels per em and nothing else needs to know how the sheet was made.

ATLAS_PNG := #load("font/atlas.png")
ATLAS_BIN := #load("font/atlas.bin")

// Mirrors what tools/gen_font_atlas.sh packs. Read in place, never parsed.
Atlas_Header :: struct #packed {
	magic:          u32,
	width, height:  u32,
	distance_range: f32,
	em_px:          f32, // the size the distances were computed at
	font_count:     u32,
}

Font_Header :: struct #packed {
	ascender, descender, line_height: f32,
	glyph_count:                      u32,
}

Glyph :: struct #packed {
	code:    u32,
	advance: f32,
	plane:   [4]f32, // left, bottom, right, top, in em from the baseline
	atlas:   [4]f32, // left, bottom, right, top, in atlas pixels, y up
}

ATLAS_MAGIC :: u32(0x31534446)

// The sheet's own numbers, shared by every font on it.
Atlas :: struct {
	tex:            u32,
	width, height:  f32,
	distance_range: f32,
	em_px:          f32,
}

g_atlas: Atlas

// Codepoints below this are looked up by subtraction, which covers ASCII and
// the Latin-1 supplement — everything a transcript is mostly made of. The rest
// (dashes, curly quotes, box drawing) is a short list walked linearly; there
// are a few dozen of them and they are rare enough not to be worth hashing.
DENSE_FIRST :: rune(0x20)
DENSE_LAST :: rune(0xFF)
DENSE_COUNT :: int(DENSE_LAST - DENSE_FIRST + 1)

Font :: struct {
	dense:    [DENSE_COUNT]Glyph,
	sparse:   []Glyph, // sorted by code
	ascent:   f32, // em, positive above the baseline
	descent:  f32, // em, negative below it
	line_gap: f32,
	tex:      u32,
}

// Loads the sheet and hands back the three fonts on it, in the order the
// generator lists them: regular, bold, mono.
font_atlas_load :: proc(g: ^Gpu) -> (regular, bold, mono: Font, ok: bool) {
	if len(ATLAS_BIN) < size_of(Atlas_Header) do return {}, {}, {}, false
	head := (^Atlas_Header)(raw_data(ATLAS_BIN))^
	if head.magic != ATLAS_MAGIC || head.font_count < 3 {
		fmt.eprintln("font atlas is not the format this build expects")
		return {}, {}, {}, false
	}

	w, h, channels: i32
	pixels := stbi.load_from_memory(
		raw_data(ATLAS_PNG),
		i32(len(ATLAS_PNG)),
		&w,
		&h,
		&channels,
		4,
	)
	if pixels == nil {
		fmt.eprintln("cannot decode the font atlas")
		return {}, {}, {}, false
	}
	defer stbi.image_free(pixels)

	g_atlas = Atlas {
		tex            = texture_upload(g, pixels[:w * h * 4], int(w), int(h), 4),
		width          = f32(head.width),
		height         = f32(head.height),
		distance_range = head.distance_range,
		em_px          = head.em_px,
	}

	off := size_of(Atlas_Header)
	out: [3]Font
	for i in 0 ..< 3 {
		out[i], off = font_read(off) or_return
	}
	return out[0], out[1], out[2], true
}

@(private = "file")
font_read :: proc(offset: int) -> (font: Font, next: int, ok: bool) {
	off := offset
	if off + size_of(Font_Header) > len(ATLAS_BIN) do return {}, 0, false
	head := (^Font_Header)(raw_data(ATLAS_BIN[off:]))^
	off += size_of(Font_Header)

	span := int(head.glyph_count) * size_of(Glyph)
	if off + span > len(ATLAS_BIN) do return {}, 0, false
	glyphs := mem.slice_data_cast([]Glyph, ATLAS_BIN[off:off + span])
	off += span

	font.ascent = head.ascender
	font.descent = head.descender
	font.line_gap = head.line_height - (head.ascender - head.descender)
	font.tex = g_atlas.tex

	// The dense range is copied out so a lookup is one bounds check and one
	// index; what is left over stays a slice of the loaded bytes.
	sparse_from := len(glyphs)
	for gl, i in glyphs {
		r := rune(gl.code)
		if r < DENSE_FIRST || r > DENSE_LAST {
			sparse_from = min(sparse_from, i)
			continue
		}
		font.dense[int(r - DENSE_FIRST)] = gl
	}
	font.sparse = glyphs[sparse_from:]
	return font, off, true
}

// The sheet has no CJK and no emoji, so anything outside it is folded onto the
// nearest thing that means the same. Claude's prose is full of punctuation the
// fonts do carry, which is why the list is shorter than it used to be: the
// curly quotes, dashes, bullets and arrows are real glyphs now.
@(private = "file")
fold :: proc "contextless" (r: rune) -> rune {
	switch r {
	case '✓', '✔':
		return 'v' // Noto Sans has no check mark at any weight
	case '✗', '✘':
		return 'x'
	case '↵':
		return '<'
	}
	return '?'
}

// The glyph for a rune, or the folded stand-in when the sheet has none.
font_glyph :: proc "contextless" (f: ^Font, r: rune) -> Glyph {
	if r >= DENSE_FIRST && r <= DENSE_LAST {
		g := f.dense[int(r - DENSE_FIRST)]
		if g.code != 0 do return g
	} else {
		// Sorted, but a few dozen entries: a scan beats the branch misses of a
		// binary search and never leaves the one cache line it started on.
		for g in f.sparse do if rune(g.code) == r do return g
	}
	folded := fold(r)
	if folded >= DENSE_FIRST && folded <= DENSE_LAST {
		g := f.dense[int(folded - DENSE_FIRST)]
		if g.code != 0 do return g
	}
	return f.dense[int('?' - DENSE_FIRST)]
}

// Pixels per em: every metric on a Font is in em, so this is the only place a
// size in pixels turns into one on screen.
font_scale :: proc "contextless" (f: ^Font, size: f32) -> f32 {
	return size
}

font_width :: proc(f: ^Font, text: string, size: f32) -> f32 {
	w: f32
	for ch in text {
		w += font_glyph(f, ch).advance
	}
	return w * size
}

// How wide the distance ramp is in screen pixels. Below about two it stops
// spanning whole pixels, and then the shader's clamp can reach neither 0 nor
// 1: every glyph turns into a translucent plate with a washed-out letter in
// it, which is what small text looks like without this floor.
font_px_range :: proc "contextless" (size: f32) -> f32 {
	return max(g_atlas.distance_range * (size / g_atlas.em_px), 2)
}

// Trims text to fit `max_width`, appending an ellipsis when it has to cut.
// The result is written into `buf`, which the caller keeps on the stack: this
// runs for every visible row of every frame, and none of it should reach the
// allocator.
font_ellipsize :: proc(f: ^Font, text: string, size: f32, max_width: f32, buf: []u8) -> string {
	if font_width(f, text, size) <= max_width do return text

	ell := font_width(f, "...", size)
	w: f32
	for ch, byte_index in text {
		next := w + font_glyph(f, ch).advance * size
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
