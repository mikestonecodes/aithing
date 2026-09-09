package aithing

import "core:math"
import "core:path/filepath"
import "core:slice"
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

// How far a card comes up out of the cell it was laid out in when the pointer
// is on it: the swell, half of which is above the cell, and the lift on top of
// that. One answer, read by the drawing that does the growing and by the
// layout, which keeps that much room above the first row. The grid is drawn
// inside a scissor at the top of its scroll area, so a top-row card that grew
// into the space above it came back with its rounded corners sawn off — a red
// card with a flat top edge, which is what this was found as.
CARD_SWELL_W :: f32(0.035)
CARD_SWELL_H :: f32(0.06)
CARD_LIFT :: f32(3)
CARD_ROOM :: CARD_H * CARD_SWELL_H / 2 + CARD_LIFT

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
	// Cards that were just dismissed, still on their way out. The card is
	// gone from the list the frame after the x is pressed, so what is drawn
	// imploding is a copy of what it looked like — and the wave its going
	// sends across the grid is read off its age, so a second one a moment
	// later makes a second wave rather than restarting the first.
	ghosts:   [dynamic]Ghost,
}

// A card and where it is drawn this frame, for the ones held back to be
// drawn last.
@(private = "file")
Placed :: struct {
	card: Card,
	r:    Rect,
	left: f32, // distance squared to where it is going
}

Ghost :: struct {
	r:    Rect, // content space, like a card
	text: string, // its own copy: the todo it came from is freed
	born: f32, // ui.time
}

canvas_destroy :: proc(c: ^Canvas) {
	delete(c.cards)
	delete(c.sel)
	delete(c.project)
	for g in c.ghosts do delete(g.text)
	delete(c.ghosts)
}

// How long a dismissed card takes to go, and how the wave it leaves travels:
// a ring spreading out from where it was at WAVE_SPEED, shoving every card it
// passes away from the spot and setting it wobbling on its own springs. The
// shove fades with distance so the far corner of a big grid stirs rather
// than jumps.
GHOST_LIFE :: f32(0.55)
WAVE_SPEED :: f32(1700) // px/s
WAVE_KICK :: f32(420) // px/s, given to a card at the spot
WAVE_REACH :: f32(900) // px, over which the shove falls to a third
WAVE_BULGE :: f32(9) // how hard the ring swells a card it passes

// Salts on a card's id for each thing about it that moves.
CARD_X :: 2
CARD_Y :: 3
CARD_SW :: 4 // width swell, hovered
CARD_SH :: 5 // height swell, hovered — a different rate, so it wobbles
CARD_PRESS :: 6
HEAD_Y :: 7
CARD_BORN :: 8 // 0 the frame a card is made, 1 once it has arrived

// The moment a card is made from the box: it is seeded under the box, small,
// so its first frame draws it rising out of where it was typed. Before this a
// new card was simply there, at the head of its section, and the only thing
// that moved was every other card in the section sliding along a slot to make
// room — motion with no cause on screen, which is what "the shifting is
// weird" was. Getting out of its way turned out to be the wrong half to keep:
// the card now lands in the free slot at the end of its section and nothing
// else moves at all (app_build_cards), so the only thing on screen that
// changes is the card coming up out of the box. The seeds only take on an id
// the springs have never seen, so a card that already has a place keeps it.
canvas_born :: proc(app: ^App, id: string) {
	ui := &app.ui
	c := &app.canvas
	// Content space, like a card: the box sits just under the grid's view.
	ui_spring_seed(ui, ui_id(id, CARD_X), c.view.x + c.view.w / 2 - CARD_W / 2)
	ui_spring_seed(ui, ui_id(id, CARD_Y), c.scroll.offset + c.view.h - GRID_TOP)
	ui_spring_seed(ui, ui_id(id, CARD_BORN), 0)
}

// The moment a card is dismissed: it is copied out to implode where it was,
// and the wave that starts from it. Called from both places a card can be
// dismissed from, with the card as it is laid out this frame.
canvas_blast :: proc(app: ^App, r: Rect, text: string) {
	append(&app.canvas.ghosts, Ghost{r, strings.clone(text), app.ui.time})
}

// --- layout ----------------------------------------------------------------

