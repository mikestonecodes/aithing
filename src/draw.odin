package aithing

import "core:fmt"
import "core:math"
import "core:time"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Everything on screen, rebuilt from the app state every frame. Measurement
// and drawing share one procedure per element with a `draw` flag, so a
// scrollbar's idea of how tall the transcript is can never drift from what
// actually gets drawn.

PAD :: f32(16)
// The composer's own ground: dark enough to read white text on, thin enough
// that the desktop behind the window still shows through it.
COMPOSER_BG :: Color(0x66202224)
BLINK :: f32(0.55) // caret on/off, in seconds
// How wide the block caret is where there is no character under it to take
// its width from, as a fraction of the type size. Where a box with nothing in
// it prints what it is for, that line has to start clear of this: it used to
// start at the same x, so "Reply to Claude..." read as a block and then
// "eply to Claude...".
CARET_EMPTY :: f32(0.55)
RESULT_BYTES :: 4000 // how much of a tool result is ever shown
RESULT_LINES :: 40

draw_app :: proc(app: ^App) {
	ui := &app.ui
	ui.cursor_text = false

	full := Rect{0, 0, ui.size.x, ui.size.y}
	panel, arrived, t := canvas_panel(app, full)

	// Where the chips are is worked out again every frame by whichever box
	// draws them, and forgotten first, so a picker can never open off a chip
	// that is not on screen. They used to be written once by the composer and
	// left there, which was fine while the thread was the only place with
	// chips and is not now.
	app.model_chip, app.effort_chip = {}, {}

	// The canvas underneath, only while the panel is still on its way. Once
	// the panel fills the window the grid is not drawn at all: the thread is
	// the page now, standing on the same ground the grid stood on — the
	// window's own clear colour — rather than a lit panel over a dimmed copy
	// of where you came from. Drawing both meant BG over BG, so the thread
	// read as a sheet floating above the grid instead of replacing it.
	// While the panel is up the canvas must not see the pointer either.
	if !arrived {
		canvas_mouse := ui.mouse
		if app.page == .Thread || t > 0.02 do ui.mouse = {-1e6, -1e6}
		// And it gives way: the grid settles back a few per cent as the
		// thread comes forward, so the two are at different depths rather
		// than one flat thing sliding over another. It cannot be clicked
		// while it is moving, which is the only reason it is allowed to be
		// somewhere other than where it was laid out.
		if t > 0 {
			back := 1 - 0.05 * ease_out(t)
			ui_push_zoom(ui, back, {full.w * (1 - back) / 2, full.h * (1 - back) / 2})
		}
		draw_canvas(app, full)
		if t > 0 do ui_pop_zoom(ui)
		ui.mouse = canvas_mouse
	}

	// The box along the bottom, wherever it turns out to be: the corner that
	// says what the harness has cost sits beside it, and has to know how far
	// in it reaches on a window too narrow to have room to its right.
	strip := Rect{}

	// The thread. One path whether it is arriving or arrived, because it is
	// laid out at the size it will end up at either way: while the panel is
	// still growing it is the same picture, with the panel as the hole you
	// see it through. The panel opens over the thread rather than the thread
	// appearing once the panel stops.
	//
	// It used to be two paths — an empty box with the thread's name in the
	// corner of it, and then the real thing dropped in at the end. The name
	// tracked the corner of a box crossing the screen, so it read as a line
	// of text flying to the top left and vanishing, and the transcript
	// arrived out of nowhere behind it.
	//
	// Laying it out at the final width is also what makes this cheap: the
	// message heights are keyed on that width (see draw_transcript), so a
	// panel that measured the transcript at its own changing width would
	// re-measure the whole thread every frame of the movement.
	if t > 0 {
		ease := ease_out(t)
		if !arrived {
			// The lift: a shadow under the panel while it is still a tile on
			// the grid, and the panel itself replacing what is under it
			// rather than being blended over it. A sheet at the window's own
			// alpha left the grid showing through the growing thread, and the
			// frame the grid stopped being drawn on, everything under it went
			// at once — a flash at the end of every open. A punch is exactly
			// the pixels the arrived thread has, so the last frame of the
			// movement and the first frame of the thread are the same
			// picture. It starts the colour of the card it grew out of and
			// its corners round off over the same stretch.
			ui_rect(ui, {panel.x + 3, panel.y + 10, panel.w, panel.h}, color_alpha(Color(0xff000000), 0.5 * (1 - ease)), 12 * (1 - ease))
			ui_punch(ui, panel, color_mix(PANEL_HI, BG, ease), 12 * (1 - ease))
			ui_push_clip(ui, panel)
			// The thread itself, shrunk into the panel: the whole window's
			// worth of it drawn at a fraction of its size, growing as the
			// panel grows. The scale comes from the width alone — a card is a
			// different shape from a window, and a thread squashed to a
			// card's proportions is a thread with the type stretched — so the
			// bottom of it falls outside the panel and arrives as the panel
			// reaches it.
			ui_push_zoom(ui, panel.w / full.w, {panel.x, panel.y})
		}
		composer_h := composer_height(app, full.w)
		// Nothing inside is touchable until it has arrived: a click that lands
		// on a transcript still on its way is a click nobody aimed, and while
		// the zoom is on it is not where it was laid out anyway.
		panel_mouse := ui.mouse
		if !arrived do ui.mouse = {-1e6, -1e6}
		draw_transcript(app, {full.x, full.y, full.w, full.h - composer_h})
		ui.mouse = panel_mouse
		// The box, outside the panel: it is drawn at the size and place it
		// ends up at from the first frame of the movement to the last, and it
		// takes clicks the whole way. It used to be drawn inside the zoom
		// along with the transcript, so opening a card sent the thing you had
		// been typing into flying up into the card and back down at full size
		// — the one part of the window that had nothing to do with which
		// thread you were opening, moving further than anything else.
		if !arrived {
			ui_pop_zoom(ui)
			ui_pop_clip(ui)
		}
		draw_composer(app, {full.x, full.y + full.h - composer_h, full.w, composer_h})
		cw := composer_width(full.w)
		strip = {full.x + (full.w - cw) / 2, full.y + full.h - composer_h, cw, composer_h}
	} else {
		draw_project_head(app, full)
		if app_capture_open(app) {
			draw_capture(app, full)
			ch := capture_height(app, full.w)
			cw := composer_width(full.w)
			strip = {full.x + (full.w - cw) / 2, full.y + full.h - ch, cw, ch}
		}
	}
	// What the window has to say for itself, in the same corner on either
	// page. It used to be printed inside the composer's chip band on a thread
	// and above the box on the grid, which is two places for one line — and
	// the line jumped from one to the other the moment a card was opened.
	bottom := strip.h > 0 ? strip.y - 24 : full.y + full.h - PAD - 18
	draw_status(app, {full.x + PAD, bottom, full.w / 2 - PAD, 16})
	draw_usage(app, full, strip)
	// Last, over everything: the corner that says what the harness has cost
	// is opaque and is drawn after the box the chips sit on, so a picker
	// drawn where it was chosen from came up behind that corner — a list you
	// were picking from half blind. Nothing else in the window is a popup, so
	// there is nothing for it to be under.
	draw_pickers(app)
	draw_launcher(app, full)
	// Last of all, the ring every press leaves on the window, over whatever
	// was pressed.
	ui_draw_ripples(ui, 0)
	if t > 0 && !arrived do ui_wake_in(ui, 0)
}

