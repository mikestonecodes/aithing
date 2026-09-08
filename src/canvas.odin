package aithing

import "core:math"
import "core:path/filepath"
import "core:strings"

// The home view is a fixed grid: every todo item is a card, cards are grouped
// under the project they belong to, and the whole thing scrolls. Nothing to
// pan, nothing to place, nothing to remember — the same item is in the same
// place every time you look, which is the only thing a map is for.
//
// A card is one piece of work and one thread, one each (see todos.odin). Every
// card says where its work stands — waiting, processing, complete, failed —
// and opening one opens its own thread.
//
// The keyboard drives it. Typing goes into the box along the bottom, and what
// is typed there becomes a card a part. `/` opens the launcher, a full-screen
// menu in type big enough to read across the room: type to narrow, arrows to
// choose, Enter to open a thread or to filter the grid down to one project.

CARD_W :: f32(300) // the width a card wants; the row stretches to fill
CARD_H :: f32(132)
CARD_GAP :: f32(18)
SECTION_HEAD :: f32(52)
SECTION_GAP :: f32(26)
GRID_PAD :: f32(24)
GRID_TOP :: f32(58) // under the line that says which project you are in

Card :: struct {
	todo:  int, // index into app.todos.list
	r:     Rect, // in content space: add the scroll offset to place it
	head:  bool, // a section header rather than a card
	name:  string, // the project, on a header
}

Canvas :: struct {
	scroll:   Scroll,
	// Scratch, not state: rebuilt from the cards every time canvas_layout is
	// called, which every reader goes through first. The indices in it point
	// into app.todos.list, so one built in an earlier frame is a bounds trap
	// the moment that list loses an entry — which is why it is not kept.
	cards:    [dynamic]Card,
	content:  f32, // how tall the grid is, from the last layout
	view:     Rect, // the rect the grid was last drawn into
	sel:      string, // the todo id under the keyboard cursor
	project:  string, // only this project's threads, when set
	menu_at:  int, // which row of it is chosen
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

	inner := r.w - GRID_PAD * 2
	cols := max(1, int((inner + CARD_GAP) / (CARD_W + CARD_GAP)))
	cw := (inner - CARD_GAP * f32(cols - 1)) / f32(cols)

	// One pass. app.todo_view is already grouped by project and ordered
	// inside each, so a section is a run of it — it used to be a loop over
	// every card with a loop over every card inside it, looking for the ones
	// in the same project.
	// Every section is named when there is more than one of them, and none is
	// when there is only one — the heading over the grid names that one. The
	// first section used to be the exception instead, on the grounds that the
	// heading above it named it; under "all projects" it named nothing, and
	// the top run of cards sat there belonging to no one.
	sections, _ := app_view_projects(app)

	y := f32(0)
	col := 0
	cwd := ""
	for at in app.todo_view {
		if at >= len(app.todos.list) do continue
		td := app.todos.list[at]
		if td.cwd != cwd {
			// Close the section before it off.
			if cwd != "" {
				if col != 0 do y += CARD_H + CARD_GAP
				y += SECTION_GAP
			}
			cwd = td.cwd
			col = 0
			if sections > 1 {
				append(&c.cards, Card{head = true, name = filepath.base(cwd), r = {GRID_PAD, y, inner, SECTION_HEAD}})
				y += SECTION_HEAD
			}
		}
		x := GRID_PAD + f32(col) * (cw + CARD_GAP)
		append(&c.cards, Card{todo = at, r = {x, y, cw, CARD_H}})
		col += 1
		if col == cols {
			col = 0
			y += CARD_H + CARD_GAP
		}
	}
	if cwd != "" {
		if col != 0 do y += CARD_H + CARD_GAP
		y += SECTION_GAP
	}
	return y + GRID_PAD
}

// The grid, laid out and current. Everything derived from app.todos.list is
// rebuilt here, from the cards themselves, every time anyone asks. There are
// no counters saying whether it is still good and nothing to invalidate at
// the fifteen places that change the list — a stale index into a list that
// has since lost an entry is how this used to crash, and an index that never
// outlives the call that made it cannot go stale.
canvas_layout :: proc(app: ^App) -> f32 {
	c := &app.canvas
	app_filter(app)
	c.content = grid_layout(app, c.view)
	return c.content
}