// Fills c.cards for this frame and returns how tall the content is. Sections
// come in the order the projects first got a card and the cards inside one in
// the order they were made, so a card added or dismissed only ever disturbs
// what comes after it — see app_build_cards for why that is the way round it
// is.
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

	// The first row starts a card's rise below the top of the view rather
	// than flush against it, so a card under the pointer has somewhere to
	// grow into that the scissor will not take back.
	y := CARD_ROOM
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

	ui_begin_scroll(ui, view, &c.scroll, content)
	moving := make([dynamic]Placed, context.temp_allocator)
	// Where a card is drawn is where it is laid out, chased by a spring: a
	// card whose row moved — one before it went, the window narrowed — slides
	// there and settles rather than being there. Every card's springs are
	// ticked, on screen or not, so one scrolled back into view is where it
	// belongs and not sliding in from where it was last seen.
	//
	// Damped to just short of critical. At 13 the springs rang, and a card
	// shoved along a slot by one made above it went past the slot and came
	// back, every card in the section at once — a row of things overshooting
	// looks like a mistake being corrected, not like room being made. The
	// wave a dismissed card sends still moves them: a kick shows as a
	// displacement and a return either way.
	for card in c.cards {
		if card.head {
			hy := ui_id(card.name, HEAD_Y)
			y := ui_spring(ui, hy, card.r.y, 170, 22)
			cr := Rect{card.r.x, y - c.scroll.offset + view.y, card.r.w, card.r.h}
			if cr.y > view.y + view.h || cr.y + cr.h < view.y do continue
			draw_section_head(app, card, cr)
			continue
		}
		td := app.todos.list[card.todo]
		kx, ky := ui_id(td.id, CARD_X), ui_id(td.id, CARD_Y)
		canvas_wave(app, card.r, kx, ky, ui_id(td.id, CARD_SW), ui_id(td.id, CARD_SH))
		x := ui_spring(ui, kx, card.r.x, 170, 22)
		y := ui_spring(ui, ky, card.r.y, 170, 22)
		cr := Rect{x, y - c.scroll.offset + view.y, card.r.w, card.r.h}
		if cr.y > view.y + view.h || cr.y + cr.h < view.y do continue
		// A card on the move goes over the ones sitting still. The card at
		// the end of a row that has to make room crosses the grid to the
		// start of the next, and drawn in list order it went under every card
		// laid out after it — cut through by the things it was passing.
		// Every card in the section is moving when room is being made, so
		// the order among them is by how far each has left to go: the one
		// crossing the grid from the end of a row to the start of the next
		// is the one furthest from home, and goes over the ones nudging
		// along a slot.
		dx, dy := x - card.r.x, y - card.r.y
		if abs(dx) > 1 || abs(dy) > 1 {
			append(&moving, Placed{card, cr, dx * dx + dy * dy})
			continue
		}
		draw_card(app, card, cr)
	}
	slice.sort_by(moving[:], proc(a, b: Placed) -> bool { return a.left < b.left })
	for m in moving do draw_card(app, m.card, m.r)
	draw_ghosts(app, view)
	ui_end_scroll(ui, view, &c.scroll)

	if len(c.cards) == 0 {
		msg := app.scanned ? "nothing here — type below to add a card, / to search" : "reading threads…"
		ui_text_centred(ui, &ui.regular, msg, view, 18, FAINT)
	}
}

// The shove a dismissed card's wave gives this one, on the frame the ring
// crosses its centre: a kick to its springs, away from the spot, and a swell.
// The ring's radius is read off the wave's age, so whether it has reached a
// card is a question about the clock and not a flag on the card.
@(private = "file")
canvas_wave :: proc(app: ^App, r: Rect, kx, ky, ksw, ksh: u64) {
	ui := &app.ui
	centre := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	for g in app.canvas.ghosts {
		age := ui.time - g.born
		if age <= 0 do continue
		from := [2]f32{g.r.x + g.r.w / 2, g.r.y + g.r.h / 2}
		d := centre - from
		dist := math.sqrt(d.x * d.x + d.y * d.y)
		if dist < 1 do continue
		now := age * WAVE_SPEED
		before := (age - ui.dt) * WAVE_SPEED
		if !(before < dist && dist <= now) do continue
		push := WAVE_KICK * math.exp(-dist / WAVE_REACH)
		ui_spring_kick(ui, kx, d.x / dist * push)
		ui_spring_kick(ui, ky, d.y / dist * push)
		swell := WAVE_BULGE * math.exp(-dist / WAVE_REACH)
		ui_spring_kick(ui, ksw, swell)
		ui_spring_kick(ui, ksh, swell)
	}
}

