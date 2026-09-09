package aithing

import "core:strings"
import "core:testing"

// A font where every character in the dense range is the same width, so a
// line's width is its length times one number and a test can say what it
// expects without knowing anything about type.
@(private = "file")
even_font :: proc(advance: f32) -> Font {
	f: Font
	f.ascent, f.descent = 1, -0.25
	f.baseline = 0.8
	for i in 0 ..< DENSE_COUNT {
		f.dense[i] = Glyph {
			code    = u32(DENSE_FIRST) + u32(i),
			advance = advance,
			plane   = {0, 0, advance, 0.7},
			atlas   = {0, 0, 1, 1},
		}
	}
	return f
}

// A line is fitted to the width of the bubble it goes in, and it is drawn in
// more than one face: inline `code` is set in the mono one, which is wider per
// character than the body face at the same size. The wrap measured every line
// in the body face, so a paragraph with a span in it was fitted to a width it
// was never drawn at, and the tail of it — the span and whatever followed it —
// came out over the right edge of the bubble. See span_step.
@(test)
a_line_is_fitted_to_the_width_it_is_drawn_at :: proc(t: ^testing.T) {
	g_atlas = Atlas{width = 1, height = 1, distance_range = 4, em_px = 48}

	ui: UI
	defer ui_destroy(&ui)
	ui.regular = even_font(0.5)
	ui.bold = even_font(0.5)
	// Half again as wide as the body face, which is the whole point: the two
	// faces used to be measured as if they were one.
	ui.mono = even_font(0.75)

	b: Block
	defer strings.builder_destroy(&b.text)
	strings.write_string(
		&b.text,
		"the placeholder was gated on `!focused`, which on a thread is never, so `\"Reply to Claude...\"` had never once been seen",
	)

	WIDTH :: f32(300)
	md_layout(&ui, &b, WIDTH)
	testing.expect(t, len(b.lines) > 1, "the paragraph did not wrap at all")

	// Measured off what is actually drawn — the glyphs and the box behind a
	// code span, every corner of them — rather than off the same sum the wrap
	// made. A test that asks the wrap whether it was right agrees with it
	// however wrong it is.
	input: Input
	for l in b.lines {
		ui_begin(&ui, 800, 600, &input, 1.0 / 60)
		md_draw_line(&ui, l, 0, 0, WIDTH, TEXT, FAINT)
		right: f32
		for v in ui.verts do right = max(right, v.pos.x)
		ui_end(&ui)
		testing.expectf(t, right <= WIDTH, "%q is drawn %v wide in a %v line", l.text, right, WIDTH)
	}
}
