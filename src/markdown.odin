package aithing

import "core:strings"

// Just enough Markdown to make an answer readable: headings, bullets, block
// quotes, fenced code, pipe tables, and inline `code` and **bold**. Wrapping happens once
// per block and is cached on the block, because a long transcript re-wrapped
// every frame is the one thing that would make this UI feel slow.

BODY_PX :: f32(19)
CODE_PX :: f32(16.5)
HEAD_PX :: f32(24)
BODY_LH :: f32(29)
CODE_LH :: f32(24)
HEAD_LH :: f32(38)

// The two pixels an inline code box hangs off either side of the span it is
// drawn behind (see md_draw_line), counted by the wrap so the box lands inside
// the width the line was fitted to and not over the edge of the bubble.
CODE_EDGE :: f32(2)

// A table is set a couple of points down from the prose around it, because a
// table wide enough to need four columns at reading size is a table that gets
// squeezed, and squeezed columns are worse to read than small ones.
TABLE_PX :: f32(16.5)
TABLE_LH :: f32(28)
TABLE_PAD :: f32(10) // the gutter either side of a cell's text
TABLE_GAP :: f32(6) // air above and below the whole table

// More columns than this and the rest of the row is left in the last cell.
// Nothing an agent writes has twelve columns; a line with twelve pipes in it
// is far more likely to be a shell pipeline someone forgot to fence.
MD_TABLE_COLS :: 12

// What the pen is set in partway along a line: ** toggles the bold face and a
// backtick toggles the mono one. Kept as a thing rather than two bools passed
// about, because the wrap and the draw both walk a line this way and the two
// of them disagreeing is what put text outside the bubble.
Span_Pen :: struct {
	bold: bool,
	code: bool,
}

// The face the next characters are set in, and at what size. Inline code is a
// point smaller because the mono face runs large beside the body one.
span_font :: proc(ui: ^UI, p: Span_Pen, base: ^Font, px: f32) -> (^Font, f32) {
	if p.code do return &ui.mono, px - 1
	if p.bold do return &ui.bold, px
	return base, px
}

// One step along a line, the way md_draw_line takes it: how far the pen moves
// and where the next character starts. The markers themselves are drawn as
// nothing and only change what follows them.
//
// The wrap and the draw both step with this. They used not to — the wrap
// measured every character in the body face at the body size, and an inline
// `code` span is drawn in the mono face — so a line carrying a span was fitted
// to a width narrower than the one it was drawn at, and the tail of it ran off
// the right of the bubble. The comment here used to say measuring the markers
// "only ever leaves the line shorter than it planned for", which is true of
// the markers and was never true of what they switch on.
span_step :: proc(
	ui: ^UI,
	text: string,
	i: int,
	p: ^Span_Pen,
	base: ^Font,
	px: f32,
) -> (
	adv: f32,
	next: int,
) {
	if text[i] == '`' {
		p.code = !p.code
		return CODE_EDGE, i + 1
	}
	if i + 1 < len(text) && text[i] == '*' && text[i + 1] == '*' {
		p.bold = !p.bold
		return 0, i + 2
	}
	step := 1
	for i + step < len(text) && (text[i + step] & 0xc0) == 0x80 do step += 1
	r, _ := decode_first(text[i:])
	f, size := span_font(ui, p^, base, px)
	return font_glyph(f, r).advance * font_scale(f, size), i + step
}

// What a laid-out line comes to on screen, spans and all. `pen` is the face
// the line opens in — `Line.pen`, which the wrap wrote — because a span that
// was still open where the line above was cut carries on into this one.
md_line_width :: proc(ui: ^UI, text: string, base: ^Font, px: f32, pen := Span_Pen{}) -> f32 {
	w: f32
	p := pen
	i := 0
	for i < len(text) {
		adv, next := span_step(ui, text, i, &p, base, px)
		w += adv
		i = next
	}
	return w
}

line_style_font :: proc(ui: ^UI, style: Line_Style) -> (^Font, f32, f32) {
	switch style {
	case .Code:
		return &ui.mono, CODE_PX, CODE_LH
	case .Heading:
		return &ui.bold, HEAD_PX, HEAD_LH
	case .Bold:
		return &ui.bold, BODY_PX, BODY_LH
	case .Table:
		return &ui.regular, TABLE_PX, TABLE_LH
	case .Body, .Bullet, .Quote:
		return &ui.regular, BODY_PX, BODY_LH
	}
	return &ui.regular, BODY_PX, BODY_LH
}

