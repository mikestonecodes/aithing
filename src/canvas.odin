package aithing

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"

// The home view is a fixed grid: every todo item is a card, cards are grouped
// under the project they belong to, and the whole thing scrolls. Nothing to
// pan, nothing to place, nothing to remember — the same item is in the same
// place every time you look, which is the only thing a map is for.
//
// A card is one piece of work, not one thread: a thread carries several, and
// an agent reads each one and says what they are (see todos.odin). Every card
// says where its work stands — waiting, processing, complete, failed — and
// opening one opens its thread at the message it is about.
//
// The keyboard drives it. Typing goes into the box along the bottom, and what
// is typed there becomes a card a part. `/` opens the launcher, a full-screen
// menu in type big enough to read across the room: the projects first,
// whether or not anything is typed, then the threads. Type to narrow, arrows
// to choose, Enter to open a thread or to filter the grid down to one
// project.

CARD_W :: f32(300) // the width a card wants; the row stretches to fill
CARD_H :: f32(132)
CARD_GAP :: f32(18)
SECTION_HEAD :: f32(52)
SECTION_GAP :: f32(26)
GRID_PAD :: f32(24)
GRID_TOP :: f32(58) // under the line that says which project you are in

// What the grid draws, one per card. `threads` is how many threads say this
// same piece of work is being done: the card is the newest of them.
Card_Ref :: struct {
	todo:    int, // index into app.todos.list
	threads: int,
}

Card :: struct {
	using ref: Card_Ref,
	r:         Rect, // in content space: add the scroll offset to place it
	head:      bool, // a section header rather than a card
	name:      string, // the project, on a header
	count:     int,
}

Canvas :: struct {
	scroll:   Scroll,
	// Scratch, not state: rebuilt from app.todo_view whenever it is out of
	// date. `cards_v` is the app.layout_v it was built at and `cards_w` the
	// width, so canvas_layout can tell. Nothing outside this file may read
	// `cards` without calling canvas_layout first — the indices in it point
	// into app.todos.list, and that list moves.
	cards:    [dynamic]Card,
	cards_v:  int,
	cards_w:  f32,
	// The todos version the indices in `cards` point into. Tying them to it
	// directly is what makes "no index outlives its list" true rather than
	// merely intended: app.layout_v is bumped by app_filter, and a list that
	// lost an entry without one is a bounds trap in canvas_node_rect.
	cards_t:  int,
	content:  f32, // how tall the grid is, from the last layout
	view:     Rect, // the rect the grid was last drawn into
	sel:      string, // the todo id under the keyboard cursor
	project:  string, // only this project's threads, when set
	launcher: bool, // the big menu is up
	menu_at:  int, // which row of it is chosen
	opened:   bool, // a thread is zoomed open over the grid
}

canvas_destroy :: proc(c: ^Canvas) {
	delete(c.cards)
	delete(c.sel)
	delete(c.project)
}

// --- layout ----------------------------------------------------------------

// Fills c.cards for this frame and returns how tall the content is. Sections
// come in the order the sessions do, which is newest first, so the project you
// touched last is the one at the top.
@(private = "file")
grid_layout :: proc(app: ^App, r: Rect) -> f32 {
	c := &app.canvas
	clear(&c.cards)
	c.cards_v = app.layout_v
	c.cards_w = r.w
	c.cards_t = app.todos.ver

	inner := r.w - GRID_PAD * 2
	cols := max(1, int((inner + CARD_GAP) / (CARD_W + CARD_GAP)))
	cw := (inner - CARD_GAP * f32(cols - 1)) / f32(cols)

	// One pass. app.todo_view is already grouped by project and ordered
	// inside each, so a section is a run of it — it used to be a loop over
	// every card with a loop over every card inside it, looking for the ones
	// in the same project.
	y := f32(0)
	head, col, n := -1, 0, 0
	cwd := ""
	for ref in app.todo_view {
		if ref.todo >= len(app.todos.list) do continue
		td := app.todos.list[ref.todo]
		if td.cwd != cwd {
			// Close the section before it off.
			if cwd != "" {
				if col != 0 do y += CARD_H + CARD_GAP
				if head >= 0 do c.cards[head].count = n
				y += SECTION_GAP
			}
			cwd = td.cwd
			col, n, head = 0, 0, -1
			// The first section needs no name over it: there is nothing above
			// it for the name to tell it apart from.
			if len(c.cards) > 0 {
				head = len(c.cards)
				append(&c.cards, Card{head = true, name = filepath.base(cwd), r = {GRID_PAD, y, inner, SECTION_HEAD}})
				y += SECTION_HEAD
			}
		}
		x := GRID_PAD + f32(col) * (cw + CARD_GAP)
		append(&c.cards, Card{ref = ref, r = {x, y, cw, CARD_H}})
		n += 1
		col += 1
		if col == cols {
			col = 0
			y += CARD_H + CARD_GAP
		}
	}
	if cwd != "" {
		if col != 0 do y += CARD_H + CARD_GAP
		if head >= 0 do c.cards[head].count = n
		y += SECTION_GAP
	}
	return y + GRID_PAD
}

