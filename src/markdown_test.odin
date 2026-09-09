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

// A code span cut across a wrap used to come out inverted for the rest of the
// paragraph. The wrap reset the pen to the plain face at every line and
// md_draw_line started every line plain to match, so the span's *closing*
// backtick — the one that landed on the second line — turned code on rather
// than off: the prose between the spans was drawn boxed in mono and the spans
// themselves bare. `./build.sh` and `odin test src` pass; merged into `main`
// read as "src pass; merged into" boxed and "main" plain, which is how it was
// noticed.
//
// Asked of what is drawn: the mono face is a different width here, so a
// segment's face is legible in the advance of the quads it left behind.
@(test)
a_span_cut_across_a_wrap_keeps_its_face :: proc(t: ^testing.T) {
	g_atlas = Atlas{width = 1, height = 1, distance_range = 4, em_px = 48}

	ui: UI
	defer ui_destroy(&ui)
	ui.regular = even_font(0.5)
	ui.bold = even_font(0.5)
	ui.mono = even_font(0.75)

	b: Block
	defer strings.builder_destroy(&b.text)
	strings.write_string(&b.text, "aaa bbb ccc `ddd eee fff` ggg hhh `iii` jjj")

	WIDTH :: f32(200)
	md_layout(&ui, &b, WIDTH)
	testing.expect(t, len(b.lines) > 1, "the paragraph did not wrap at all")

	// Which line the span was cut on is the wrap's business; what matters is
	// that whichever line opens inside it says so, and that the line after the
	// span closes is back in the plain face.
	carried := -1
	for l, i in b.lines do if l.pen.code do carried = i
	testing.expect(t, carried >= 0, "the span was not cut across a line at all")

	last := b.lines[len(b.lines) - 1]
	testing.expectf(
		t,
		!last.pen.code,
		"%q opens in the mono face, so the closing backtick turned code on",
		last.text,
	)

	// And the drawing agrees, which is the half that matters: reading Line.pen
	// is what md_draw_line was not doing. A code box is the only non-glyph
	// quad on a body line and it is drawn CODE_EDGE left of the pen, so the
	// carried line opening in a box is the box starting at the line's own
	// left edge.
	input: Input
	ui_begin(&ui, 800, 600, &input, 1.0 / 60)
	md_draw_line(&ui, b.lines[carried], 0, 0, WIDTH, TEXT, FAINT)
	box_left := max(f32)
	for v in ui.verts do if v.effect != .Text do box_left = min(box_left, v.pos.x)
	ui_end(&ui)
	testing.expectf(
		t,
		box_left <= 0,
		"%q carries a span but its first code box starts at %v, not at the line's edge",
		b.lines[carried].text,
		box_left,
	)

	// The line after the span closes is plain again: only the one span that
	// opens and closes on it is boxed.
	ui_begin(&ui, 800, 600, &input, 1.0 / 60)
	md_draw_line(&ui, last, 0, 0, WIDTH, TEXT, FAINT)
	plain := 0
	for v in ui.verts do if v.effect != .Text do plain += 1
	ui_end(&ui)
	testing.expectf(
		t,
		plain / 4 <= 1,
		"%q drew %v code boxes, not the one span it has",
		last.text,
		plain / 4,
	)
}