// The one line above the grid: the name of the project it is showing, and
// nothing when it is showing more than one.
//
// It used to print the last project worked in whenever the grid was not
// narrowed, so a grid of every project sat under one project's name — two
// pieces of state, one line, and no way to tell which you were reading. Then
// it printed "all projects" there instead, which is a name no project has: a
// line that says the grid below it is everything, over a grid of sections
// that each already say whose cards they are. The sections are the answer, so
// the line stands down and lets them give it.
@(private = "file")
draw_project_head :: proc(app: ^App, full: Rect) {
	ui := &app.ui
	// One project on screen, whether because the grid was narrowed to it or
	// because it is the only one with cards. Both are the same question, and
	// they used to be two.
	name := app.canvas.project
	if name == "" {
		if projects, only := app_view_projects(app); projects == 1 do name = only
	}
	if name == "" do return
	// The line is the name and nothing else. It used to carry a hint beside
	// it — "esc to widen", "/ to pick a project" — which said the same thing
	// on every frame forever after it had been read once, and cost the top of
	// the window to keep saying it.
	// It arrives: keyed on the name, so narrowing to another project brings
	// the new one in from the left with a little give, and the same name
	// staying put does not move.
	hid := ui_id(name, 12)
	ui_spring_seed(ui, hid, 0)
	in_ := ui_spring(ui, hid, 1, 200, 12)
	ui_text(ui, &ui.bold, base_name(name), {full.x + GRID_PAD - (1 - in_) * 18, full.y + 20}, 21, color_alpha(TEXT, clamp(in_, 0, 1)))
}

// --- the box under the grid ---------------------------------------------------

// A list is written down before it is worked on, and writing it down should
// not mean opening a thread first. So the grid has one box along the bottom:
// type into it and every part of what was typed becomes a card.
//
// The box asks for nothing but the work. Where one item stops and the next
// begins is worked out from what was written — a line, a bullet, a numbered
// point, a sentence — rather than being a rule the writer has to keep to, and
// the count under the box says what was made of it before Enter is pressed.

// The box under the grid is the same box the thread has — the same width, the
// same type, the same paddings, the same band of chips — because it is the
// same box as far as anyone looking at it is concerned. It used to be its own
// size, 15px type in a 6-line box against the composer's 19px in 8, and the
// difference was six pixels of height and a change of typeface at the exact
// moment a card was clicked: the thing you had just been typing into jumped
// as the thread came up over it. Nothing about opening a card is about the
// box, so nothing about the box moves when one is opened. See strip_height.

// How much of the window the box takes, which the grid above it keeps clear.
capture_height :: proc(app: ^App, width: f32) -> f32 {
	if !app_capture_open(app) do return 0
	// Nothing is added for the pictures. They used to sit in a row along the
	// top of the box, over the path that named them, and both were on screen
	// at once: the same screenshot twice, once as a thumbnail and once as
	// eighty characters of cache path in the middle of the sentence. The path
	// is drawn as the picture now, in the words, where it was pasted — so the
	// box is as tall as what is written in it and nothing else.
	return strip_height(strip_box_height(app, &app.capture, width))
}

// Where the box under the grid lands.
capture_box :: proc(app: ^App, full: Rect) -> Rect {
	h := capture_height(app, full.w)
	width := composer_width(full.w)
	return {full.x + (full.w - width) / 2, full.y + full.h - h + 6, width, h - 18}
}

// Where the i'th picture in the box was drawn, which is wherever the words put
// it: the editor records the cells it drew and this is the one place they are
// read from, by the headless shot putting a pointer on one. Empty until a
// frame has been drawn, because until then nobody has said where the words go.
capture_thumb :: proc(app: ^App, i: int) -> (Rect, bool) {
	if i < 0 || i >= len(app.capture.imgs) do return {}, false
	return app.capture.imgs[i].r, true
}

@(private = "file")
draw_capture :: proc(app: ^App, full: Rect) {
	ui := &app.ui
	// The box is the box. It used to keep a line above itself naming the
	// project the cards would land in — "in aithing" — and that line is gone
	// with the room it took: the box is only there on a grid narrowed to one
	// project, and the heading over that grid has already said which.
	box := capture_box(app, full)

	// Clicking the box is asking to type in it, so it writes the one variable
	// that says where the keyboard is rather than only moving a caret nobody
	// can see: while the keyboard is on the cards the click inside would
	// otherwise place a caret in a box that still would not take a letter.
	// Read after it is written, so the box lights up on the press and not on
	// the frame after.
	if ui.pressed && ui_hovered(ui, box) do app.on_cards = false

	focused := app_focus(app) == .Capture
	ui_punch(ui, box, COMPOSER_BG, 14)
	draw_box_edge(app, box, focused, ui_id("capture-edge"))
	if ui_hovered(ui, box) do ui.cursor_text = true

	// A pasted picture is a path in the text, drawn as the picture it names
	// where it was pasted. There is no x on one and no row of thumbnails over
	// the box: the path is the picture, so a picture is dropped by deleting it
	// like a letter, in the box you are already typing in.
	inner_y := box.y + COMPOSER_PAD

	text_w := box.w - COMPOSER_SIDE * 2
	editor_layout_lines(ui, &app.capture, text_w, &ui.regular, COMPOSER_PX)
	_, lines := editor_window(&app.capture, COMPOSER_LINES)
	text_h := f32(lines) * (COMPOSER_PX * 1.5)
	text_r := Rect{box.x + COMPOSER_SIDE, inner_y, text_w, text_h}
	// Nothing is printed into the empty box. It used to say "what needs
	// doing", which is a line that answers its own question once and then
	// sits under the caret forever: the box is the only place on the grid you
	// can type, and a caret blinking in it says that already.
	draw_editor(app, &app.capture, text_r, &ui.regular, COMPOSER_PX, focused, COMPOSER_LINES)

	// The same band along the bottom the composer has, and the same two chips
	// in the corner of it: what is typed here is what a card runs on, so the
	// model is chosen where the card is written rather than inside a thread
	// opened afterwards.
	//
	// Nothing else sits in that band. It used to print what Enter would do —
	// "enter · runs it", "enter · 3 cards, a thread each" — which is a line
	// that says the same thing on every frame forever after it has been read
	// once, and the cards it was warning about appear the moment Enter is
	// pressed anyway.
	chip_y := box.y + box.h - COMPOSER_CHIPS / 2 - 8
	draw_chips(app, box, chip_y)
}

// --- the launcher ------------------------------------------------------------

// What a row of the big menu does when it is chosen.
Hit :: struct {
	session: int, // -1 on a project row
	cwd:     string,
	name:    string,
	sub:     string,
	count:   int,
}

LAUNCH_ROWS :: 8

// How many of those rows the projects may take. They come first and, with
// nothing typed, there is one for every project on disk — a cap is what keeps
// the threads from being pushed off the bottom by a long list of them.
LAUNCH_PROJECTS :: 4

