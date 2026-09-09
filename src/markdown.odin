package aithing

import "core:strings"

// Just enough Markdown to make an answer readable: headings, bullets, block
// quotes, fenced code, and inline `code` and **bold**. Wrapping happens once
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

// What a laid-out line comes to on screen, spans and all. A line starts in the
// plain face however the one above it ended: md_draw_line resets at every
// line, so a span broken across a wrap is drawn plain on the second line, and
// this measures it the same way.
md_line_width :: proc(ui: ^UI, text: string, base: ^Font, px: f32) -> f32 {
	w: f32
	p: Span_Pen
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
	for line in iter_next(&it) {
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

		switch {
		case strings.has_prefix(trimmed, "#"):
			body := strings.trim_left(trimmed, "#")
			wrap_into(ui, &b.lines, strings.trim_left_space(body), width, .Heading, indent)
		case strings.has_prefix(trimmed, "- "), strings.has_prefix(trimmed, "* "):
			wrap_into(ui, &b.lines, trimmed, width - indent - 12, .Bullet, indent + 12)
		case strings.has_prefix(trimmed, "> "):
			wrap_into(ui, &b.lines, trimmed[2:], width - 12, .Quote, indent + 12)
		case is_ordered_item(trimmed):
			wrap_into(ui, &b.lines, trimmed, width - indent - 12, .Bullet, indent + 12)
		case:
			wrap_into(ui, &b.lines, line, width - indent, .Body, indent)
		}
	}

	h: f32
	for l in b.lines {
		_, _, lh := line_style_font(ui, l.style)
		h += lh
	}
	b.height = h
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
	emit :: proc(out: ^[dynamic]Line, st: ^Line_Style, text: string, indent: f32) {
		append(out, Line{text = text, style = st^, indent = indent})
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
	p: Span_Pen
	for i < len(text) {
		ch := text[i]
		cw, next := span_step(ui, text, i, &p, font, px)

		if w + cw > width && i > start {
			cut := last_break > start ? last_break : i
			emit(out, &st, text[start:cut], indent)
			start = cut
			for start < len(text) && text[start] == ' ' do start += 1
			last_break = -1
			w = 0
			i = start
			// A line is drawn from its own beginning in the plain face, so
			// the next one is measured from there too.
			p = {}
			continue
		}
		if ch == ' ' do last_break = i + 1
		w += cw
		i = next
	}
	if start < len(text) {
		emit(out, &st, text[start:], indent)
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
		// Draw the marker in the accent colour and indent the rest of the text.
		marker_len := 2
		if is_ordered_item(text) {
			marker_len = 0
			for marker_len < len(text) && text[marker_len] != ' ' do marker_len += 1
			marker_len += 1
		}
		marker := text[:min(marker_len, len(text))]
		w := ui_text(ui, font, marker, {pen - 12, y}, px, ACCENT)
		_ = w
		text = text[min(marker_len, len(text)):]
	}

	// Inline spans: ** toggles bold, ` toggles mono. The markers themselves are
	// not drawn, which is why wrapping measured them — it only ever leaves the
	// line shorter than it planned for.
	bold := false
	code := false
	seg_start := 0
	i := 0
	flush :: proc(ui: ^UI, s: string, pen: ^f32, y: f32, bold, code: bool, col, dim: Color, base: ^Font, px: f32) {
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
			flush(ui, text[seg_start:i], &pen, y, bold, code, col, dim, font, px)
			code = !code
			i += 1
			seg_start = i
			continue
		}
		if i + 1 < len(text) && text[i] == '*' && text[i + 1] == '*' {
			flush(ui, text[seg_start:i], &pen, y, bold, code, col, dim, font, px)
			bold = !bold
			i += 2
			seg_start = i
			continue
		}
		i += 1
	}
	flush(ui, text[seg_start:], &pen, y, bold, code, col, dim, font, px)
	return lh
}

