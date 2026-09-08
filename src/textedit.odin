package aithing

import "core:strings"
import "core:unicode/utf8"

// The composer's text box. There is no widget tree to hang state off, so the
// editor is a plain struct the caller owns: a byte buffer, a cursor, a
// selection anchor, and the line ranges the last layout produced.

Editor :: struct {
	buf:      strings.Builder,
	cursor:   int, // byte offset
	anchor:   int, // the other end of the selection; equal to cursor when none
	lines:    [dynamic]Span, // byte ranges of the wrapped lines, rebuilt on draw
	last_edit: f32, // ui.time of the last change, so the caret stops blinking
}

Span :: struct {
	start, end: int,
}

editor_text :: proc(e: ^Editor) -> string {
	return strings.to_string(e.buf)
}

editor_destroy :: proc(e: ^Editor) {
	strings.builder_destroy(&e.buf)
	delete(e.lines)
}

editor_clear :: proc(e: ^Editor) {
	strings.builder_reset(&e.buf)
	e.cursor, e.anchor = 0, 0
}

editor_selection :: proc(e: ^Editor) -> (lo, hi: int) {
	lo, hi = e.cursor, e.anchor
	if lo > hi do lo, hi = hi, lo
	return
}

editor_has_selection :: proc(e: ^Editor) -> bool {
	return e.cursor != e.anchor
}

editor_set_text :: proc(e: ^Editor, text: string) {
	strings.builder_reset(&e.buf)
	strings.write_string(&e.buf, text)
	e.cursor = len(text)
	e.anchor = e.cursor
}

@(private = "file")
delete_selection :: proc(e: ^Editor) -> bool {
	if !editor_has_selection(e) do return false
	lo, hi := editor_selection(e)
	text := editor_text(e)
	rest := strings.clone(text[hi:], context.temp_allocator)
	strings.builder_reset(&e.buf)
	strings.write_string(&e.buf, text[:lo])
	strings.write_string(&e.buf, rest)
	e.cursor, e.anchor = lo, lo
	return true
}

editor_insert :: proc(e: ^Editor, s: string) {
	delete_selection(e)
	text := editor_text(e)
	tail := strings.clone(text[e.cursor:], context.temp_allocator)
	strings.builder_reset(&e.buf)
	strings.write_string(&e.buf, text[:e.cursor])
	strings.write_string(&e.buf, s)
	strings.write_string(&e.buf, tail)
	e.cursor += len(s)
	e.anchor = e.cursor
}

// Byte offset one rune to the left/right of `at`.
prev_rune :: proc(s: string, at: int) -> int {
	if at <= 0 do return 0
	i := at - 1
	for i > 0 && (s[i] & 0xc0) == 0x80 do i -= 1
	return i
}

next_rune :: proc(s: string, at: int) -> int {
	if at >= len(s) do return len(s)
	_, size := utf8.decode_rune_in_string(s[at:])
	return min(at + max(size, 1), len(s))
}

@(private = "file")
is_word :: proc(c: byte) -> bool {
	return(
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '_' ||
		c >= 0x80 \
	)
}

word_left :: proc(s: string, at: int) -> int {
	i := at
	for i > 0 && !is_word(s[i - 1]) do i -= 1
	for i > 0 && is_word(s[i - 1]) do i -= 1
	return i
}

word_right :: proc(s: string, at: int) -> int {
	i := at
	for i < len(s) && !is_word(s[i]) do i += 1
	for i < len(s) && is_word(s[i]) do i += 1
	return i
}

line_start :: proc(s: string, at: int) -> int {
	i := at
	for i > 0 && s[i - 1] != '\n' do i -= 1
	return i
}

line_end :: proc(s: string, at: int) -> int {
	i := at
	for i < len(s) && s[i] != '\n' do i += 1
	return i
}

// Which laid-out line a byte offset falls on, and how far into it.
editor_locate :: proc(e: ^Editor, at: int) -> (line: int, offset: int) {
	for span, i in e.lines {
		if at >= span.start && at <= span.end do return i, at - span.start
	}
	return max(len(e.lines) - 1, 0), 0
}

// Moves the cursor by whole laid-out lines, keeping roughly the same column.
editor_move_line :: proc(e: ^Editor, delta: int, select: bool) {
	if len(e.lines) == 0 do return
	line, offset := editor_locate(e, e.cursor)
	target := clamp(line + delta, 0, len(e.lines) - 1)
	if target == line do return
	span := e.lines[target]
	e.cursor = clamp(span.start + offset, span.start, span.end)
	if !select do e.anchor = e.cursor
}