// Everything the typed text finds: the projects first, because narrowing to
// one is the commonest thing to want, then the threads themselves.
//
// First and always, not only once something is typed. `/` on a fresh grid used
// to offer nothing but threads, which is the one thing the grid behind it is
// already showing; the projects are what it cannot say, so they are what the
// menu opens on. Newest first, because the sessions are.
// The query is read here rather than passed in: it is app.search and nothing
// else, and the three callers that each trimmed and lowered their own copy of
// it were three chances for the menu to be filtered by something other than
// what is in the box.
launcher_hits :: proc(app: ^App) -> []Hit {
	out := make([dynamic]Hit, context.temp_allocator)
	query := strings.trim_space(editor_text(&app.search))
	// Once for the sweep, not once per session: see worktree_root.
	root := worktree_root()
	// The way back out of a narrowed grid, offered where the narrowing was
	// chosen. Esc does not do this: a project you picked is a thing you said,
	// and a key that backs out of everything else should not undo it.
	if app.canvas.project != "" {
		append(&out, Hit{session = -1, cwd = "", name = "all projects", sub = "everything"})
	}
	seen := make(map[string]int, context.temp_allocator)
	for s in app.sessions {
		// Not a card's own tree. Its name is the project with a card id on
		// the end, so typing the project's name found it once per card ever
		// run there and offered to narrow the grid to a directory in the
		// cache that has nothing on it.
		if worktree_card_under(root, s.cwd) != "" do continue
		// The project the grid is already narrowed to is not offered: the row
		// above widens it, and narrowing to where you are does nothing.
		if app.canvas.project != "" && s.cwd == app.canvas.project do continue
		if !contains_fold(base_name(s.cwd), query) do continue
		if at, has := seen[s.cwd]; has {
			out[at].count += 1
			continue
		}
		if len(seen) >= LAUNCH_PROJECTS do continue
		seen[s.cwd] = len(out)
		append(&out, Hit{session = -1, cwd = s.cwd, name = base_name(s.cwd), sub = "project", count = 1})
	}
	// Threads: the filtered list is already in newest-first order and already
	// matches the query, archived and abandoned ones included.
	for i in app_visible(app) {
		if len(out) >= LAUNCH_ROWS do break
		s := &app.sessions[i]
		append(&out, Hit{session = i, name = s.title, sub = base_name(s.cwd)})
	}
	if len(out) > LAUNCH_ROWS do resize(&out, LAUNCH_ROWS)
	return out[:]
}

// Type big enough to read from across the room: the query, and under it what
// it found. Arrows choose, Enter takes it.
@(private = "file")
draw_launcher :: proc(app: ^App, full: Rect) {
	ui := &app.ui
	c := &app.canvas
	// The fade is one number and the movement is another: the menu comes up
	// on a spring, so it lands a shade too big and relaxes into place, while
	// the dark behind it only ever eases in. Sprung, the dark would flicker
	// past full black on the overshoot.
	t := ui_anim(ui, ui_id("launcher"), app.overlay == .Launcher ? 1 : 0, 16)
	pop := ui_spring(ui, ui_id("launcher-pop"), app.overlay == .Launcher ? 1 : 0, 240, 13)
	if t < 0.01 do return
	if t < 0.99 do ui_wake_in(ui, 0)

	ui_rect(ui, full, color_alpha(Color(0xff000000), 0.88 * t))

	w := min(full.w - 120, 980)
	x := full.x + (full.w - w) / 2
	y := full.y + full.h * 0.14 + (1 - t) * 18
	// Only the drawing is scaled, about the middle of the window: the rows
	// are hit where they settle, and they settle within a quarter second.
	sc := 0.9 + 0.1 * pop
	ui_push_zoom(ui, sc, {full.w * (1 - sc) / 2, full.h * 0.3 * (1 - sc)})
	defer ui_pop_zoom(ui)

	// What the menu is offering, worked out once for the frame. The card
	// behind the rows is sized from it and the rows are drawn from it, and
	// those used to be two calls: the same sweep over every session on the
	// machine, twice a frame, for one number and one list.
	hits := launcher_hits(app)
	// One card holding the whole menu, so the grid behind it reads as a
	// backdrop rather than as something still being offered.
	card := Rect{x - 34, y - 34, w + 68, 128 + max(f32(len(hits)), 1) * 52 + 46}
	ui_rect(ui, {card.x + 3, card.y + 10, card.w, card.h}, color_alpha(Color(0xff000000), 0.5 * t), 20)
	ui_rect(ui, card, color_alpha(PANEL, 0.97 * t), 20)
	ui_rect(ui, card, color_alpha(BORDER, 0.8 * t), 20)

	// The query, in the biggest type in the program.
	query := editor_text(&app.search)
	size := f32(46)
	if query == "" {
		ui_text(ui, &ui.bold, "Search everything", {x, y}, size, color_alpha(FAINT, t))
	} else {
		editor_layout_lines(ui, &app.search, w, &ui.bold, size)
		draw_editor(app, &app.search, {x, y, w, size * 1.4}, &ui.bold, size, true, 1)
	}
	y += size * 1.5
	ui_rect(ui, {x, y, w, 1}, color_alpha(BORDER, t))
	y += 22

	if len(hits) == 0 {
		ui_text(ui, &ui.regular, "nothing by that name", {x, y + 8}, 22, color_alpha(FAINT, t))
		return
	}
	c.menu_at = clamp(c.menu_at, 0, len(hits) - 1)

	row_h := f32(52)
	for hit, i in hits {
		r := Rect{x - 18, y, w + 36, row_h}
		rid := ui_id("launch-row", i)
		clicked, hovered := ui_invisible_button(ui, rid, r)
		if hovered && ui.mouse_moved do c.menu_at = i
		on := i == c.menu_at
		// The chosen row's light springs up and settles, and the row swells
		// a touch under it; the pointer arriving on a row rings out from
		// where it landed.
		lit := ui_spring(ui, rid, on ? 1 : 0, 300, 14)
		if lit > 0.01 {
			g := 4 * lit
			ui_rect(ui, {r.x - g, r.y - g / 2, r.w + g * 2, r.h + g}, color_alpha(PANEL_HI, 0.9 * t * min(lit, 1)), 12)
			ui_rect(ui, {r.x - g, r.y + 10, 3, r.h - 20}, color_alpha(ACCENT, t * min(lit, 1)), 2)
		}
		if ui_entered(ui, rid, hovered) do ui_ripple(ui, rid, ui.mouse, TOUCH, r.w * 0.5)
		ui_push_clip(ui, r)
		ui_draw_ripples(ui, rid)
		ui_pop_clip(ui)
		buf: [256]u8
		sub_w := font_width(&ui.regular, hit.sub, 16) + 30
		name := font_ellipsize(&ui.bold, hit.name, 27, r.w - 40 - sub_w, buf[:])
		ui_text(ui, &ui.bold, name, {x, r.y + 11}, 27, color_alpha(on ? TEXT : MUTED, t))
		ui_text(ui, &ui.regular, hit.sub, {x + w - font_width(&ui.regular, hit.sub, 16), r.y + 19}, 16, color_alpha(FAINT, t))
		if clicked do launcher_take(app, hit)
		y += row_h
	}

	ui_text(ui, &ui.regular, "enter opens  ·  esc closes  ·  a project row narrows the grid", {x, y + 18}, 13.5, color_alpha(FAINT, 0.8 * t))
}