// Where a thread's card is on screen, for the panel that grows out of it.
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
	ui_text(ui, &ui.bold, card.name, {r.x, r.y + 14}, 22, TEXT)
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
	blocked := app.page != .Grid || app.overlay != .None
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

	// When it last moved, up in the corner: a card carries the work and its
	// state, and nothing else.
	stamp := ""
	stamp_buf: [16]u8
	if td.session != "" do stamp = relative_time(td.at, stamp_buf[:])
	corner := font_width(&ui.regular, stamp, 12)
	if stamp != "" do ui_text(ui, &ui.regular, stamp, {r.x + r.w - pad - corner, ty + 1}, 12, FAINT)

	// The item itself, which is the whole point of the card — and what a copy
	// with nothing selected takes, because a card is not something that can be
	// selected in the first place.
	ui_hover_text(ui, r, td.text)
	ty += draw_wrapped(ui, &ui.bold, td.text, tx, ty, tw - corner - 10, 15, state == .Done ? MUTED : TEXT, 3)

	// Where the work stands, in the word for it. A turn in flight pulses,
	// whether it was started here or in another window. There used to be a
	// place in a queue printed here as well — "next up", "queued · 3" — and
	// there is no queue to have a place in now.
	label := todo_state_label(state)
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
	if turn := turn_for_todo(app, td.id); turn >= 0 {
		note = turn_doing(app.turns[turn])
	} else if state == .Failed || state == .Asked {
		// Why. A headless turn has no transcript to read it out of, and a
		// card that says `failed` and nothing else is a card you cannot act
		// on — which is exactly how it read. A card that stopped to ask
		// something is the same: the question is the whole of what it wants.
		note = app.notes[td.id]
		note_col = state == .Failed ? RED : AMBER
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

// Moves the cursor one card along the grid, in the order the grid is read.
//
// It used to be four directions, each finding the nearest card that lay that
// way by measuring centre to centre. That went when up and down became the
// box's history: two directions over a list that is already in reading order
// needs no geometry, and every card is reachable with either of them, which
// the nearest-in-direction search could not promise on a short last row.
canvas_step_sel :: proc(app: ^App, delta: int) {
	c := &app.canvas
	canvas_layout(app)
	at := -1
	cards := 0
	for card in c.cards {
		if card.head do continue
		if app.todos.list[card.todo].id == c.sel do at = cards
		cards += 1
	}
	if cards == 0 do return
	next := at < 0 ? 0 : clamp(at + delta, 0, cards - 1)
	i := 0
	for card in c.cards {
		if card.head do continue
		if i == next {
			canvas_set_sel(app, app.todos.list[card.todo].id)
			return
		}
		i += 1
	}
}

// `id` is often app.canvas.sel itself — Enter on the grid passes the cursor
// straight back in — so the new one is made before the old one goes. Freeing
// first left the clone reading memory it had just handed back.
canvas_set_sel :: proc(app: ^App, id: string) {
	next := strings.clone(id)
	delete(app.canvas.sel)
	app.canvas.sel = next
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
	app.page = .Thread
	app.overlay = .None
}

canvas_close :: proc(app: ^App) {
	app.page = .Grid
	app.overlay = .None
}

// A new thread, asked for by hand: it opens in front of you. A card never
// comes through here — its turn is headless and leaves the reader on the grid.
canvas_new_chat :: proc(app: ^App, cwd: string) {
	// Starting a thread from the launcher shuts it the way escape does, so
	// what was typed does not stay behind narrowing the grid.
	if app.overlay == .Launcher do app_launcher(app, false)
	// Cloned before the old one goes: the caller often passes app.cwd itself.
	next := strings.clone(cwd)
	delete(app.cwd)
	app.cwd = next
	chat_new(app)
	app.page = .Thread
	app.overlay = .None
}

// Only this project, or all of them again.
//
// Whatever was half-typed under the grid goes with it. The box only exists on
// a grid narrowed to one project and what is in it becomes cards in that
// project, so text left over from the last one would either follow you into
// the wrong project or sit in a box nobody can see — where it still answered
// for `/`, and still ate the Esc that should have widened the grid.
canvas_filter_project :: proc(app: ^App, cwd: string) {
	next := strings.clone(cwd) // may be the string being replaced
	if next != app.canvas.project {
		editor_clear(&app.capture)
		app.history_at = 0
	}
	delete(app.canvas.project)
	app.canvas.project = next
	app.canvas.scroll.target, app.canvas.scroll.offset = 0, 0
}

// The panel a card zooms open into: from its place in the grid to the whole
// window, and back. Returns the rect the transcript should use, and whether it
// has arrived (only then is the real transcript drawn inside).
canvas_panel :: proc(app: ^App, full: Rect) -> (r: Rect, arrived: bool, t: f32) {
	ui := &app.ui
	c := &app.canvas
	t = ui_anim(ui, ui_id("canvas-open"), app.page == .Thread ? 1 : 0, 11)
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