// Lays the block out at `width` if it has not been laid out at that width
// already, or if more text has arrived since.
md_layout :: proc(ui: ^UI, b: ^Block, width: f32) {
	text := block_text(b)
	if b.wrap_w == width && b.wrap_len == len(text) && len(b.lines) > 0 do return
	b.wrap_w = width
	b.wrap_len = len(text)
	clear(&b.lines)

	in_code := false
	it := each_line(text)
	for {
		// `it.rest` is a suffix of `text`, so how far the walk has got is
		// len(text) - len(it.rest) — which is how a table, whose Line is the
		// whole run of rows at once, gets a slice of the block's own text
		// without any of it being copied.
		before := len(text) - len(it.rest)
		line, more := iter_next(&it)
		if !more do break

		if strings.has_prefix(strings.trim_left_space(line), "```") {
			in_code = !in_code
			continue
		}
		if in_code {
			wrap_into(ui, &b.lines, line, width - 20, .Code, 10)
			continue
		}

		trimmed := strings.trim_left_space(line)
		if trimmed == "" {
			append(&b.lines, Line{text = "", style = .Body})
			continue
		}
		indent := f32(len(line) - len(trimmed)) * 3

		// A pipe table, if the line after this one is the rule row. Nothing
		// short of the rule row makes a table: a sentence with a pipe in it is
		// a sentence, and treating it as a header is how a paragraph loses its
		// second half to a column nobody asked for.
		if md_is_table_row(line) {
			peek := it
			rule, ok := iter_next(&peek)
			if ok && md_is_table_rule(rule) {
				it = peek
				end := len(text) - len(it.rest)
				for {
					after := it
					next, ok2 := iter_next(&after)
					if !ok2 || !md_is_table_row(next) do break
					it = after
					end = len(text) - len(it.rest)
				}
				for end > before && (text[end - 1] == '\n' || text[end - 1] == '\r') do end -= 1
				append(&b.lines, Line{text = text[before:end], style = .Table, indent = indent})
				continue
			}
		}

		switch {
		case strings.has_prefix(trimmed, "#"):
			body := strings.trim_left(trimmed, "#")
			wrap_into(ui, &b.lines, strings.trim_left_space(body), width, .Heading, indent)
		case strings.has_prefix(trimmed, "- "), strings.has_prefix(trimmed, "* "),
		     is_ordered_item(trimmed):
			_, _, gutter := md_marker(ui, trimmed)
			wrap_into(ui, &b.lines, trimmed, width - indent - gutter, .Bullet, indent + gutter)
		case strings.has_prefix(trimmed, "> "):
			wrap_into(ui, &b.lines, trimmed[2:], width - 12, .Quote, indent + 12)
		case:
			wrap_into(ui, &b.lines, line, width - indent, .Body, indent)
		}
	}

	h: f32
	for l in b.lines do h += md_line_height(ui, l, width)
	b.height = h
}

// The marker a list line opens with, and how far left of the text it hangs.
//
// The gutter was a flat 12 pixels, which is a dash and a space and nothing
// more. A numbered list drew "1. " into it, ran over the right edge of it and
// printed the number on top of the first word — the screenshot that started
// this had "1Tick 300 is far outside" in it. So an ordered list is measured,
// and measured against "99." rather than its own number, so that the text of
// every item in a list up to two digits starts in the same column instead of
// stepping right when the count reaches ten.
@(private = "file")
md_marker :: proc(ui: ^UI, s: string) -> (marker: string, skip: int, gutter: f32) {
	skip = 2
	ordered := is_ordered_item(s)
	if ordered {
		skip = 0
		for skip < len(s) && s[skip] != ' ' do skip += 1
		skip += 1
	}
	skip = min(skip, len(s))
	// The space a marker is written with is not part of the marker: the gutter
	// is what puts air between the two, and drawing the space as well would
	// put that air in twice.
	marker = strings.trim_right_space(s[:skip])
	gutter = 12
	if ordered {
		font, px, _ := line_style_font(ui, .Bullet)
		// Against "99." rather than the item's own number, so the tenth item
		// does not step right while the nine above it stay put.
		w := max(md_line_width(ui, marker, font, px), md_line_width(ui, "99.", font, px))
		gutter = max(gutter, w + 5)
	}
	return
}

@(private = "file")
is_ordered_item :: proc(s: string) -> bool {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
	return i > 0 && i + 1 < len(s) && (s[i] == '.' || s[i] == ')') && s[i + 1] == ' '
}