// The grid, laid out and current. Everything derived from app.todos.list is
// rebuilt here the moment the list it came from has changed, rather than being
// invalidated by hand at each of the fifteen places that change it: a stale
// index into a list that has since lost an entry is how this used to crash.
// Free when nothing has moved, which is every frame but the ones that did.
canvas_layout :: proc(app: ^App) -> f32 {
	c := &app.canvas
	if app.view_v != app.todos.ver do app_filter(app)
	if c.cards_v != app.layout_v || c.cards_w != c.view.w || c.cards_t != app.todos.ver {
		c.content = grid_layout(app, c.view)
	}
	return c.content
}

// Where the card of a thread is on screen, for the panel that grows out of
// it. A thread has as many cards as it has items; the one under the cursor is
// the one that was opened, and any of them will do otherwise.
canvas_node_rect :: proc(app: ^App, id: string) -> (Rect, bool) {
	c := &app.canvas
	canvas_layout(app)
	best := -1
	for card, ci in c.cards {
		if card.head do continue
		td := app.todos.list[card.todo]
		if td.session != id do continue
		if td.id == c.sel {
			best = ci
			break
		}
		if best < 0 do best = ci
	}
	if best < 0 do return {}, false
	r := c.cards[best].r
	return {r.x, r.y - c.scroll.offset + GRID_TOP, r.w, r.h}, true
}

// --- the grid ---------------------------------------------------------------

draw_canvas :: proc(app: ^App, r: Rect) {
	ui := &app.ui
	c := &app.canvas

	c.view = r
	content := canvas_layout(app)
	// The box along the bottom is always there, so the grid keeps its room
	// clear whether or not anything is being typed into it.
	bottom := capture_height(app, r.w)
	view := Rect{r.x, r.y + GRID_TOP, r.w, r.h - GRID_TOP - bottom}
	canvas_keep_sel_in_view(app, view)

	ui_begin_scroll(ui, view, &c.scroll, content)
	for card in c.cards {
		cr := Rect{card.r.x, card.r.y - c.scroll.offset + view.y, card.r.w, card.r.h}
		if cr.y > view.y + view.h || cr.y + cr.h < view.y do continue
		if card.head {
			draw_section_head(app, card, cr)
		} else {
			draw_card(app, card, cr)
		}
	}
	ui_end_scroll(ui, view, &c.scroll)

	if len(c.cards) == 0 {
		msg := app.scanned ? "nothing here — type below to add a card, / to search" : "reading threads…"
		ui_text_centred(ui, &ui.regular, msg, view, 18, FAINT)
	}
}

@(private = "file")
draw_section_head :: proc(app: ^App, card: Card, r: Rect) {
	ui := &app.ui
	x := ui_text(ui, &ui.bold, card.name, {r.x, r.y + 14}, 22, TEXT) + 12
	ui_text(ui, &ui.regular, fmt.tprintf("%d", card.count), {r.x + x, r.y + 20}, 15, FAINT)
	ui_rect(ui, {r.x, r.y + r.h - 9, r.w, 1}, color_alpha(BORDER, 0.7))
}