// Choosing a row: a project narrows the grid, a thread opens.
launcher_take :: proc(app: ^App, hit: Hit) {
	if hit.session < 0 {
		canvas_filter_project(app, hit.cwd)
		app.overlay = .None
		editor_clear(&app.search)
		return
	}
	canvas_open(app, app.sessions[hit.session].id)
	editor_clear(&app.search)
}

// Enter, from the key handler.
launcher_confirm :: proc(app: ^App) {
	hits := launcher_hits(app)
	if len(hits) == 0 do return
	launcher_take(app, hits[clamp(app.canvas.menu_at, 0, len(hits) - 1)])
}


// --- composer ---------------------------------------------------------------

// The edge of a box you can type in. The accent comes on with a spring when
// the caret arrives, so it flares a shade past its colour and settles, and a
// wide soft halo comes up under it: the box you are in is the box that is
// lit, and it says so with a small movement rather than a switch.
@(private = "file")
draw_box_edge :: proc(app: ^App, box: Rect, focused: bool, id: u64) {
	ui := &app.ui
	on := ui_spring(ui, id, focused ? 1 : 0, 200, 11)
	halo := clamp(on, 0, 1.4)
	if halo > 0.01 do ui_rect(ui, {box.x - 6, box.y - 6, box.w + 12, box.h + 12}, color_alpha(ACCENT, 0.07 * halo), 20)
	ui_rect(ui, box, color_mix(color_alpha(BORDER, 0.9), color_alpha(ACCENT, 0.35), clamp(on, 0, 1)), 14)
}

COMPOSER_PX :: f32(19)
COMPOSER_MIN :: f32(84)
COMPOSER_LINES :: 8 // how tall the box grows before it starts scrolling
COMPOSER_PAD :: f32(12) // inside the box, above the text and below it
COMPOSER_CHIPS :: f32(36) // the band along the bottom holding the model chip
COMPOSER_SIDE :: f32(18) // the text inset from either edge of the box
COMPOSER_THUMB :: f32(72)

// The box is exactly as tall as what goes in it, and this is the one place
// that says how tall that is: draw_composer lays out against the same numbers,
// so the text never lands under the chip row. Both boxes ask it — the grid's
// about what is written there, the thread's about the reply — so an empty box
// is the same height on either page and the swap at the moment a card opens
// is no swap at all.
strip_box_height :: proc(app: ^App, e: ^Editor, width: f32) -> f32 {
	ui := &app.ui
	inner := composer_width(width) - COMPOSER_SIDE * 2
	editor_layout_lines(ui, e, inner, &ui.regular, COMPOSER_PX)
	_, lines := editor_window(e, COMPOSER_LINES)
	return COMPOSER_PAD * 2 + f32(lines) * (COMPOSER_PX * 1.5) + COMPOSER_CHIPS
}

// Where the line an empty box prints starts: past the caret sitting at the
// head of it, with a hair of air after.
placeholder_x :: proc(x: f32) -> f32 {
	return x + COMPOSER_PX * CARET_EMPTY + 4
}

// The room the whole strip takes: the box plus the 6px of air above it and the
// 12px below it that the draw insets by, and never less than the floor.
strip_height :: proc(box_h: f32) -> f32 {
	return max(box_h + 18, COMPOSER_MIN)
}

composer_box_height :: proc(app: ^App, width: f32) -> f32 {
	h := strip_box_height(app, &app.editor, width)
	if len(app.attach) > 0 do h += COMPOSER_THUMB + 14
	return h
}

@(private = "file")
composer_width :: proc(width: f32) -> f32 {
	return min(width - PAD * 2, CONTENT_MAX)
}

// What the layout above reserves for the whole strip: the box plus the 6px of
// air above it and the 12px below that draw_composer insets by. There is no
// ceiling on it — COMPOSER_LINES is the ceiling, and it is one the text inside
// knows about, which a plain clamp here was not: the box stopped growing at
// 300px and the text kept going out through the bottom of it.
composer_height :: proc(app: ^App, width: f32) -> f32 {
	return strip_height(composer_box_height(app, width))
}

draw_composer :: proc(app: ^App, r: Rect) {
	ui := &app.ui
	width := composer_width(r.w)
	x := r.x + (r.w - width) / 2

	box := Rect{x, r.y + 6, width, r.h - 18}
	focused := app_focus(app) == .Composer
	// What you are about to say sits over the desktop, not over the app: the
	// box is cut out of everything drawn behind it and filled with a colour
	// too thin to hide what the compositor blurs through the window.
	ui_punch(ui, box, COMPOSER_BG, 14)
	draw_box_edge(app, box, focused, ui_id("composer-edge"))

	if ui_hovered(ui, box) do ui.cursor_text = true

	inner_y := box.y + COMPOSER_PAD

	// Pasted images sit above the text, each with a corner button to drop it.
	peek := Rect{}
	peek_at := -1
	if len(app.attach) > 0 {
		thumb := COMPOSER_THUMB
		tx := box.x + 14
		for i := 0; i < len(app.attach); i += 1 {
			a := &app.attach[i]
			tr := Rect{tx, inner_y, thumb, thumb}
			ui_image_cover(ui, tr, a.tex, a.width, a.height, 8)
			if ui_hovered(ui, tr) do peek, peek_at = tr, i
			del := Rect{tr.x + thumb - 16, tr.y - 4, 20, 20}
			clicked, hovered := ui_invisible_button(ui, ui_id("unattach", i), del)
			up := ui_spring(ui, ui_id("unattach-up", i), hovered ? 1 : 0, 400, 11)
			ui_circle(ui, {del.x + 10, del.y + 10}, 8 + 2 * up, color_mix(Color(0xcc000000), RED, clamp(up, 0, 1)))
			ui_text_centred(ui, &ui.bold, "x", del, 11, TEXT)
			if clicked {
				attachment_destroy(a)
				ordered_remove(&app.attach, i)
				i -= 1
				// Everything after it has just moved down one; the pointer is
				// on the x, not on a thumbnail, so there is nothing to show.
				peek_at = -1
			}
			tx += thumb + 8
		}
		inner_y += thumb + 14
	}

	// A draft in a new chat may belong to a thread that is already open on
	// this project; the manager reads it as it grows and opens that thread.
	if app.page == .Thread do route_update(app)

	// The text starts under the top padding and the box grows downward with it,
	// so the first line never moves as you type and the chip row stays clear.
	text_w := box.w - COMPOSER_SIDE * 2
	editor_layout_lines(ui, &app.editor, text_w, &ui.regular, COMPOSER_PX)
	_, lines := editor_window(&app.editor, COMPOSER_LINES)
	text_h := f32(lines) * (COMPOSER_PX * 1.5)
	text_r := Rect{box.x + COMPOSER_SIDE, inner_y, text_w, text_h}
	// What the box is for, whenever there is nothing in it. It used to be
	// hidden as soon as the box had the caret, which on a thread is always —
	// so the line existed and was never once seen.
	if editor_text(&app.editor) == "" {
		ui_text(ui, &ui.regular, "Reply to Claude...", {placeholder_x(text_r.x), text_r.y + 2}, COMPOSER_PX, FAINT)
	}
	draw_editor(app, &app.editor, text_r, &ui.regular, COMPOSER_PX, focused, COMPOSER_LINES)

	// The only two controls in the window: which model answers and how hard
	// it thinks. Permissions are whatever the harness is already configured
	// to do.
	// The chips are the whole chip band. A running turn used to put a `stop`
	// button in the left of it, which is a second way to say what Ctrl+C
	// already says, sitting in the box you are typing into and only there —
	// on the grid, where cards actually run, it was never drawn at all.
	chip_y := box.y + box.h - COMPOSER_CHIPS / 2 - 8
	draw_chips(app, box, chip_y)

	// Last, so it is over the box rather than under it.
	grow := ui_spring(ui, ui_id("composer-peek"), peek_at >= 0 ? 1 : 0, 320, 18)
	if peek_at >= 0 && peek_at < len(app.attach) {
		draw_image_peek(app, peek, app.attach[peek_at], grow)
	}
}