// Which of the wrapped lines a box that is only so tall actually shows.
// Every box goes through here twice — once to work out how tall to be, once to
// draw — so the two can never disagree, which is what left a box measured at
// six lines drawing ten of them out through its own bottom edge.
//
// Nothing is remembered: the window is worked out from where the caret is, so
// there is no scroll offset to keep in step with an edit that moved it.
editor_window :: proc(e: ^Editor, max_lines: int) -> (first, count: int) {
	n := max(len(e.lines), 1)
	count = min(n, max(max_lines, 1))
	line, _ := editor_locate(e, e.cursor)
	first = clamp(line - count + 1, 0, n - count)
	return
}

Editor_Action :: enum {
	None,
	Submit,
	Cancel,
	Copy,
	Cut,
	Paste,
	Stop, // ctrl c, which is not copy here: see below
}

// Applies one key press. Text itself arrives separately, as UTF-8, because the
// compositor sends keycodes and the layout table turns those into characters.
editor_key :: proc(e: ^Editor, k: Key, time_now: f32) -> Editor_Action {
	// No caret anywhere — a grid of every project has no box on it. The keys
	// that are not about text still mean what they mean, and they are
	// answered here rather than in a second switch beside the caller: there
	// was one of those once, for the grid that had no box, and being a copy
	// it drifted — paste and cut only ever reached one of them.
	if e == nil {
		switch k.code {
		case KEY_ENTER, KEY_KPENTER:
			return .Submit
		case KEY_ESC:
			return .Cancel
		case KEY_C:
			if .Super in k.mods do return .Copy
			if .Ctrl in k.mods do return .Stop
		case KEY_INSERT:
			if .Ctrl in k.mods do return .Copy
		}
		return .None
	}
	text := editor_text(e)
	select := .Shift in k.mods
	ctrl := .Ctrl in k.mods
	// Copy, cut and paste are super, the way they are on a Mac and the way
	// every browser and terminal on Linux ends up wanting them once ctrl c
	// means something else. Here ctrl c means stop, which is the one thing it
	// means everywhere a program can be interrupted.
	super := .Super in k.mods
	e.last_edit = time_now

	switch k.code {
	case KEY_ENTER, KEY_KPENTER:
		// Enter sends; shift-enter is a newline, the way every chat client does it.
		if .Shift in k.mods {
			editor_insert(e, "\n")
			return .None
		}
		return .Submit
	case KEY_ESC:
		return .Cancel
	case KEY_BACKSPACE:
		if delete_selection(e) do return .None
		if e.cursor > 0 {
			from := ctrl ? word_left(text, e.cursor) : prev_rune(text, e.cursor)
			e.anchor = from
			delete_selection(e)
		}
		return .None
	case KEY_DELETE:
		if delete_selection(e) do return .None
		if e.cursor < len(text) {
			e.anchor = ctrl ? word_right(text, e.cursor) : next_rune(text, e.cursor)
			delete_selection(e)
		}
		return .None
	case KEY_LEFT:
		e.cursor = ctrl ? word_left(text, e.cursor) : prev_rune(text, e.cursor)
		if !select do e.anchor = e.cursor
		return .None
	case KEY_RIGHT:
		e.cursor = ctrl ? word_right(text, e.cursor) : next_rune(text, e.cursor)
		if !select do e.anchor = e.cursor
		return .None
	case KEY_UP:
		editor_move_line(e, -1, select)
		return .None
	case KEY_DOWN:
		editor_move_line(e, 1, select)
		return .None
	case KEY_HOME:
		e.cursor = ctrl ? 0 : line_start(text, e.cursor)
		if !select do e.anchor = e.cursor
		return .None
	case KEY_END:
		e.cursor = ctrl ? len(text) : line_end(text, e.cursor)
		if !select do e.anchor = e.cursor
		return .None
	case KEY_A:
		if super || ctrl {
			e.anchor, e.cursor = 0, len(text)
			return .None
		}
	case KEY_C:
		if super do return .Copy
		if ctrl do return .Stop
	case KEY_X:
		// Ctrl cuts here and nowhere else in this program, because a
		// compositor asked to type a cut types ctrl and the letter x — niri's
		// `Mod+X { spawn "wtype" "-M" "ctrl" "-k" "x"; }`. It collides with
		// nothing: ctrl c is the only ctrl key the clipboard would fight over,
		// and that one stays stop.
		if super || ctrl do return .Cut
	case KEY_V:
		if super do return .Paste
	case KEY_INSERT:
		// The clipboard's other name, the one every terminal answers to and
		// the one a compositor binding reaches for when it wants a copy that
		// works in a terminal and a browser alike.
		if ctrl do return .Copy
		if select do return .Paste
	}
	return .None
}

editor_delete_selection :: proc(e: ^Editor) -> bool {
	return delete_selection(e)
}