// The cards on their way out, over the grid: each pops a touch, implodes and
// fades, and an unseen wave runs out from it shoving everything else.
@(private = "file")
draw_ghosts :: proc(app: ^App, view: Rect) {
	ui := &app.ui
	c := &app.canvas
	for i := 0; i < len(c.ghosts); i += 1 {
		g := c.ghosts[i]
		age := ui.time - g.born
		if age < 0 || age >= max(GHOST_LIFE, WAVE_REACH * 2 / WAVE_SPEED) {
			delete(g.text)
			ordered_remove(&c.ghosts, i)
			i -= 1
			continue
		}
		ui.animating = true
		cx := g.r.x + g.r.w / 2
		cy := g.r.y - c.scroll.offset + view.y + g.r.h / 2
		// The ring the wave used to draw is gone: a circle the width of the
		// window swelling out of a deleted card read as an error, not as
		// motion. The wave itself stays — it is what shoves the other cards
		// — it just travels unseen now, which is why the ghost is still kept
		// alive past GHOST_LIFE for as long as the wave takes to cross.
		if age >= GHOST_LIFE do continue
		t := age / GHOST_LIFE
		// Out with a flourish: it swells first and then collapses to nothing,
		// the back-ease run in reverse.
		sc := max(1 - ease_back(t, 1.6), 0)
		a := 1 - t
		w, h := g.r.w * sc, g.r.h * sc
		r := Rect{cx - w / 2, cy - h / 2, w, h}
		ui_rect(ui, {r.x + 1, r.y + 4, r.w, r.h}, color_alpha(Color(0xff000000), 0.3 * a), 12 * sc)
		ui_rect(ui, r, color_alpha(PANEL_HI, a), 12 * sc)
		ui_rect(ui, r, color_alpha(RED, 0.35 * a), 12 * sc)
		if sc > 0.25 {
			pad := 14 * sc
			draw_wrapped(ui, &ui.bold, g.text, r.x + pad, r.y + pad, r.w - pad * 2, 15 * sc, color_alpha(TEXT, a), 3)
		}
	}
}

@(private = "file")
draw_section_head :: proc(app: ^App, card: Card, r: Rect) {
	ui := &app.ui
	ui_text(ui, &ui.bold, card.name, {r.x, r.y + 14}, 22, TEXT)
	ui_rect(ui, {r.x, r.y + r.h - 9, r.w, 1}, color_alpha(BORDER, 0.7))
}