// Greedy word wrap. Words longer than the line (a URL, a path) are broken.
@(private = "file")
wrap_into :: proc(
	ui: ^UI,
	out: ^[dynamic]Line,
	text: string,
	width: f32,
	style: Line_Style,
	indent: f32,
) {
	font, px, _ := line_style_font(ui, style)
	if width <= 20 {
		append(out, Line{text = text, style = style, indent = indent})
		return
	}

	// Only the first line of a wrapped bullet carries the marker. The rest are
	// ordinary body lines at the same indent, which is both how a list is
	// meant to look and the only way md_draw_line's marker slice stays on a
	// rune boundary: it takes the first two bytes, and two bytes into a
	// continuation line is as likely to be the middle of an em dash as the
	// "- " it is looking for.
	st := style
	emit :: proc(
		out: ^[dynamic]Line,
		st: ^Line_Style,
		text: string,
		indent: f32,
		pen: Span_Pen,
	) {
		append(out, Line{text = text, style = st^, indent = indent, pen = pen})
		if st^ == .Bullet do st^ = .Body
	}

	// The whole line if it fits, and the walk is the same one either way: the
	// fast path here used to measure the line with a plain font_width, which
	// is a second opinion about how wide a line is and was the wrong one for
	// any line with a span in it.
	start := 0
	last_break := -1
	w: f32
	i := 0
	p: Span_Pen // the face at `i`
	line_pen: Span_Pen // the face the line beginning at `start` opened in
	break_pen: Span_Pen // the face at `last_break`
	for i < len(text) {
		ch := text[i]
		// The face before this character is what a cut here would carry over,
		// and span_step is about to move past it: a backtick at `i` toggles
		// the pen, and the line that starts at `i` starts before the toggle.
		here := p
		cw, next := span_step(ui, text, i, &p, font, px)

		if w + cw > width && i > start {
			cut := last_break > start ? last_break : i
			cut_pen := last_break > start ? break_pen : here
			emit(out, &st, text[start:cut], indent, line_pen)
			start = cut
			for start < len(text) && text[start] == ' ' do start += 1
			last_break = -1
			// The wrap used to reset to the plain face here and md_draw_line
			// used to start every line plain to match, so a code span cut
			// across a wrap did not merely lose its box on the second line:
			// its closing backtick turned code *on*, and every span after it
			// in the paragraph came out inverted — the words between the
			// spans boxed and the spans themselves bare. The pen carries over
			// instead, and the line remembers the one it opened in.
			line_pen = cut_pen
			p = cut_pen
			// The box a span is drawn in hangs CODE_EDGE off each end and the
			// wrap counts it a backtick at a time. A span carried over the cut
			// left its opening backtick on the line above, so the left edge is
			// charged here or the box overhangs the width the line was fitted
			// to.
			w = line_pen.code ? CODE_EDGE : 0
			i = start
			continue
		}
		if ch == ' ' {
			last_break = i + 1
			break_pen = p
		}
		w += cw
		i = next
	}
	if start < len(text) {
		emit(out, &st, text[start:], indent, line_pen)
	}
}

@(private = "file")
decode_first :: proc(s: string) -> (rune, int) {
	for r, i in s do return r, i
	return ' ', 1
}

// Draws one laid-out line, handling `code` and **bold** spans inline. Returns
// the line's height so the caller can advance.
md_draw_line :: proc(ui: ^UI, l: Line, x, y, width: f32, col: Color, dim: Color) -> f32 {
	// A table is the whole of its Line and lays itself out from its own text.
	if l.style == .Table do return md_draw_table(ui, l, x, y, width, col)

	font, px, lh := line_style_font(ui, l.style)
	pen := x + l.indent

	if l.style == .Code {
		ui_rect(ui, {x, y, width, lh}, CODE_BG, NO_ROUND)
	}
	if l.style == .Quote {
		ui_rect(ui, {x + l.indent - 10, y + 2, 2, lh - 4}, ACCENT_DIM, 1)
	}
	if l.text == "" do return lh

	text := l.text
	if l.style == .Bullet {
		// Draw the marker in the accent colour, in the gutter the wrap left
		// for it. The gutter has to be the one md_layout reserved or the two
		// disagree, which is why both ask md_marker rather than either
		// writing the width down.
		marker, skip, gutter := md_marker(ui, text)
		ui_text(ui, font, marker, {pen - gutter, y}, px, ACCENT)
		text = text[skip:]
	}

	// Not `Span_Pen{}`: a line opens in whatever face the wrap left open at
	// the cut above it, which is the whole of what Line.pen is for.
	md_draw_spans(ui, text, pen, y, font, px, col, l.pen)
	return lh
}