@(private = "file")
draw_card :: proc(app: ^App, card: Card, r: Rect) {
	ui := &app.ui
	c := &app.canvas
	td := app.todos.list[card.todo]
	id := ui_id(td.id)
	bid := ui_id(td.id, 1)
	pad := f32(14)
	blocked := c.opened || c.launcher
	// The dismiss button sits on top of the card, so it is offered the
	// pointer first: the card's own button covers the same spot and would
	// otherwise take the press and open the item instead.
	// Square, and the cross drawn in the middle of it: the mark used to sit
	// low and right of a box whose top edge was above the card's padding, so
	// the hotspot was never quite where the x looked.
	btn := Rect{r.x + r.w - pad - 28, r.y + pad - 4, 28, 28}
	over := !blocked && (ui_hovered(ui, r) || ui.active == id || ui.active == bid)
	bclicked: bool
	bhov: bool
	if over do bclicked, bhov = ui_invisible_button(ui, bid, btn)
	clicked: bool
	hovered := over
	if over && !bhov do clicked, _ = ui_invisible_button(ui, id, r)
	selected := c.sel == td.id
	current := td.session != "" && app.chat.session_id == td.session
	state := todo_display_state(app, td)

	lift := ui_anim(ui, id, hovered || selected ? 1 : 0, 18)
	if lift > 0.01 do ui_rect(ui, {r.x + 1, r.y + 4, r.w, r.h}, color_alpha(Color(0xff000000), 0.3 * lift), 12)
	ui_rect(ui, r, color_mix(USER_BG, PANEL_HI, lift * 0.7), 12)
	if selected do ui_rect(ui, r, color_alpha(ACCENT, 0.55), 12)
	if current do ui_rect(ui, {r.x, r.y + 12, 3, r.h - 24}, ACCENT, 2)
	// Work that came back clean is work you are done with: it stays on the
	// map, drawn back, rather than shouting alongside what is still open.
	if state == .Done do ui_rect(ui, r, color_alpha(BG, 0.28), 12)

	tx := r.x + pad
	ty := r.y + pad
	tw := r.w - pad * 2

	// When it last moved, and how many threads say it is being worked on. Both
	// go up in the corner, where "how much" and "when" already live: a card
	// carries the work and its state, and nothing else.
	stamp := ""
	stamp_buf: [16]u8
	if td.session != "" do stamp = relative_time(td.at, stamp_buf[:])
	corner := font_width(&ui.regular, stamp, 12)
	if stamp != "" do ui_text(ui, &ui.regular, stamp, {r.x + r.w - pad - corner, ty + 1}, 12, FAINT)
	if card.threads > 1 {
		// The same work picked up more than once: the card is the newest
		// thread of it, and this is how many there are behind it.
		n := fmt.tprintf("%d threads", card.threads)
		nw := font_width(&ui.regular, n, 11.5)
		corner += nw + 10
		ui_text(ui, &ui.regular, n, {r.x + r.w - pad - corner, ty + 2}, 11.5, FAINT)
	}

	// The item itself, which is the whole point of the card.
	ty += draw_wrapped(ui, &ui.bold, td.text, tx, ty, tw - corner - 10, 15, state == .Done ? MUTED : TEXT, 3)

	// Where the work stands, in the word for it, and where in the queue when
	// that is what it is waiting on. A turn in flight pulses, whether it was
	// started here or in another window.
	label := todo_state_label(state)
	if pos := todo_queue_pos(app, td.batch); state == .Queued && pos > 0 {
		label = pos == 1 ? "next up" : fmt.tprintf("queued · %d", pos)
	}
	col := todo_state_color(state)
	alpha := f32(1)
	if state == .Running {
		pulse := 0.5 + 0.5 * math.sin(ui.time * 5)
		ui.time_effects = true
		alpha = 0.55 + 0.45 * pulse
	}
	// The dot and the word are one thing, centred in the pill. They used to be
	// placed by three numbers that happened to look right at one size, and the
	// word sat low in the pill at every size.
	DOT :: f32(7)
	DOT_GAP :: f32(7)
	lw := font_width(&ui.regular, label, 11.5)
	pill := Rect{tx, r.y + r.h - pad - 20, DOT + DOT_GAP + lw + 20, 20}
	ui_rect(ui, pill, color_alpha(col, 0.16 * alpha), 10)
	cx := pill.x + (pill.w - (DOT + DOT_GAP + lw)) / 2
	ui_circle(ui, {cx + DOT / 2, pill.y + pill.h / 2}, DOT / 2, color_alpha(col, alpha))
	ui_text_middle(ui, &ui.regular, label, cx + DOT + DOT_GAP, pill, 11.5, color_alpha(col, alpha))

	// What the turn is doing right now, beside the pill. This is the whole of
	// what a headless turn shows anyone: there is no transcript on screen for
	// it, and a card that says nothing but `processing` for two minutes is a
	// card you have to open a thread to believe.
	room := r.w - pad * 2 - pill.w - 14
	note, note_col := "", FAINT
	if turn := turn_for_batch(app, td.batch); turn >= 0 {
		note = turn_doing(&app.turns[turn])
	} else if state == .Failed {
		// Why. A headless turn has no transcript to read it out of, and a
		// card that says `failed` and nothing else is a card you cannot act
		// on — which is exactly how it read.
		note = app.notes[td.batch]
		note_col = RED
	}
	if note != "" && room > 40 {
		buf: [192]u8
		note = font_ellipsize(&ui.regular, note, 11.5, room, buf[:])
		nw := font_width(&ui.regular, note, 11.5)
		ui_text_middle(ui, &ui.regular, note, r.x + r.w - pad - nw, pill, 11.5, note_col)
	}

	// Dismissing it, which every card answers to the same way: the card goes
	// and stays gone. The press is only recorded here — the list it would drop
	// an item out of is the one this loop is walking — and app_apply_clicks
	// does the work once the frame is over.
	if hovered {
		ui_rect(ui, btn, bhov ? PANEL_HI : Color(0), 6)
		mark := bhov ? TEXT : MUTED
		ui_line(ui, {btn.x + 9, btn.y + 9}, {btn.x + 19, btn.y + 19}, 2, mark)
		ui_line(ui, {btn.x + 19, btn.y + 9}, {btn.x + 9, btn.y + 19}, 2, mark)
		if bclicked {
			app_dismiss_todo(app, td.id)
			return
		}
	}

	if clicked do app_open_todo(app, td.id)
}