@(private = "file")
draw_card :: proc(app: ^App, card: Card, base: Rect) {
	r := base
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

	// The card under the pointer comes up to meet it, and it comes up like
	// something with give in it: its width and height swell on two springs
	// wound to different rates, so it wobbles for a moment before it holds,
	// and a press squashes it down until it is let go. The layout is not
	// touched — `base` is where it is and what it is hit against, and the
	// text wraps to it — only the drawing swells around the centre. How far
	// out of the cell that reaches is CARD_ROOM, which the layout keeps clear
	// above the first row.
	up := hovered || selected ? f32(1) : 0
	held := ui.active == id || ui.active == bid ? f32(1) : 0
	lift := ui_spring(ui, id, up, 260, 14)
	sw := ui_spring(ui, ui_id(td.id, CARD_SW), up, 330, 9)
	sh := ui_spring(ui, ui_id(td.id, CARD_SH), up, 190, 8)
	press := ui_spring(ui, ui_id(td.id, CARD_PRESS), held, 500, 18)
	// A card just made grows to size as it rises out of the box (see
	// canvas_born), with a touch of overshoot so it lands rather than fades
	// in. Any card the spring has not met before rests at 1, so this is a
	// no-op for everything already on the grid.
	born := ui_spring(ui, ui_id(td.id, CARD_BORN), 1, 240, 17)
	grow := 0.7 + 0.3 * born
	r.w = base.w * (1 + CARD_SWELL_W * sw - 0.04 * press) * grow
	r.h = base.h * (1 + CARD_SWELL_H * sh - 0.06 * press) * grow
	r.x = base.x + (base.w - r.w) / 2
	r.y = base.y + (base.h - r.h) / 2 - CARD_LIFT * lift
	if born < 0.99 do ui_rect(ui, {r.x + 1, r.y + 6, r.w, r.h}, color_alpha(Color(0xff000000), 0.35 * (1 - born)), 12)
	btn = {r.x + r.w - pad - 28, r.y + pad - 4, 28, 28}

	if lift > 0.01 do ui_rect(ui, {r.x + 1, r.y + 4 + 4 * lift, r.w, r.h}, color_alpha(Color(0xff000000), 0.3 * lift), 12)
	ui_rect(ui, r, color_mix(USER_BG, PANEL_HI, lift * 0.7), 12)
	// The pointer arriving sends a ring out from where it landed, kept
	// inside the card: the card says it felt it.
	if ui_entered(ui, id, hovered) do ui_ripple(ui, id, ui.mouse, TOUCH, max(base.w, base.h) * 0.9)
	ui_push_clip(ui, r)
	ui_draw_ripples(ui, id)
	ui_pop_clip(ui)
	// The cursor is drawn at full strength when the keyboard is on the cards
	// and faintly when the caret is down in the box, so which one the next
	// letter goes to is on screen rather than something to remember. It is
	// read off the same answer that dims the box's edge, not a flag set
	// beside it.
	if selected do ui_rect(ui, r, color_alpha(ACCENT, app_focus(app) == .Capture ? 0.2 : 0.55), 12)
	if current do ui_rect(ui, {r.x, r.y + 12, 3, r.h - 24}, ACCENT, 2)
	// Work that came back clean is work you are done with: it stays on the
	// map, drawn back, rather than shouting alongside what is still open.
	// A card that is finished sits back, whether its work is still on its own
	// branch or already in the project. Both are done as far as the grid is
	// concerned; the chip is where the difference is said.
	settled := state == .Done || state == .Merged
	if settled do ui_rect(ui, r, color_alpha(BG, 0.28), 12)

	tx := r.x + pad
	ty := r.y + pad
	tw := base.w - pad * 2

	// When it last moved, up in the corner: a card carries the work and its
	// state, and nothing else.
	stamp := ""
	stamp_buf: [16]u8
	if td.session != "" do stamp = relative_time(td.at, stamp_buf[:])
	// The x lands in the same corner, and the two were drawn over each other:
	// a cross with `34m` printed through it. The stamp is the thing you can
	// do without while your hand is on the card, so it stands down and the
	// cross takes its place. The room kept for it does not change with the
	// hover — text that reflowed as the pointer crossed the card was the
	// first try at this — and is never less than the cross needs.
	corner := math.max(font_width(&ui.regular, stamp, 12), f32(28))
	if stamp != "" && !hovered {
		w := font_width(&ui.regular, stamp, 12)
		ui_text(ui, &ui.regular, stamp, {r.x + r.w - pad - w, ty + 1}, 12, FAINT)
	}

	// The item itself, which is the whole point of the card — and what a copy
	// with nothing selected takes, because a card is not something that can be
	// selected in the first place.
	// Through text_without_images: a card written in the box under the grid
	// carries the paths of whatever was pasted into it, because that is how it
	// hands them to Claude, and a card whose first line is a cache path says
	// nothing about the work. The picture is drawn beside the words instead.
	said := text_without_images(td.text)
	ui_hover_text(ui, r, said)
	ty += draw_wrapped(ui, &ui.bold, said, tx, ty, tw - corner - 10, 15, settled ? MUTED : TEXT, 3)

	// And the pictures those words named, in the room left between them and
	// the pill: a card whose path had been taken out of its text otherwise
	// gave no sign it was carrying a screenshot at all.
	pill_top := r.y + r.h - pad - 20
	// Whether there is room for them is asked of `base`, the cell the card
	// rests in, and not of `r`, which is swelling on the hover springs. Asked
	// of `r`, a card with words nearly down to the pill had no room at rest
	// and room a moment later, so the picture popped into the middle of the
	// wobble and left again when it settled. The card grows around it either
	// way; what is drawn does not change halfway through.
	if imgs := text_images(app, td.text); len(imgs) > 0 {
		rest_top := base.y + pad + (ty - (r.y + pad))
		side := min(base.y + base.h - pad - 20 - 8 - rest_top, f32(38))
		if side >= 20 {
			ix := tx
			rest_x := base.x + pad
			for a in imgs {
				if rest_x + side > base.x + base.w - pad do break
				rest_x += side + 6
				ui_image_cover(ui, {ix, ty + 2, side, side}, a.tex, a.width, a.height, 5)
				ix += side + 6
			}
		}
	}

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
	pill := Rect{tx, pill_top, DOT + DOT_GAP + lw + 20, 20}
	ui_rect(ui, pill, color_alpha(col, 0.16 * alpha), 10)
	cx := pill.x + (pill.w - (DOT + DOT_GAP + lw)) / 2
	ui_circle(ui, {cx + DOT / 2, pill.y + pill.h / 2}, DOT / 2, color_alpha(col, alpha))
	ui_text_middle(ui, &ui.regular, label, cx + DOT + DOT_GAP, pill, 11.5, color_alpha(col, alpha))

	// What the turn is doing right now, in the corner beside the pill. This
	// was the tool and its arguments in words — `Bash  cp -r src build` —
	// ellipsized into whatever room the pill had left over, which at 11.5px
	// was a line that changed shape every second and said less at a glance
	// than its own first word did. The mark is the one the transcript draws
	// for that family of tool, so a sweep across the grid says which cards
	// are reading and which are running something without reading a word;
	// the words themselves are still there, under the pointer.
	room := r.w - pad * 2 - pill.w - 14
	if turn := turn_for_card(app, td); turn >= 0 {
		if room > DOING do draw_doing(app, app.turns[turn], {r.x + r.w - pad - DOING / 2, pill.y + pill.h / 2}, id)
	} else if state == .Failed || state == .Asked {
		// Why. A headless turn has no transcript to read it out of, and a
		// card that says `failed` and nothing else is a card you cannot act
		// on — which is exactly how it read. A card that stopped to ask
		// something is the same: the question is the whole of what it wants.
		note := app.notes[td.id]
		note_col := state == .Failed ? RED : AMBER
		if note != "" && room > 40 {
			buf: [192]u8
			note = font_ellipsize(&ui.regular, note, 11.5, room, buf[:])
			nw := font_width(&ui.regular, note, 11.5)
			ui_text_middle(ui, &ui.regular, note, r.x + r.w - pad - nw, pill, 11.5, note_col)
		}
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
			canvas_blast(app, card.r, said)
			return
		}
	}

	if clicked do app_click_todo(app, td.id)
}