// The whole picture, for as long as the pointer rests on its thumbnail. A
// thumbnail is 72 pixels of a screenshot, which is enough to tell two pastes
// apart and nothing like enough to read what is in either — and what is in it
// is the entire reason for pasting a picture at somebody.
//
// Nothing is written down about which one is open, because the question
// "which picture is being looked at" already has an answer: the one under the
// pointer, this frame. It grows out of the thumbnail as the pointer arrives
// and is gone the frame the pointer leaves, so there is no shut to forget.
PEEK_IMAGE_W :: f32(760)

draw_image_peek :: proc(app: ^App, thumb: Rect, a: Attachment, grow: f32) {
	ui := &app.ui
	// Nothing decoded means nothing to blow up: the thumbnail is a white
	// square and the file is still attached and still handed over.
	if a.tex == WHITE_TEX || a.width <= 0 || a.height <= 0 do return

	// As big as the window over the box will take, at the picture's own shape,
	// and never bigger than the picture is: blowing a small paste up past its
	// own pixels is a blurry version of what the thumbnail already showed.
	max_w := min(ui.size.x - PAD * 2, PEEK_IMAGE_W, f32(a.width))
	max_h := thumb.y - PAD * 2
	if max_w < 60 || max_h < 60 do return
	w := max_w
	h := w * f32(a.height) / f32(a.width)
	if h > max_h {
		h = max_h
		w = h * f32(a.width) / f32(a.height)
	}
	x := clamp(thumb.x + thumb.w / 2 - w / 2, PAD, max(ui.size.x - PAD - w, PAD))
	box := Rect{x, thumb.y - 12 - h, w, h}

	// It arrives a shade small and settles, out of the thumbnail it belongs
	// to. Only the drawing scales: the panel takes no clicks, so there is
	// nothing that could be hit anywhere other than where it was laid out.
	sc := 0.88 + 0.12 * clamp(grow, 0, 1)
	ax, ay := thumb.x + thumb.w / 2, thumb.y
	ui_push_zoom(ui, sc, {ax * (1 - sc), ay * (1 - sc)})
	defer ui_pop_zoom(ui)

	// The same ground the boxes stand on, cut out of the window: what is
	// behind the picture is the desktop, not the transcript it is covering.
	ui_punch(ui, {box.x - 7, box.y - 7, box.w + 14, box.h + 14}, COMPOSER_BG, 12)
	ui_image(ui, box, a.tex, 8)
}

// What the window has to say for itself, in the same corner on every page:
// bottom left, above the box. It used to be drawn inside the composer's chip
// band on a thread and above the box on the grid, which is two places for one
// line, and before that inside the composer and nowhere else, so it existed
// only on the thread page — and the grid is where you sit while cards run,
// which meant a failed build was said to an empty room. Every landing note and
// every push that was refused announced itself somewhere nobody was looking,
// which is most of what "nothing ever seems to happen" was.
draw_status :: proc(app: ^App, at: Rect) {
	if app.status == "" || app.status == "ready" do return
	if at.w < 40 do return
	ui := &app.ui
	// A new line rises into place rather than being swapped in: the spring
	// is keyed on the words, so it is seeded at nothing the first frame a
	// line is seen and every line that follows arrives the same way.
	sid := ui_id(app.status, 11)
	ui_spring_seed(ui, sid, 0)
	in_ := ui_spring(ui, sid, 1, 220, 13)
	buf: [128]u8
	msg := font_ellipsize(&ui.regular, app.status, 13, at.w, buf[:])
	ui_text(ui, &ui.regular, msg, {at.x, at.y + (1 - in_) * 10}, 13, color_alpha(FAINT, clamp(in_, 0, 1)))
}

// How long the picker takes to arrive, and how far it starts from where it
// ends up. Short enough that it is under the pointer by the time the pointer
// has got there, and long enough to say which chip it came out of.
PICKER_OPEN :: f32(0.11)
PICKER_ANIM :: 101 // salts on the tag, clear of anything else keyed on it
PICKER_KNOB :: 102
PICKER_POP :: 103
PICKER_STEP :: f32(46) // between one stop and the next, up the track
PICKER_END :: f32(30) // track to panel edge, top and bottom

