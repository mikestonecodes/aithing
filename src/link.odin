package aithing

import "core:os"
import "core:strings"

// A web address in an answer, found where it is drawn. Nothing about links is
// written down at layout: the wrap cuts a paragraph into lines and each line
// keeps the paragraph it was cut from (Line.src), so a link is worked out from
// that paragraph every time it is drawn. That is what lets a URL too long for
// the bubble — which the wrap breaks mid-word — open as the whole address from
// either half of it, rather than as the half on the line that was clicked.

LINK :: BLUE

// The next http(s) address in `s` at or after `from`, as byte offsets.
link_next :: proc(s: string, from: int) -> (start, end: int, ok: bool) {
	i := from
	for i < len(s) {
		j := strings.index(s[i:], "http")
		if j < 0 do return
		start = i + j
		i = start + 4
		rest := s[start:]
		if !strings.has_prefix(rest, "http://") && !strings.has_prefix(rest, "https://") do continue
		// The start of a word, and not the tail of one: `xhttp://` is not an
		// address anybody meant.
		if start > 0 && link_char(s[start - 1]) && !strings.contains_rune("([<`\"'*_", rune(s[start - 1])) do continue

		end = start
		for end < len(s) && link_char(s[end]) do end += 1
		end = link_trim(s[start:end]) + start
		if end - start <= len("https://") do continue
		return start, end, true
	}
	return
}

// What may appear in an address as it is written in prose. A backtick, a
// quote and angle brackets close one, and so does `*`, because `**https://…**`
// is an address in bold and the markers are not part of it.
@(private = "file")
link_char :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', '`', '"', '<', '>', '*':
		return false
	}
	return true
}

// The sentence an address ends is not part of it: the full stop after one, or
// the bracket closing `(see https://…)` and the markdown `[text](https://…)`.
// A bracket the address opened itself stays, which is every Wikipedia page
// named for something with a parenthesis in it.
@(private = "file")
link_trim :: proc(u: string) -> int {
	n := len(u)
	for n > 0 {
		switch u[n - 1] {
		case '.', ',', ';', ':', '!', '?', '\'':
			n -= 1
			continue
		case ')':
			if strings.count(u[:n], "(") < strings.count(u[:n], ")") {
				n -= 1
				continue
			}
		case ']':
			if strings.count(u[:n], "[") < strings.count(u[:n], "]") {
				n -= 1
				continue
			}
		}
		break
	}
	return n
}

// Draws `s` in one face, with whatever part of it is a link in `src` set in
// the link colour, underlined, and opened by a click. `s` is a slice of `src`:
// the run being drawn is some of a line, and the line is some of the paragraph
// the address was written in.
link_draw_run :: proc(
	ui: ^UI,
	s: string,
	at: [2]f32,
	f: ^Font,
	size: f32,
	col: Color,
	src: string,
) -> f32 {
	base := int(uintptr(raw_data(s))) - int(uintptr(raw_data(src)))
	if s == "" || base < 0 || base + len(s) > len(src) || strings.index(src, "://") < 0 {
		return ui_text(ui, f, s, at, size, col)
	}
	x := at.x
	done := 0
	from := 0
	for {
		start, end, ok := link_next(src, from)
		if !ok || start >= base + len(s) do break
		from = end
		if end <= base + done do continue
		a := max(start - base, done)
		b := min(end - base, len(s))
		x += ui_text(ui, f, s[done:a], {x, at.y}, size, col)
		w := font_width(f, s[a:b], size)
		link_hit(ui, {x, at.y, w, size + 7}, src[start:end], size)
		x += ui_text(ui, f, s[a:b], {x, at.y}, size, LINK)
		done = b
	}
	x += ui_text(ui, f, s[done:], {x, at.y}, size, col)
	return x - at.x
}

// The part of a link drawn at `r`. Every part of one address answers to one
// id, so pressing the first half of a broken URL and letting go on the second
// is a click, and it opens once.
@(private = "file")
link_hit :: proc(ui: ^UI, r: Rect, url: string, size: f32) {
	id := ui_id_ptr(raw_data(url), len(url))
	// The text is drawn over whatever it sits in — a stone's panel, which
	// takes a press anywhere on it to unfold itself — and that was drawn
	// first, so it has already taken the press. The link takes it back, the
	// way a popup does (ui_claim), or no link inside a panel could be clicked.
	over := ui.has_mouse && rect_contains(rect_intersect(r, ui.clip), ui.mouse)
	if ui.pressed && over do ui.active = 0
	clicked, hovered := ui_invisible_button(ui, id, r)
	ui_rect(ui, {r.x, r.y + size + 3, r.w, 1}, color_alpha(LINK, hovered ? 1 : 0.45))
	// Super+C over an address copies the address, not the paragraph it is in.
	ui_hover_text(ui, r, url)
	if clicked do link_open(url)
}

// Hands the address to the desktop. Through a shell that backgrounds the
// opener and exits, so the one process waited on here is gone in a moment and
// the browser it starts is not a child of this one: xdg-open can block for as
// long as the browser it launched stays open, and waiting on that would stop
// the window.
link_open :: proc(url: string) {
	desc := os.Process_Desc {
		command = {"sh", "-c", `xdg-open "$1" >/dev/null 2>&1 &`, "sh", url},
	}
	if p, err := os.process_start(desc); err == nil {
		_, _ = os.process_wait(p)
	}
}