DOING :: f32(26) // the disc in a card's corner that says what its turn is at

// What a running turn is doing: the mark for it, with the work going round it.
// Everything here moves — the disc breathes, a bead runs the ring, and the
// whole thing takes a knock each time the tool changes — because a headless
// card has no transcript anyone can watch, and a mark that sat still would be
// a picture of a turn rather than a turn. The word `processing` under it says
// the same thing and has said it for two minutes; this says it now.
@(private = "file")
draw_doing :: proc(app: ^App, t: ^Turn, at: [2]f32, card: u64) {
	ui := &app.ui
	ui.time_effects = true
	col, icon := tool_style(t.tool)
	// No tool named means the agent is writing, which is a thing it is doing
	// and not a gap between the things it does. The transcript's own mark for
	// something said stands in, in its own colour, so a card that is thinking
	// does not wear the grey nut kept for tools this build has never heard of.
	if t.tool == "" do col, icon = TILE_SAID, .Said

	// The knock. Which tool it is is the one thing written down — no note is
	// kept of the last one — so the change is caught by handing the name's
	// hash to ui_changed, which remembers a number for exactly one frame.
	id := card ~ 0xd01
	pop := ui_spring(ui, id, 0, 340, 11)
	if ui_changed(ui, id, f32(ui_id(t.tool) & 0xffff)) {
		ui_spring_kick(ui, id, 9)
		// Through the card's own ripple channel, so the ring is clipped to
		// the card and the card reads as the thing that felt it.
		ui_ripple(ui, card, at, col, DOING * 2.6)
	}

	breath := 0.5 + 0.5 * math.sin(ui.time * 4.5)
	rad := DOING / 2 * (1 + 0.06 * breath + 0.16 * pop)

	g := rad * (1.5 + 0.5 * breath)
	ui_quad(
		ui,
		{at.x - g, at.y - g, g * 2, g * 2},
		{0, 0},
		{1, 1},
		color_alpha(col, 0.2 + 0.16 * breath + 0.24 * pop),
		WHITE_TEX,
		NO_ROUND,
		.Glow,
	)

	disc := color_mix(PANEL, col, 0.2 + 0.16 * breath + 0.2 * pop)
	ui_circle(ui, at, rad, disc)
	// There used to be a ring here with four beads chasing each other round
	// it — a trailing comet on the disc's edge. It was asked for and then
	// asked away again: the disc already breathes and the mark already knocks
	// when the tool changes, and the beads were a second thing saying the
	// same word louder. The disc, the glow and the mark are the whole of it.

	// The mark, in the box draw_icon takes its scale from: bigger than the
	// disc, because that box is a transcript stone and the mark inside it is
	// half its width.
	box := DOING * 1.28 * (1 + 0.16 * pop)
	draw_icon(ui, icon, {at.x - box / 2, at.y - box / 2, box, box}, col, disc)
	// The line it replaced, for whoever wants it: pointing at the mark is
	// asking what it stands for.
	ui_hover_text(ui, {at.x - rad, at.y - rad, rad * 2, rad * 2}, turn_doing(t))
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
				// A word wider than the line has no space to break at, so it
				// is broken where it stops fitting. It used to be taken whole
				// here, which drew a pasted path clean over the card's edge.
				if last_fit == 0 do last_fit = font_fit(font, rest, size, w)
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

// Reads the layout the caller has already built rather than building another
// one — every caller lays the grid out and then asks several questions of it,
// and laying the whole grid out again per question is half of what a frame on
// the grid used to cost.
@(private = "file")
sel_rect :: proc(app: ^App) -> (Rect, bool) {
	c := &app.canvas
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

// One row up or down, for j and k. h and l already reach every card, so this
// is a shortcut and not the only way through: when the row it lands on is
// short it takes the card nearest across, which is the last one. That is the
// promise the old nearest-in-direction search could not make and why it went
// — here it is only ever a shortcut, so a row that cannot be entered squarely
// is still entered.
canvas_step_row :: proc(app: ^App, delta: int) {
	c := &app.canvas
	canvas_layout(app)
	at := -1
	for card, i in c.cards {
		if card.head do continue
		if app.todos.list[card.todo].id == c.sel do at = i
	}
	// Nothing chosen yet: j and k start at the first card, the way the
	// arrows do.
	if at < 0 {
		for card in c.cards do if !card.head {
			canvas_set_sel(app, app.todos.list[card.todo].id)
			return
		}
		return
	}
	cur := c.cards[at].r
	// Cards are appended in reading order, so the next row down is the first
	// card past this one sitting lower, and the row up is the last one before
	// it sitting higher. Section headers are laid out in the same order and
	// are skipped, so j and k cross a heading without stopping on it.
	row := f32(0)
	found := false
	if delta > 0 {
		for card in c.cards[at + 1:] {
			if card.head do continue
			if card.r.y > cur.y {
				row = card.r.y
				found = true
				break
			}
		}
	} else {
		#reverse for card in c.cards[:at] {
			if card.head do continue
			if card.r.y < cur.y {
				row = card.r.y
				found = true
				break
			}
		}
	}
	if !found do return
	best := -1
	best_d := max(f32)
	for card, i in c.cards {
		if card.head || card.r.y != row do continue
		d := abs((card.r.x + card.r.w / 2) - (cur.x + cur.w / 2))
		if d < best_d {
			best_d = d
			best = i
		}
	}
	if best >= 0 do canvas_set_sel(app, app.todos.list[c.cards[best].todo].id)
}

// x on the grid: the card under the cursor goes, and the cursor lands on the
// one that takes its place. Leaving the cursor on the id that was just
// dismissed sent the next h or l back to the first card of the grid, which
// after three x presses is nowhere near where you were working.
canvas_dismiss_sel :: proc(app: ^App) {
	c := &app.canvas
	canvas_layout(app)
	if c.sel == "" do return
	at := -1
	for card, i in c.cards {
		if card.head do continue
		if app.todos.list[card.todo].id == c.sel do at = i
	}
	if at < 0 do return
	next := ""
	for card in c.cards[at + 1:] do if !card.head {
		next = app.todos.list[card.todo].id
		break
	}
	if next == "" {
		#reverse for card in c.cards[:at] do if !card.head {
			next = app.todos.list[card.todo].id
			break
		}
	}
	app_dismiss_todo(app, c.sel)
	canvas_blast(app, c.cards[at].r, app.todos.list[c.cards[at].todo].text)
	canvas_set_sel(app, next)
}