// A few lines of body text, ellipsized on the last. Returns the height.
draw_wrapped :: proc(ui: ^UI, font: ^Font, text: string, x, y, w, size: f32, col: Color, max_lines: int) -> f32 {
	lh := size * 1.45
	rest := text
	line := 0
	for rest != "" && line < max_lines {
		end := 0
		last_fit := 0
		for end < len(rest) {
			next := strings.index_byte(rest[end:], ' ')
			cand := next < 0 ? len(rest) : end + next
			if font_width(font, rest[:cand], size) > w {
				if last_fit == 0 do last_fit = cand // one long word
				break
			}
			last_fit = cand
			end = cand + 1
			if next < 0 do break
		}
		if last_fit == 0 do last_fit = len(rest)
		piece := rest[:last_fit]
		if line == max_lines - 1 && last_fit < len(rest) {
			buf: [512]u8
			piece = font_ellipsize(font, rest, size, w, buf[:])
			ui_text(ui, font, piece, {x, y + f32(line) * lh}, size, col)
			line += 1
			break
		}
		ui_text(ui, font, piece, {x, y + f32(line) * lh}, size, col)
		rest = strings.trim_left_space(rest[last_fit:])
		line += 1
	}
	return f32(line) * lh
}

// --- the keyboard cursor ------------------------------------------------------

@(private = "file")
sel_rect :: proc(app: ^App) -> (Rect, bool) {
	c := &app.canvas
	canvas_layout(app)
	for card in c.cards do if !card.head && app.todos.list[card.todo].id == c.sel do return card.r, true
	return {}, false
}

// Moves the cursor one card in a direction: the nearest card that lies that
// way, measured centre to centre, so a short last row and the gap between two
// projects both behave the way the eye expects.
canvas_move_sel :: proc(app: ^App, dx, dy: int) {
	c := &app.canvas
	canvas_layout(app)
	if len(c.cards) == 0 do return
	from, ok := sel_rect(app)
	if !ok {
		for card in c.cards do if !card.head {
			canvas_set_sel(app, app.todos.list[card.todo].id)
			return
		}
		return
	}
	fc := [2]f32{from.x + from.w / 2, from.y + from.h / 2}
	best := -1
	best_cost := f32(1e18)
	for card, ci in c.cards {
		if card.head do continue
		if app.todos.list[card.todo].id == c.sel do continue
		tc := [2]f32{card.r.x + card.r.w / 2, card.r.y + card.r.h / 2}
		d := tc - fc
		// Must lie in the direction asked for.
		if dx != 0 && (d.x * f32(dx) <= 1 || abs(d.y) > from.h * 0.6) do continue
		if dy != 0 && d.y * f32(dy) <= 1 do continue
		cost := dx != 0 ? abs(d.x) + abs(d.y) * 4 : abs(d.y) + abs(d.x) * 3
		if cost < best_cost {
			best_cost = cost
			best = ci
		}
	}
	if best >= 0 do canvas_set_sel(app, app.todos.list[c.cards[best].todo].id)
}

