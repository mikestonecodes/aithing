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
	for raw in strings_lines(text) {
		line := raw
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
	if font_width(font, text, px) <= width {
		append(out, Line{text = text, style = style, indent = indent})
		return
	}

	start := 0
	last_break := -1
	w: f32
	i := 0
	for i < len(text) {
		ch := text[i]
		step := 1
		for i + step < len(text) && (text[i + step] & 0xc0) == 0x80 do step += 1
		r, _ := decode_first(text[i:])
		cw := font.chars[glyph_index(r)].xadvance * font_scale(font, px)

		if w + cw > width && i > start {
			cut := last_break > start ? last_break : i
			append(out, Line{text = text[start:cut], style = style, indent = indent})
			start = cut
			for start < len(text) && text[start] == ' ' do start += 1
			last_break = -1
			w = 0
			i = start
			continue
		}
		if ch == ' ' do last_break = i + 1
		w += cw
		i += step
	}
	if start < len(text) {
		append(out, Line{text = text[start:], style = style, indent = indent})
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

md_height :: proc(ui: ^UI, b: ^Block, width: f32) -> f32 {
	md_layout(ui, b, width)
	return b.height
}
