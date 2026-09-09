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

@(private = "file")
table_ui :: proc(ui: ^UI) {
	g_atlas = Atlas{width = 1, height = 1, distance_range = 4, em_px = 48}
	ui.regular = even_font(0.5)
	ui.bold = even_font(0.5)
	ui.mono = even_font(0.75)
}

// A table is one Line holding all of its rows, because the width of a column
// is the widest cell in it and no single row knows that. The two things that
// have to agree about it are the height md_layout leaves for it and the height
// md_draw_line advances by; both ask md_table, so this checks they came back
// with the same answer, and that the cells of a column all start at the same x
// however long the cells above them were.
@(test)
a_table_has_one_answer_about_its_columns :: proc(t: ^testing.T) {
	ui: UI
	defer ui_destroy(&ui)
	table_ui(&ui)

	b: Block
	defer strings.builder_destroy(&b.text)
	strings.write_string(
		&b.text,
		"before\n\n| a | b |\n|---|---|\n| a much longer first cell | y |\n| x | z |\n\nafter\n",
	)

	WIDTH :: f32(600)
	md_layout(&ui, &b, WIDTH)

	tables := 0
	table: Line
	for l in b.lines do if l.style == .Table {
		tables += 1
		table = l
	}
	testing.expectf(t, tables == 1, "the table came out as %v lines, not one", tables)

	m := md_table(&ui, table.text, WIDTH)
	testing.expectf(t, m.ncols == 2 && m.rows == 3, "read %v columns and %v rows", m.ncols, m.rows)

	// The height the block reserved is the height the draw advances by.
	input: Input
	ui_begin(&ui, 800, 600, &input, 1.0 / 60)
	adv := md_draw_line(&ui, table, 0, 0, WIDTH, TEXT, FAINT)
	// Every cell of the second column opens at the same x, whatever the cell
	// to its left came to: that is what one shared set of widths buys.
	starts: map[int]f32
	defer delete(starts)
	for v in ui.verts {
		if v.effect != .Text do continue
		if v.pos.x < m.width[0] do continue
		row := int(v.pos.y / TABLE_LH)
		if x, seen := starts[row]; !seen || v.pos.x < x do starts[row] = v.pos.x
	}
	ui_end(&ui)

	testing.expectf(t, adv == m.height, "drew %v tall, laid out %v", adv, m.height)
	testing.expectf(t, len(starts) == 3, "found %v rows of second-column text, not 3", len(starts))
	want := m.width[0] + TABLE_PAD
	for row, x in starts {
		testing.expectf(t, abs(x - want) < 0.5, "row %v opens its second column at %v, not %v", row, x, want)
	}
}

// A table wider than the bubble is squeezed to fit rather than run off the
// right of it, which is the same rule every other block here is held to.
@(test)
a_wide_table_is_squeezed_to_the_width_it_is_given :: proc(t: ^testing.T) {
	ui: UI
	defer ui_destroy(&ui)
	table_ui(&ui)

	b: Block
	defer strings.builder_destroy(&b.text)
	strings.write_string(
		&b.text,
		"| one | two | three |\n|---|---|---|\n| a very long cell indeed that will not fit | another long one here | and a third of them |\n",
	)

	WIDTH :: f32(300)
	md_layout(&ui, &b, WIDTH)
	m := md_table(&ui, b.lines[0].text, WIDTH)
	total: f32
	for i in 0 ..< m.ncols do total += m.width[i]
	testing.expectf(t, total <= WIDTH + 0.01, "the columns come to %v in a %v bubble", total, WIDTH)
}

// The rule row is what makes a table. A sentence with a pipe in it is a
// sentence: reading it as a header would eat the rest of the paragraph into a
// column nobody asked for.
@(test)
a_pipe_alone_is_not_a_table :: proc(t: ^testing.T) {
	ui: UI
	defer ui_destroy(&ui)
	table_ui(&ui)

	b: Block
	defer strings.builder_destroy(&b.text)
	strings.write_string(&b.text, "run `ls | wc -l` to count them\nand then read the number\n")

	md_layout(&ui, &b, 400)
	for l in b.lines {
		testing.expectf(t, l.style != .Table, "%q was read as a table", l.text)
	}
}

// The alignments in the rule row are read off it, and a right-aligned cell
// ends where its column ends rather than starting where it starts.
@(test)
a_rule_row_says_how_a_column_is_aligned :: proc(t: ^testing.T) {
	ui: UI
	defer ui_destroy(&ui)
	table_ui(&ui)

	b: Block
	defer strings.builder_destroy(&b.text)
	strings.write_string(&b.text, "| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n")

	md_layout(&ui, &b, 600)
	m := md_table(&ui, b.lines[0].text, 600)
	testing.expect(t, m.align[0] == .Left, "the first column is not left aligned")
	testing.expect(t, m.align[1] == .Center, "the second column is not centred")
	testing.expect(t, m.align[2] == .Right, "the third column is not right aligned")
}