// The picker: a slider standing on the chip that opened it, one stop per
// choice, lowest at the bottom.
//
// It has been a list twice. First a column of bare words, then the same
// column with a heading, a line under every row saying what that choice was
// for, and the exact release each one runs — four lines of prose and a
// monospaced id to change one word on a chip. Nobody reads a paragraph to
// pick between five things they already know the names of; what they want to
// know is which one they are on and which way is more, and both of those are
// a position, not a sentence. So the words went and the shape stayed: a
// filled bar that rises as you go up, a knob that slides between the stops,
// and the label beside the stop swelling as the knob reaches it.
//
// Both chips share it — the model's and the effort's are the same slider with
// a different list — and it is dragged, clicked or walked with the arrow
// keys, all of them writing the same one value. There is no pending choice
// held while you drag: what the knob is on is what is chosen, and a slider
// that had to be confirmed is a slider with a second copy of its own position.
@(private = "file")
draw_picker :: proc(
	app: ^App,
	chip: Rect,
	labels: []string,
	at: int,
	tag: string,
	open: bool,
) -> (choice: int, picked: bool) {
	ui := &app.ui
	// Shut is a length of time from open, not a frame. The tween is ticked
	// whether or not there is a chip to hang the slider off, so a picker the
	// page took away with it cannot come back halfway through its own
	// movement the next time it is asked for.
	t := ui_tween(ui, ui_id(tag, PICKER_ANIM), open ? 1 : 0, PICKER_OPEN)
	if t <= 0 || chip.w <= 0 do return 0, false

	n := len(labels)
	LABEL_PX :: f32(15) // the stop the knob is on; the rest shrink toward 13
	TRACK_X :: f32(30) // the track's centre, from the panel's right edge
	GAP :: f32(28) // between the longest label and the track

	text_w := f32(0)
	for label in labels do text_w = max(text_w, font_width(&ui.bold, label, LABEL_PX + 2))
	w := max(chip.w, 20 + text_w + GAP + TRACK_X)
	h := f32(n - 1) * PICKER_STEP + PICKER_END * 2
	r := Rect{chip.x + chip.w - w, chip.y - h - 10, w, h}
	// It stands up off a chip near the bottom of the window, and in a short
	// window a tall enough slider runs off the top of it. Checked here rather
	// than by keeping the list short enough that it could not happen.
	if r.y < 8 do r.y = min(chip.y + chip.h + 8, ui.size.y - h - 8)
	r.y = max(r.y, 8)
	r.x = clamp(r.x, 8, max(8, ui.size.x - w - 8))

	track_x := r.x + r.w - TRACK_X
	foot := r.y + r.h - PICKER_END // the bottom stop, which is choice 0
	stop_y :: proc(foot: f32, i: f32) -> f32 {return foot - i * PICKER_STEP}
	// Which stop a point on the track is nearest. The whole panel is the
	// grab area: it is a slider, not a list of buttons with a slider drawn
	// down one side, and a press three pixels off the rail that did nothing
	// is the thing that makes a control feel like it is ignoring you.
	nearest :: proc(foot, y: f32, n: int) -> int {
		return clamp(int(math.round((foot - y) / PICKER_STEP)), 0, n - 1)
	}

	drag := ui_id(tag, PICKER_KNOB)
	hover := -1
	if open {
		// Anywhere else closes it.
		if ui.pressed && !rect_contains(r, ui.mouse) && !rect_contains(chip, ui.mouse) do app.overlay = .None
		// And a press inside it belongs to it, whatever has already claimed
		// it: this is drawn last, over things that are drawn as buttons.
		ui_claim(ui, r)
		if ui.pressed && rect_contains(r, ui.mouse) do ui.active = drag
		if ui.active == drag {
			if v := nearest(foot, ui.mouse.y, n); v != at do choice, picked = v, true
			// Let go and it is put away, wherever the pointer has got to: the
			// press picked, and there is nothing left to confirm.
			if ui.released {
				ui.active = 0
				app.overlay = .None
			}
		} else if ui_hovered(ui, r) {
			hover = nearest(foot, ui.mouse.y, n)
		}
	}

	// Anchored at the corner the chip is under, so it comes up out of the
	// chip and not out of the middle of nothing. Only the drawing moves: the
	// stops are hit where they have settled, which is where they are for all
	// but a tenth of a second.
	e := ease_out(t)
	// Up on a spring, so it lands a touch too big and gives: the panel has
	// weight, and the chip it came out of is where the weight is anchored.
	pop := ui_spring(ui, ui_id(tag, PICKER_POP), open ? 1 : 0, 320, 13)
	s := 0.9 + 0.1 * pop
	ui_push_zoom(ui, s, {(r.x + r.w) * (1 - s), (r.y + r.h) * (1 - s) + (1 - e) * 14})
	defer ui_pop_zoom(ui)
	a := t

	SHADOW :: Color(0xff000000)
	ui_rect(ui, {r.x - 10, r.y + 2, r.w + 20, r.h + 18}, color_alpha(SHADOW, 0.12 * a), 28)
	ui_rect(ui, {r.x - 2, r.y + 4, r.w + 4, r.h + 8}, color_alpha(SHADOW, 0.26 * a), 18)
	// A hairline of the type colour around it, so the panel has an edge
	// against the transcript it covers instead of melting into it.
	ui_rect(ui, {r.x - 1, r.y - 1, r.w + 2, r.h + 2}, color_alpha(TEXT, 0.12 * a), 17)
	ui_rect(ui, r, color_alpha(PANEL_HI, a), 16)

	// Where the knob actually is, which is a moment behind where it belongs:
	// the bar, the labels and the light all read off this one number, so
	// nothing in here can be a step ahead of anything else in it.
	// On a spring, so a knob thrown up three stops goes a shade past the
	// last one and drops back onto it.
	pos := ui_spring(ui, drag, f32(at), 380, 17)
	knob := stop_y(foot, pos)
	// How far it still has to go, which is how hard it is moving. The knob
	// swells while it travels and settles when it lands — the whole reason
	// the eye follows it across four stops instead of losing it.
	kick := clamp(abs(f32(at) - pos), 0, 1)

	top := stop_y(foot, f32(n - 1))
	ui_rect(ui, {track_x - 3, top, 6, foot - top}, color_alpha(TEXT, 0.10 * a), 3)
	// The light under the bar. It is drawn wide and faint under the bar
	// itself rather than as a second bar, so the track glows where it is
	// filled instead of gaining an outline.
	ui_rect(ui, {track_x - 9, knob - 6, 18, foot - knob + 12}, color_alpha(ACCENT, 0.14 * a), 9)
	// The bar, brightest at the knob and falling away toward the foot, so it
	// reads as filled from below rather than as a coloured stick.
	fill := Rect{track_x - 3, knob, 6, foot - knob}
	lo := color_alpha(ACCENT, 0.45 * a)
	hi := color_alpha(ACCENT, a)
	ui_quad_corners(
		ui,
		{{fill.x, fill.y}, {fill.x + fill.w, fill.y}, {fill.x + fill.w, fill.y + fill.h}, {fill.x, fill.y + fill.h}},
		{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
		{hi, hi, lo, lo},
		WHITE_TEX,
	)
	ui_circle(ui, {track_x, foot}, 3, lo)

	for label, i in labels {
		y := stop_y(foot, f32(i))
		// How near the knob is to this stop, which is the one number every
		// row is drawn from: the notch, the type size and the colour all come
		// off it, so a label cannot be lit while its notch is dark.
		near := clamp(1 - abs(pos - f32(i)), 0, 1)
		on := i <= at
		// Where a press would land, said on the track and not only in the
		// label: the whole panel is the grab area, so the ring is the only
		// thing telling you that the pointer over a word is over a stop.
		if i == hover do ui_circle(ui, {track_x, y}, 9, color_alpha(TEXT, 0.12 * a))
		ui_circle(ui, {track_x, y}, 3.5 + 1.5 * near, color_alpha(on ? ACCENT : TEXT, (on ? 0.9 : 0.18) * a))
		px := LABEL_PX - 2 + 3 * near
		col := color_mix(i == hover ? MUTED : FAINT, TEXT, near)
		lw := font_width(near > 0.5 ? &ui.bold : &ui.regular, label, px)
		ui_text(
			ui,
			near > 0.5 ? &ui.bold : &ui.regular,
			label,
			{track_x - GAP - lw, y - px * 0.72},
			px,
			color_alpha(col, a),
		)
	}

	// The knob last, over the bar and the notches it sits on.
	ui_circle(ui, {track_x, knob}, 15 + 4 * kick, color_alpha(ACCENT, 0.18 * a))
	ui_circle(ui, {track_x, knob}, 9 + 2 * kick, color_alpha(ACCENT, a))
	ui_circle(ui, {track_x, knob}, 3.5, color_alpha(TEXT, a))
	return
}

// The two controls the window has: which model answers and how hard it
// thinks. Every box that starts work carries them — the composer inside a
// thread and the box under the grid — because the moment the work is written
// is the moment the choice is about, and for a while the choice could only be
// made from inside a thread you had to open first.
//
// This is also the one place the chip rects are written down. The picker
// opens off them, and two boxes each keeping their own copy of where their
// chips were is two popups to keep in step.
@(private = "file")
draw_chips :: proc(app: ^App, box: Rect, y: f32) {
	ui := &app.ui
	// The chips end where the box does. They used to have to stop short of
	// the corner that says what the harness has cost, which was a panel in
	// this one — the two controls the window has, under an opaque readout,
	// with their picker opening behind it. The dial that replaced it stands in
	// the other corner, so there is nothing here to be kept off.
	right := box.x + box.w - 12
	// The model reads first, left to right: it is the choice that decides
	// what answers, and effort is a setting on top of it. They were the other
	// way round because the row is laid out from its right edge, which is a
	// reason about the code and not about the two words.
	ex := draw_chip(app, ui_id("effort-chip"), right, y, effort_label[app.effort], app.overlay == .Effort)
	if ui.pressed && ui.hot == ui_id("effort-chip") do app.overlay = app.overlay == .Effort ? .None : .Effort
	app.effort_chip = Rect{ex, y - 5, right - ex, 26}
	cx := draw_chip(app, ui_id("model-chip"), ex - 8, y, model_label[app.model], app.overlay == .Model)
	if ui.pressed && ui.hot == ui_id("model-chip") do app.overlay = app.overlay == .Model ? .None : .Model
	app.model_chip = Rect{cx, y - 5, ex - 8 - cx, 26}
}

// Both of them, every frame, whether or not they are open: the movement in
// and out is the picker's own, so it has to be asked even while it is shut.
// The chip rect is this frame's or it is nothing, so a picker left open by a
// page that has gone has nothing to hang off and is not drawn.
@(private = "file")
draw_pickers :: proc(app: ^App) {
	if m, picked := draw_picker(
		app,
		app.model_chip,
		slice.enumerated_array(&model_label),
		int(app.model),
		"model",
		app.overlay == .Model,
	); picked {
		app.model = Model(m)
		model_save(app.model)
	}
	if e, picked := draw_picker(
		app,
		app.effort_chip,
		slice.enumerated_array(&effort_label),
		int(app.effort),
		"effort",
		app.overlay == .Effort,
	); picked {
		app.effort = Effort(e)
		effort_save(app.effort)
	}
}

// A small text chip, right-aligned at `right`. Returns its left edge.
//
// `open` is whether the popup hanging off it is up, and it is the chip's own
// question because the popup is drawn somewhere else entirely: a list came up
// over the transcript with both chips still sitting there unlit, and which of
// the two it belonged to was a guess. The chip it came from wears the accent
// while it is open.
@(private = "file")
draw_chip :: proc(app: ^App, id: u64, right, y: f32, label: string, open: bool) -> f32 {
	ui := &app.ui
	w := font_width(&ui.regular, label, 14) + 30
	r := Rect{right - w, y - 5, w, 26}
	_, hovered := ui_invisible_button(ui, id, r)
	// Eased rather than switched, so the chip and the popup it belongs to are
	// one movement instead of a light going on next to one.
	lit := ui_anim(ui, id, open ? 1 : 0, 26)
	// And it swells under the pointer, on a spring, so it gives a little
	// before it holds. The hit rect is `r`; only the drawing grows.
	up := ui_spring(ui, ui_id_ptr(&app.ui, int(id)), hovered || open ? 1 : 0, 400, 12)
	g := 2 * up
	d := Rect{r.x - g, r.y - g, r.w + g * 2, r.h + g * 2}
	bg := color_mix(hovered ? PANEL_HI : color_alpha(PANEL_HI, 0.5), color_mix(PANEL_HI, ACCENT, 0.55), lit)
	ui_rect(ui, d, bg, 13 + g)
	if ui_entered(ui, id, hovered) do ui_ripple(ui, id, ui.mouse, TOUCH, r.w)
	ui_push_clip(ui, d)
	ui_draw_ripples(ui, id)
	ui_pop_clip(ui)
	ui_circle(ui, {r.x + 12, r.y + 13}, 3.5 + up, color_mix(ACCENT, TEXT, lit))
	ui_text(ui, &ui.regular, label, {r.x + 21, y}, 14, color_mix(hovered ? TEXT : MUTED, TEXT, lit))
	return r.x
}

// --- an editable text box ---------------------------------------------------

// How wide a pasted picture is where it sits in the words, in multiples of the
// type size. Everything the box measures — the wrap, the click, the selection,
// the caret — asks editor_width for it, so there is one answer to how far a
// picture pushes the words after it along.
IMG_CELL :: f32(1.6)

// The width of `text[from:to]` as it is drawn, which is not the width of the
// letters in it: a path is drawn as the picture it names, one cell wide
// however long the path is.
editor_width :: proc(font: ^Font, text: string, px: f32, from, to: int) -> f32 {
	w: f32
	run := from
	i := from
	for i < to {
		end, ok := image_at(text, i)
		if !ok || end > to {
			i += 1
			continue
		}
		w += font_width(font, text[run:i], px) + px * IMG_CELL
		i = end
		run = i
	}
	return w + font_width(font, text[run:to], px)
}

// Wraps the editor's text and records the byte range of every laid-out line,
// which is what makes up/down movement and click-to-position work.
editor_layout_lines :: proc(ui: ^UI, e: ^Editor, width: f32, font: ^Font, px: f32) {
	clear(&e.lines)
	text := editor_text(e)
	scale := font_scale(font, px)

	start := 0
	last_break := -1
	w: f32
	i := 0
	for i <= len(text) {
		if i == len(text) {
			append(&e.lines, Span{start, i})
			break
		}
		// A picture measures as one thing and never breaks in the middle: the
		// path is not on screen, so a line ending halfway through one would be
		// a line ending nowhere.
		if end, is_img := image_at(text, i); is_img {
			cw := px * IMG_CELL
			if w + cw > width && i > start {
				cut := last_break > start ? last_break : i
				append(&e.lines, Span{start, cut})
				start = cut
				last_break = -1
				w = 0
				continue
			}
			w += cw
			i = end
			continue
		}
		if text[i] == '\n' {
			append(&e.lines, Span{start, i})
			start = i + 1
			last_break = -1
			w = 0
			i += 1
			continue
		}
		step := 1
		for i + step < len(text) && (text[i + step] & 0xc0) == 0x80 do step += 1
		r: rune = ' '
		for ch in text[i:] {
			r = ch
			break
		}
		cw := font_glyph(font, r).advance * scale
		if w + cw > width && i > start {
			cut := last_break > start ? last_break : i
			append(&e.lines, Span{start, cut})
			start = cut
			last_break = -1
			w = 0
			i = cut
			continue
		}
		if text[i] == ' ' do last_break = i + 1
		w += cw
		i += step
	}
	if len(e.lines) == 0 do append(&e.lines, Span{0, 0})
}

// Which byte of a laid-out line the pointer landed on. A picture is one thing
// to land on: click either half of it and the caret goes to the side it was
// nearer, never into the middle of a path nobody can see.
@(private = "file")
byte_at_x :: proc(font: ^Font, text: string, span: Span, px, target: f32) -> int {
	scale := font_scale(font, px)
	w: f32
	i := span.start
	for i < span.end {
		cw: f32
		next := i
		if end, ok := image_at(text, i); ok {
			cw, next = px * IMG_CELL, end
		} else {
			r, size := utf8.decode_rune_in_string(text[i:])
			cw, next = font_glyph(font, r).advance * scale, i + max(size, 1)
		}
		if w + cw / 2 > target do return i
		w += cw
		i = next
	}
	return span.end
}

draw_editor :: proc(app: ^App, e: ^Editor, r: Rect, font: ^Font, px: f32, focused: bool, max_lines: int) {
	ui := &app.ui
	text := editor_text(e)
	lh := px * 1.5
	first, shown := editor_window(e, max_lines)

	// Click and drag to place the caret and select.
	id := ui_id_ptr(e)
	_, hovered := ui_invisible_button(ui, id, r)
	_ = hovered
	if (ui.pressed && ui_hovered(ui, r)) || (ui.down && ui.active == id) {
		row := clamp(first + int((ui.mouse.y - r.y) / lh), 0, max(len(e.lines) - 1, 0))
		span := e.lines[row]
		e.cursor = byte_at_x(font, text, span, px, ui.mouse.x - r.x)
		if ui.pressed {
			e.anchor = e.cursor
			if ui.click_count >= 2 {
				e.anchor = word_left(text, min(e.cursor + 1, len(text)))
				e.cursor = word_right(text, e.anchor)
			}
			if ui.click_count >= 3 {
				e.anchor = span.start
				e.cursor = span.end
			}
		}
		e.last_edit = ui.time
	}

	// Selection, then the text, then the caret on top.
	clear(&e.imgs)
	lo, hi := editor_selection(e)
	y := r.y
	for i in first ..< min(first + shown, len(e.lines)) {
		span := e.lines[i]
		if hi > lo && span.end >= lo && span.start <= hi {
			x0 := editor_width(font, text, px, span.start, max(lo, span.start))
			x1 := editor_width(font, text, px, span.start, min(hi, span.end))
			ui_rect(ui, {r.x + x0, y, max(x1 - x0, 2), lh}, color_alpha(ACCENT, 0.30), 2)
		}
		draw_editor_line(app, e, font, text, span, r.x, y, px, lh)
		y += lh
	}

	if focused {
		row, off := editor_locate(e, e.cursor)
		span := e.lines[clamp(row, 0, len(e.lines) - 1)]
		cx := r.x + editor_width(font, text, px, span.start, span.start + off)
		row -= first

		// A block caret, the width of the character it sits on, with that
		// character redrawn dark on top of it — a terminal cursor, because a
		// hairline is hard to find in a window this size.
		// Blink like a terminal: on, off, half a second each. Two frames a
		// second, asked for by the frame that needs them, rather than sixty
		// frames a second forever.
		idle := ui.time - e.last_edit
		alpha := f32(1)
		if idle > 0.6 {
			phase := (idle - 0.6) / BLINK
			alpha = int(phase) % 2 == 0 ? 1 : 0.18
			ui_wake_in(ui, BLINK * (1 - (phase - f32(int(phase)))))
		} else {
			ui_wake_in(ui, 0.6 - idle)
		}

		// Terminal-shaped: as wide as the character it covers, and exactly the
		// cell the glyph is drawn into — same origin and same height as the
		// text above, so the block lands on the character and not beside it.
		under: string
		w := px * CARET_EMPTY
		alpha_over := f32(1)
		if e.cursor < span.end {
			if _, on_img := image_at(text, e.cursor); on_img {
				// Over a picture the block goes see-through and the glyph
				// underneath is not redrawn: a solid caret the width of the
				// picture is a caret that hides what it is sitting on.
				w = px * IMG_CELL
				alpha_over = 0.35
			} else {
				under = text[e.cursor:next_rune(text, e.cursor)]
				w = max(font_width(font, under, px), px * 0.35)
			}
		}
		top := r.y + f32(row) * lh + 2
		height := (font.ascent - font.descent) * font_scale(font, px)
		ui_rect(ui, {cx, top, w, height}, color_alpha(ACCENT, alpha * alpha_over), 1.5)
		if under != "" && alpha > 0.6 {
			ui_text(ui, font, under, {cx, top}, px, BG)
		}
	}

	// A picture in the middle of a sentence is the size of the letters around
	// it, which is enough to say one is there and nothing like enough to see
	// what is in it. Resting on it gives the whole thing, out of the same
	// spring the composer's thumbnails use — and nothing is written down about
	// which one is open, because the answer is the one under the pointer.
	peek := Rect{}
	peek_at := -1
	for cell, i in e.imgs do if ui_hovered(ui, cell.r) do peek, peek_at = cell.r, i
	grow := ui_spring(ui, ui_id_ptr(e) + 7, peek_at >= 0 ? 1 : 0, 320, 18)
	if peek_at >= 0 {
		cell := e.imgs[peek_at]
		end, _ := image_at(text, cell.at)
		draw_image_peek(app, peek, app_preview(app, text[cell.at:end]), grow)
	}
}

// One laid-out line, with the pictures it names drawn where their paths are
// written. The path itself is never on screen: it is what the harness is given
// and what tells the card which picture it carries, and it is eighty
// characters of noise in the middle of a sentence someone is writing. What it
// names is the only part worth seeing, so that is what sits there.
@(private = "file")
draw_editor_line :: proc(app: ^App, e: ^Editor, font: ^Font, text: string, span: Span, x, y, px, lh: f32) {
	ui := &app.ui
	cell := px * IMG_CELL
	at := x
	run := span.start
	i := span.start
	for i < span.end {
		end, ok := image_at(text, i)
		if !ok || end > span.end {
			i += 1
			continue
		}
		ui_text(ui, font, text[run:i], {at, y + 2}, px, TEXT)
		at += font_width(font, text[run:i], px)
		// A shade smaller than the line it sits in, so a picture in the middle
		// of a sentence does not push the line apart.
		box := Rect{at + 1, y + (lh - cell) / 2 + 1, cell - 2, cell - 2}
		append(&e.imgs, Image_Cell{i, box})
		if a := app_preview(app, text[i:end]); a.width > 0 {
			ui_image_cover(ui, box, a.tex, a.width, a.height, 4)
		} else {
			// Nothing decoded: a file that has been moved or deleted since it
			// was pasted. The words still carry the path — it is still what
			// goes out — so the space it takes is still held, in the shape of
			// a picture that will not open.
			ui_rect(ui, box, color_alpha(MUTED, 0.35), 4)
		}
		at += cell
		i = end
		run = i
	}
	ui_text(ui, font, text[run:span.end], {at, y + 2}, px, TEXT)
}

// True if the pointer was pressed inside `r` this frame, regardless of what
// widget claimed it — used to move keyboard focus.
clicked_in :: proc(app: ^App, r: Rect) -> bool {
	ui := &app.ui
	return ui.pressed && rect_contains(r, ui.mouse)
}