// `id` is often app.canvas.sel itself — Enter on the grid passes the cursor
// straight back in — so the new one is made before the old one goes. Freeing
// first left the clone reading memory it had just handed back.
canvas_set_sel :: proc(app: ^App, id: string) {
	next := strings.clone(id)
	delete(app.canvas.sel)
	app.canvas.sel = next
	canvas_keep_sel_in_view(app)
}

// Scrolls just enough to keep the chosen card on screen. Moving the cursor is
// what asks for this, so it hangs off canvas_set_sel — the one place the
// cursor is written — and off nothing else.
//
// It used to run from draw_canvas, every frame. The cursor is only moved by
// the keyboard, so it sat wherever it was last left while the wheel moved the
// grid, and the frame after the wheel took that card off the screen this
// dragged the whole grid straight back onto it: the scroll would not go past
// the cursor's card, and the rows below it could not be reached at all. That
// is the "scrolling gets stuck and I cannot see the bottom ones".
@(private = "file")
canvas_keep_sel_in_view :: proc(app: ^App) {
	c := &app.canvas
	// Before the first frame there is no view to keep anything inside of, and
	// nothing to scroll — the cursor restored from disk is followed by the
	// scroll restored from disk, which is the position that was saved.
	if c.view.h <= 0 do return
	canvas_layout(app)
	r, ok := sel_rect(app)
	if !ok do return
	// The same room draw_canvas leaves: the project line above the grid and
	// the box along the bottom are not scrolled.
	h := c.view.h - GRID_TOP - capture_height(app, c.view.w)
	if h <= 0 do return
	top := r.y - SECTION_HEAD
	bottom := r.y + r.h + CARD_GAP
	if top < c.scroll.target do c.scroll.target = max(top, 0)
	else if bottom - h > c.scroll.target do c.scroll.target = bottom - h
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
		app_history_done(app)
	}
	delete(app.canvas.project)
	app.canvas.project = next
	app.canvas.scroll.target, app.canvas.scroll.offset = 0, 0
}