canvas_set_sel :: proc(app: ^App, id: string) {
	delete(app.canvas.sel)
	app.canvas.sel = strings.clone(id)
}

// Scrolls just enough to keep the chosen card on screen.
@(private = "file")
canvas_keep_sel_in_view :: proc(app: ^App, view: Rect) {
	c := &app.canvas
	r, ok := sel_rect(app)
	if !ok do return
	top := r.y - SECTION_HEAD
	bottom := r.y + r.h + CARD_GAP
	if top < c.scroll.target do c.scroll.target = max(top, 0)
	else if bottom - view.h > c.scroll.target do c.scroll.target = bottom - view.h
}

// Enter on the grid, with nothing typed in the box under it.
canvas_open_sel :: proc(app: ^App) {
	c := &app.canvas
	canvas_layout(app)
	if c.sel == "" {
		for card in c.cards do if !card.head {
			app_open_todo(app, app.todos.list[card.todo].id)
			return
		}
		return
	}
	app_open_todo(app, c.sel)
}

// --- opening a thread ---------------------------------------------------------

// `id` here is a thread, not a card. It must not go anywhere near the
// keyboard cursor, which holds a card id — putting a session id in it left
// the cursor pointing at nothing, so the arrow keys started from scratch and
// ctrl c on the grid could not find the card it was meant to stop.
canvas_open :: proc(app: ^App, id: string) {
	app_select(app, id)
	app.canvas.opened = true
	app.canvas.launcher = false
	app.focus = .Composer
}

canvas_close :: proc(app: ^App) {
	app.canvas.opened = false
	app.model_open = false
}

// A new thread, asked for by hand: it opens in front of you. A card never
// comes through here — its turn is headless and leaves the reader on the grid.
canvas_new_chat :: proc(app: ^App, cwd: string) {
	// Starting a thread from the launcher shuts it the way escape does, so
	// what was typed does not stay behind narrowing the grid.
	if app.canvas.launcher do app_launcher(app, false)
	// Cloned before the old one goes: the caller often passes app.cwd itself.
	next := strings.clone(cwd)
	delete(app.cwd)
	app.cwd = next
	chat_new(app)
	app.canvas.opened = true
	app.canvas.launcher = false
	app.focus = .Composer
}

// Only this project, or all of them again.
canvas_filter_project :: proc(app: ^App, cwd: string) {
	delete(app.canvas.project)
	app.canvas.project = strings.clone(cwd)
	app.canvas.scroll.target, app.canvas.scroll.offset = 0, 0
	app_filter(app)
}

// The panel a card zooms open into: from its place in the grid to the whole
// window, and back. Returns the rect the transcript should use, and whether it
// has arrived (only then is the real transcript drawn inside).
canvas_panel :: proc(app: ^App, full: Rect) -> (r: Rect, arrived: bool, t: f32) {
	ui := &app.ui
	c := &app.canvas
	t = ui_anim(ui, ui_id("canvas-open"), c.opened ? 1 : 0, 11)
	// This runs before draw_canvas, so on the first frame it is the one that
	// tells the layout how wide the grid is.
	c.view = full
	from, ok := canvas_node_rect(app, app.chat.session_id)
	if !ok do from = {full.x + full.w * 0.35, full.y + full.h * 0.4, full.w * 0.3, full.h * 0.2}
	ease := t * t * (3 - 2 * t)
	r = {
		from.x + (full.x - from.x) * ease,
		from.y + (full.y - from.y) * ease,
		from.w + (full.w - from.w) * ease,
		from.h + (full.h - from.h) * ease,
	}
	arrived = t > 0.985
	return
}

// A straight line as a thin quad.
ui_line :: proc(ui: ^UI, a, b: [2]f32, thickness: f32, col: Color) {
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 0.5 do return
	n := [2]f32{-d.y, d.x} / l * (thickness / 2)
	ui_quad_corners(ui, {a + n, b + n, b - n, a - n}, {{0, 0}, {1, 0}, {1, 1}, {0, 1}}, {col, col, col, col}, WHITE_TEX)
}