// Draws a run of text with its inline spans — ** toggles bold, ` toggles mono
// — and answers how far the pen moved. The markers themselves are not drawn,
// which is why wrapping measures them with the same walk (span_step): the wrap
// and the draw agreeing about what a line comes to is the only reason text
// stays inside its bubble.
//
// A table cell draws through here too, which is why this is a proc of its own
// and not the tail of md_draw_line: a cell is a run of markdown that is not a
// line, and the alternative was a second span walk that would have drifted
// from this one the first time either was touched.
md_draw_spans :: proc(
	ui: ^UI,
	text: string,
	x, y: f32,
	base: ^Font,
	px: f32,
	col: Color,
	start_pen := Span_Pen{},
) -> f32 {
	pen := x
	bold := start_pen.bold
	code := start_pen.code
	seg_start := 0
	i := 0
	flush :: proc(ui: ^UI, s: string, pen: ^f32, y: f32, bold, code: bool, col: Color, base: ^Font, px: f32) {
		if s == "" do return
		f := base
		c := col
		size := px
		if code {
			f = &ui.mono
			c = CODE_TEXT
			size = px - 1
		} else if bold {
			f = &ui.bold
		}
		if code {
			w := font_width(f, s, size)
			ui_rect(ui, {pen^ - 2, y + 1, w + 4, size + 7}, CODE_BG, 3)
		}
		pen^ += ui_text(ui, f, s, {pen^, y}, size, c)
	}

	for i < len(text) {
		if text[i] == '`' {
			flush(ui, text[seg_start:i], &pen, y, bold, code, col, base, px)
			code = !code
			i += 1
			seg_start = i
			continue
		}
		if i + 1 < len(text) && text[i] == '*' && text[i + 1] == '*' {
			flush(ui, text[seg_start:i], &pen, y, bold, code, col, base, px)
			bold = !bold
			i += 2
			seg_start = i
			continue
		}
		i += 1
	}
	flush(ui, text[seg_start:], &pen, y, bold, code, col, base, px)
	return pen - x
}


// ---------------------------------------------------------------- tables ---
//
// A GFM pipe table is laid out as a single Line whose text is the whole table,
// rule row and all, sliced straight out of the block. It is one Line and not
// one per row because a table's column widths are one answer for the table:
// the width of the second column is the widest second cell in it, which no
// single row knows. A row that carried its own copy of the widths would be a
// second opinion about where the column starts, and the row that got it wrong
// is the one drawn a pixel out of line with the row above.
//
// So nothing about the shape is written down. md_table works it out from the
// text every time it is asked, and both the height (md_line_height) and the
// drawing (md_draw_table) ask it, so the space a table is given and the space
// it fills cannot disagree. It costs a measure of every cell per frame, which
// for the handful of rows a table has is nothing beside the wrap it replaces.

Table_Align :: enum {
	Left,
	Center,
	Right,
}

Table :: struct {
	ncols:  int,
	rows:   int, // rows that get drawn: the rule row is not one of them
	width:  [MD_TABLE_COLS]f32,
	align:  [MD_TABLE_COLS]Table_Align,
	height: f32,
}

// The cells of one row. The outer pipes are optional in GFM and both forms
// turn up, so a leading and a trailing one are dropped rather than counted as
// empty cells. A pipe inside a `code` span is text: `a | b` in a cell is one
// cell, and splitting on it blindly is how a table of shell snippets comes out
// with a ragged extra column.
md_table_cells :: proc(row: string, out: ^[MD_TABLE_COLS]string) -> int {
	s := strings.trim_space(row)
	if strings.has_prefix(s, "|") do s = s[1:]
	if strings.has_suffix(s, "|") do s = s[:len(s) - 1]

	n := 0
	start := 0
	code := false
	for i in 0 ..< len(s) {
		if s[i] == '`' do code = !code
		if s[i] == '|' && !code && n < MD_TABLE_COLS - 1 {
			out[n] = strings.trim_space(s[start:i])
			n += 1
			start = i + 1
		}
	}
	out[n] = strings.trim_space(s[start:])
	return n + 1
}

// Any line with a pipe in it can be a row; what makes it a table is the rule
// row under the header, which is the only part of the syntax that cannot be
// anything else.
md_is_table_row :: proc(line: string) -> bool {
	t := strings.trim_space(line)
	if t == "" do return false
	if strings.has_prefix(t, "```") do return false
	return strings.index_byte(t, '|') >= 0
}