// How long a card takes to become a thread, and to fall back into the grid.
// Long enough to see where the thread came from, short enough that nobody
// waits for it — and it is a length now rather than a rate, so the panel is
// full size at the end of it and the transcript goes in on time. It used to
// be an exponential easing called "arrived" at 98.5%, which took the better
// part of half a second to reach and spent most of it drawing an empty box.
// Thirteen frames: enough to see the thread grow out of the card it came
// from, which is the whole of what the movement is for.
CANVAS_OPEN :: f32(0.22)

// The panel a card zooms open into: from its place in the grid to the whole
// window, and back. Returns the rect the transcript should use, and whether it
// has arrived (only then is the real transcript drawn inside).
canvas_panel :: proc(app: ^App, full: Rect) -> (r: Rect, arrived: bool, t: f32) {
	ui := &app.ui
	c := &app.canvas
	t = ui_tween(ui, ui_id("canvas-open"), app.page == .Thread ? 1 : 0, CANVAS_OPEN)
	// This runs before draw_canvas, so on the first frame it is the one that
	// tells the layout how wide the grid is.
	c.view = full
	// Nothing is moving: the thread fills the window, or the grid has it.
	// Neither case has a card to grow out of, and asking where that card is
	// laid the whole grid out again — every frame of every keystroke typed
	// into a thread, which is the last place that work belongs.
	if t >= 1 do return full, true, t
	if t <= 0 do return {}, false, t
	from, ok := canvas_node_rect(app, app.chat.session_id)
	if !ok do from = {full.x + full.w * 0.35, full.y + full.h * 0.4, full.w * 0.3, full.h * 0.2}
	// Opening lands a hair past the window and settles back — the thread
	// comes forward with some weight behind it — while closing simply
	// arrives, since a grid is not something that can go past its own edge.
	ease := app.page == .Thread ? ease_back(t, 0.5) : ease_out(t)
	r = {
		from.x + (full.x - from.x) * ease,
		from.y + (full.y - from.y) * ease,
		from.w + (full.w - from.w) * ease,
		from.h + (full.h - from.h) * ease,
	}
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