// `|---|:--:|---:|`. The pipe is required: a bare `---` is a horizontal rule
// and a `- foo` list marker is not a rule row either.
md_is_table_rule :: proc(line: string) -> bool {
	if strings.index_byte(line, '|') < 0 do return false
	cells: [MD_TABLE_COLS]string
	n := md_table_cells(line, &cells)
	for i in 0 ..< n {
		c := cells[i]
		dashes := 0
		for j in 0 ..< len(c) {
			switch c[j] {
			case '-':
				dashes += 1
			case ':':
			case:
				return false
			}
		}
		if dashes == 0 do return false
	}
	return n > 0
}

// Everything about how the table sits on screen, worked out from the table.
// Columns are as wide as their widest cell and no wider; a table that comes to
// more than the width it is given has every column scaled to fit, because a
// column dropped off the right edge is a column the reader never learns is
// there.
md_table :: proc(ui: ^UI, text: string, width: f32) -> (t: Table) {
	cells: [MD_TABLE_COLS]string
	head := true
	it := each_line(text)
	for row in iter_next(&it) {
		if strings.trim_space(row) == "" do continue
		if md_is_table_rule(row) {
			n := md_table_cells(row, &cells)
			for i in 0 ..< n {
				c := cells[i]
				left := strings.has_prefix(c, ":")
				right := strings.has_suffix(c, ":")
				t.align[i] = left && right ? .Center : right ? .Right : .Left
			}
			continue
		}
		// The header is set in the bold face and is measured in it: measuring
		// it in the body face is the same mistake the wrap made about inline
		// code, one face deciding how wide another one draws.
		font := head ? &ui.bold : &ui.regular
		n := md_table_cells(row, &cells)
		for i in 0 ..< n {
			w := md_line_width(ui, cells[i], font, TABLE_PX) + 2 * TABLE_PAD
			t.width[i] = max(t.width[i], w)
		}
		t.ncols = max(t.ncols, n)
		t.rows += 1
		head = false
	}

	sum: f32
	for i in 0 ..< t.ncols do sum += t.width[i]
	if sum > width && width > 0 {
		k := width / sum
		for i in 0 ..< t.ncols do t.width[i] *= k
	}
	t.height = 2 * TABLE_GAP + f32(t.rows) * TABLE_LH
	return
}

// How tall a laid-out line is. Every style but .Table answers with its line
// height; a table answers with its own, which is the number of rows it has.
md_line_height :: proc(ui: ^UI, l: Line, width: f32) -> f32 {
	if l.style == .Table do return md_table(ui, l.text, width - l.indent).height
	_, _, lh := line_style_font(ui, l.style)
	return lh
}

md_draw_table :: proc(ui: ^UI, l: Line, x, y, width: f32, col: Color) -> f32 {
	t := md_table(ui, l.text, width - l.indent)
	left := x + l.indent
	total: f32
	for i in 0 ..< t.ncols do total += t.width[i]

	cells: [MD_TABLE_COLS]string
	ry := y + TABLE_GAP
	r := 0
	it := each_line(l.text)
	for row in iter_next(&it) {
		if strings.trim_space(row) == "" do continue
		if md_is_table_rule(row) do continue
		head := r == 0
		font := head ? &ui.bold : &ui.regular
		n := md_table_cells(row, &cells)

		// A rule under the header and nothing else. Lines between the body
		// rows were tried and are not there any more: at an alpha low enough
		// not to fence the table in they were invisible against the bubble,
		// and at one high enough to see they were the loudest thing in it.
		if head do ui_rect(ui, {left, ry + TABLE_LH - 1, total, 1}, BORDER)

		cx := left
		for i in 0 ..< t.ncols {
			cw := t.width[i]
			if i < n && cells[i] != "" {
				avail := cw - 2 * TABLE_PAD
				tw := md_line_width(ui, cells[i], font, TABLE_PX)
				off: f32
				switch t.align[i] {
				case .Left:
				case .Center:
					off = (avail - tw) / 2
				case .Right:
					off = avail - tw
				}
				// A cell too long for its column is cut off at the column,
				// not run into the one beside it: the scissor is what keeps a
				// squeezed table readable rather than overlapping.
				ui_push_clip(ui, {cx, ry, cw, TABLE_LH})
				md_draw_spans(
					ui,
					cells[i],
					cx + TABLE_PAD + max(off, 0),
					// High enough in the row that the box behind an inline
					// code span clears the bottom of it: the box hangs seven
					// pixels below the size it is set at, and the scissor
					// would cut its rounded corners off.
					ry + (TABLE_LH - TABLE_PX) * 0.5 - 2,
					font,
					TABLE_PX,
					col,
					Span_Pen{},
				)
				ui_pop_clip(ui)
			}
			cx += cw
		}
		ry += TABLE_LH
		r += 1
	}
	return t.height
}
