package aithing

import "core:fmt"
import "core:math"
import "core:time"
import "core:slice"
import "core:strings"

// Everything on screen, rebuilt from the app state every frame. Measurement
// and drawing share one procedure per element with a `draw` flag, so a
// scrollbar's idea of how tall the transcript is can never drift from what
// actually gets drawn.

PAD :: f32(16)
// The composer's own ground: dark enough to read white text on, thin enough
// that the desktop behind the window still shows through it.
COMPOSER_BG :: Color(0x66202224)
BLINK :: f32(0.55) // caret on/off, in seconds
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
		// on a composer still on its way is a click nobody aimed, and while
		// the zoom is on it is not where it was laid out anyway.
		panel_mouse := ui.mouse
		if !arrived do ui.mouse = {-1e6, -1e6}
		draw_transcript(app, {full.x, full.y, full.w, full.h - composer_h})
		draw_composer(app, {full.x, full.y + full.h - composer_h, full.w, composer_h})
		ui.mouse = panel_mouse
		cw := composer_width(full.w)
		strip = {full.x + (full.w - cw) / 2, full.y + full.h - composer_h, cw, composer_h}
		if !arrived {
			ui_pop_zoom(ui)
			ui_pop_clip(ui)
		}
	} else {
		draw_project_head(app, full)
		if app_capture_open(app) {
			draw_capture(app, full)
			ch := capture_height(app, full.w)
			cw := composer_width(full.w)
			strip = {full.x + (full.w - cw) / 2, full.y + full.h - ch, cw, ch}
		}
		// Bottom left, clear of the capture box in the middle and of the
		// usage corner on the right.
		bottom := strip.h > 0 ? strip.y - 24 : full.y + full.h - PAD - 18
		draw_status(app, {full.x + PAD, bottom, full.w / 2 - PAD, 16})
	}
	draw_usage(app, full, strip)
	// Last, over everything: the corner that says what the harness has cost
	// is opaque and is drawn after the box the chips sit on, so a picker
	// drawn where it was chosen from came up behind that corner — a list you
	// were picking from half blind. Nothing else in the window is a popup, so
	// there is nothing for it to be under.
	draw_pickers(app)
	draw_launcher(app, full)
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
	ui_text(ui, &ui.bold, base_name(name), {full.x + GRID_PAD, full.y + 20}, 21, TEXT)
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

CAPTURE_PX :: f32(15)
CAPTURE_PAD :: f32(12)
CAPTURE_LINES :: 6 // how tall the box grows before it starts scrolling

// How wide the text in the box is, which is the one number the height and the
// draw have to agree on: they used to work it out separately — the height off
// the whole box, the draw off the box less ninety pixels it kept for a note —
// so a line that fitted for one wrapped for the other and the box came out a
// line short of what it was drawing.
@(private = "file")
capture_text_width :: proc(width: f32) -> f32 {
	return composer_width(width) - COMPOSER_SIDE * 2
}

// How much of the window the box takes, which the grid above it keeps clear.
capture_height :: proc(app: ^App, width: f32) -> f32 {
	ui := &app.ui
	if !app_capture_open(app) do return 0
	editor_layout_lines(ui, &app.capture, capture_text_width(width), &ui.regular, CAPTURE_PX)
	_, lines := editor_window(&app.capture, CAPTURE_LINES)
	return CAPTURE_PAD * 2 + f32(lines) * (CAPTURE_PX * 1.5) + COMPOSER_CHIPS
}

@(private = "file")
draw_capture :: proc(app: ^App, full: Rect) {
	ui := &app.ui
	h := capture_height(app, full.w)
	width := composer_width(full.w)
	x := full.x + (full.w - width) / 2
	// The box is the box. It used to keep a line above itself naming the
	// project the cards would land in — "in aithing" — and that line is gone
	// with the room it took: the box is only there on a grid narrowed to one
	// project, and the heading over that grid has already said which.
	box := Rect{x, full.y + full.h - h + 6, width, h - 18}

	focused := app_focus(app) == .Capture
	ui_punch(ui, box, COMPOSER_BG, 14)
	ui_rect(ui, box, focused ? color_alpha(ACCENT, 0.35) : color_alpha(BORDER, 0.9), 14)
	if ui_hovered(ui, box) do ui.cursor_text = true

	text_w := capture_text_width(full.w)
	editor_layout_lines(ui, &app.capture, text_w, &ui.regular, CAPTURE_PX)
	_, lines := editor_window(&app.capture, CAPTURE_LINES)
	text_h := f32(lines) * (CAPTURE_PX * 1.5)
	text_r := Rect{box.x + COMPOSER_SIDE, box.y + CAPTURE_PAD, text_w, text_h}
	if editor_text(&app.capture) == "" {
		ui_text(ui, &ui.regular, "what needs doing", {text_r.x, text_r.y + 1}, CAPTURE_PX, FAINT)
	}
	draw_editor(app, &app.capture, text_r, &ui.regular, CAPTURE_PX, focused, CAPTURE_LINES)

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
	draw_chips(app, full, box, chip_y)
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
	t := ui_anim(ui, ui_id("launcher"), app.overlay == .Launcher ? 1 : 0, 16)
	if t < 0.01 do return
	if t < 0.99 do ui_wake_in(ui, 0)

	ui_rect(ui, full, color_alpha(Color(0xff000000), 0.88 * t))

	w := min(full.w - 120, 980)
	x := full.x + (full.w - w) / 2
	y := full.y + full.h * 0.14 + (1 - t) * 18

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
		clicked, hovered := ui_invisible_button(ui, ui_id("launch-row", i), r)
		if hovered && ui.mouse_moved do c.menu_at = i
		on := i == c.menu_at
		if on {
			ui_rect(ui, r, color_alpha(PANEL_HI, 0.9 * t), 12)
			ui_rect(ui, {r.x, r.y + 10, 3, r.h - 20}, color_alpha(ACCENT, t), 2)
		}
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

COMPOSER_PX :: f32(19)
COMPOSER_MIN :: f32(84)
COMPOSER_LINES :: 8 // how tall the box grows before it starts scrolling
COMPOSER_PAD :: f32(12) // inside the box, above the text and below it
COMPOSER_CHIPS :: f32(36) // the band along the bottom holding the model chip
COMPOSER_SIDE :: f32(18) // the text inset from either edge of the box
COMPOSER_THUMB :: f32(72)

// The box is exactly as tall as what goes in it, and this is the one place
// that says how tall that is: draw_composer lays out against the same numbers,
// so the text never lands under the chip row.
composer_box_height :: proc(app: ^App, width: f32) -> f32 {
	ui := &app.ui
	inner := composer_width(width) - COMPOSER_SIDE * 2
	editor_layout_lines(ui, &app.editor, inner, &ui.regular, COMPOSER_PX)
	_, lines := editor_window(&app.editor, COMPOSER_LINES)
	h := COMPOSER_PAD * 2 + f32(lines) * (COMPOSER_PX * 1.5)
	if len(app.attach) > 0 do h += COMPOSER_THUMB + 14
	return h + COMPOSER_CHIPS
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
	return max(composer_box_height(app, width) + 18, COMPOSER_MIN)
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
	ui_rect(ui, box, focused ? color_alpha(ACCENT, 0.35) : color_alpha(BORDER, 0.9), 14)

	if ui_hovered(ui, box) do ui.cursor_text = true

	inner_y := box.y + COMPOSER_PAD

	// Pasted images sit above the text, each with a corner button to drop it.
	if len(app.attach) > 0 {
		thumb := COMPOSER_THUMB
		tx := box.x + 14
		for i := 0; i < len(app.attach); i += 1 {
			a := &app.attach[i]
			tr := Rect{tx, inner_y, thumb, thumb}
			ui_image(ui, tr, a.tex, 8)
			del := Rect{tr.x + thumb - 16, tr.y - 4, 20, 20}
			clicked, hovered := ui_invisible_button(ui, ui_id("unattach", i), del)
			ui_circle(ui, {del.x + 10, del.y + 10}, 8, hovered ? RED : Color(0xcc000000))
			ui_text_centred(ui, &ui.bold, "x", del, 11, TEXT)
			if clicked {
				attachment_destroy(a)
				ordered_remove(&app.attach, i)
				i -= 1
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
	if editor_text(&app.editor) == "" && !focused {
		ui_text(ui, &ui.regular, "Reply to Claude...", {text_r.x, text_r.y + 2}, COMPOSER_PX, FAINT)
	}
	draw_editor(app, &app.editor, text_r, &ui.regular, COMPOSER_PX, focused, COMPOSER_LINES)

	// The only two controls in the window: which model answers and how hard
	// it thinks. Permissions are whatever the harness is already configured
	// to do.
	chip_y := box.y + box.h - COMPOSER_CHIPS / 2 - 8
	draw_chips(app, {r.x, 0, r.w, r.y + r.h}, box, chip_y)
	if app_chat_busy(app) {
		// While a turn is in flight the same corner says so, and stops it.
		stop := Rect{box.x + 14, chip_y - 3, 58, 22}
		clicked, hovered := ui_invisible_button(ui, ui_id("stop"), stop)
		ui_rect(ui, stop, hovered ? PANEL_HI : Color(0x00000000), 6)
		ui_rect(ui, {stop.x + 8, stop.y + 7, 8, 8}, RED, 2)
		ui_text(ui, &ui.regular, "stop", {stop.x + 22, stop.y + 3}, 13, hovered ? TEXT : MUTED)
		if clicked do app_interrupt(app)
	}
	// The strip that used to carry the status is gone, so it says its piece
	// down here instead, out of the way of the text.
	left := f32(14) + (app_chat_busy(app) ? 66 : 0)
	draw_status(app, {box.x + left, chip_y + 3, box.w - 220 - left, 16})
}

// What the window has to say for itself, wherever it is standing. This used
// to be drawn inside the composer and nowhere else, so it existed only on the
// thread page — and the grid is where you sit while cards run, which meant
// "built — restart to pick it up" was said to an empty room. Every landing
// note, every push that was refused and every finished build announced itself
// somewhere nobody was looking, which is most of what "nothing ever seems to
// happen" was.
draw_status :: proc(app: ^App, at: Rect) {
	if app.status == "" || app.status == "ready" do return
	if at.w < 40 do return
	ui := &app.ui
	buf: [128]u8
	msg := font_ellipsize(&ui.regular, app.status, 13, at.w, buf[:])
	ui_text(ui, &ui.regular, msg, {at.x, at.y}, 13, FAINT)
}

// How long the picker takes to arrive, and how far it starts from where it
// ends up. Short enough that it is under the pointer by the time the pointer
// has got there, and long enough to say which chip it came out of.
PICKER_OPEN :: f32(0.11)
PICKER_ANIM :: 101 // salts on the tag, clear of the row ids, which are 0..n
PICKER_PILL :: 102
GAUGE_W :: f32(38)

// The picker itself: rows stacked above the chip that opened it. Both chips
// share it — the model's and the effort's are the same popup with a different
// list, and a second copy of this is a second popup to keep in step.
//
// What is different between them is data, not code: the heading, the rows,
// the line under each row saying what it is for, and then either the exact
// release the row runs — the ids are pinned so a name cannot drift to another
// build, and the picker was the one place that promise was invisible — or a
// gauge, for a list that is a ladder. It is sized off that content and off
// nothing else; the width used to be max(chip.w, 150), which is the chip's
// business and not the list's.
//
// And it grows out of the chip's own corner rather than appearing over the
// transcript. The two chips sit side by side and this is wider than either,
// so a list that was simply there gave no sign of which of the two it was a
// list of. The movement says it, in the one place anyone is looking.
@(private = "file")
draw_picker :: proc(
	app: ^App,
	chip: Rect,
	head: string,
	labels: []string,
	notes: []string,
	hints: []string, // what each row runs, right-aligned; empty for none
	gauge: bool, // right-aligned rungs instead, for a list that is a ladder
	at: int,
	tag: string,
	open: bool,
) -> (choice: int, picked: bool) {
	ui := &app.ui
	LABEL_PX :: f32(15)
	NOTE_PX :: f32(12.5)
	HINT_PX :: f32(11)
	PAD_X :: f32(16)
	DOT_X :: f32(16) // where the tick sits, from the row's left edge
	TEXT_X :: f32(34)
	GAP :: f32(24) // between the longest label and whatever is right-aligned

	// Shut is a length of time from open, not a frame. The tween is ticked
	// whether or not there is a chip to hang the popup off, so a picker the
	// page took away with it cannot come back halfway through its own
	// movement the next time it is asked for.
	t := ui_tween(ui, ui_id(tag, PICKER_ANIM), open ? 1 : 0, PICKER_OPEN)
	if t <= 0 || chip.w <= 0 do return 0, false

	row_h := f32(48)
	head_h := f32(28)
	// As wide as the widest thing in it, and no wider.
	right_w := gauge ? GAUGE_W : 0
	for hint in hints do right_w = max(right_w, font_width(&ui.mono, hint, HINT_PX))
	w := font_width(&ui.bold, head, 12) + TEXT_X + PAD_X
	for label, i in labels {
		line := font_width(&ui.regular, label, LABEL_PX)
		if right_w > 0 do line += GAP + right_w
		if i < len(notes) do line = max(line, font_width(&ui.regular, notes[i], NOTE_PX))
		w = max(w, line + TEXT_X + PAD_X)
	}
	w = min(w, ui.size.x - 24)
	h := head_h + row_h * f32(len(labels)) + 12

	r := Rect{chip.x + chip.w - w, chip.y - h - 8, w, h}
	// It opens upward off a chip that sits near the bottom of the window, but
	// a list this tall in a short window can run off the top, and one this
	// wide off the left. Both edges are checked here rather than by keeping
	// the popup small enough that neither could happen.
	if r.y < 8 do r.y = min(chip.y + chip.h + 8, ui.size.y - h - 8)
	r.y = max(r.y, 8)
	r.x = clamp(r.x, 8, max(8, ui.size.x - w - 8))
	row_at :: proc(r: Rect, head_h, row_h: f32, i: int) -> Rect {
		return {r.x + 6, r.y + head_h + 6 + f32(i) * row_h, r.w - 12, row_h - 4}
	}

	// What the pointer is on, asked before anything is drawn: the lit row
	// goes under the labels, and finding it means asking every row first.
	// While it is on its way out it asks nothing — a popup nobody can see any
	// more must not be eating presses meant for what is behind it.
	hover := -1
	if open {
		// Anywhere else closes it.
		if ui.pressed && !rect_contains(r, ui.mouse) && !rect_contains(chip, ui.mouse) do app.overlay = .None
		// And a press inside it belongs to it, whatever has already claimed
		// it: this is drawn last, over things that are drawn as buttons.
		ui_claim(ui, r)
		for i in 0 ..< len(labels) {
			clicked, hovered := ui_invisible_button(ui, ui_id(tag, i), row_at(r, head_h, row_h, i))
			if hovered do hover = i
			if clicked {
				app.overlay = .None
				choice, picked = i, true
			}
		}
	}

	// Anchored at the corner the chip is under, so it comes up out of the
	// chip and not out of the middle of nothing. Only the drawing moves: the
	// rows are hit where they have settled, which is where they are for all
	// but a tenth of a second.
	e := ease_out(t)
	s := 0.96 + 0.04 * e
	ui_push_zoom(ui, s, {(r.x + r.w) * (1 - s), (r.y + r.h) * (1 - s) + (1 - e) * 12})
	defer ui_pop_zoom(ui)
	a := t

	SHADOW :: Color(0xff000000)
	ui_rect(ui, {r.x - 10, r.y + 2, r.w + 20, r.h + 18}, color_alpha(SHADOW, 0.12 * a), 26)
	ui_rect(ui, {r.x - 2, r.y + 4, r.w + 4, r.h + 8}, color_alpha(SHADOW, 0.26 * a), 16)
	// A hairline of the type colour around it, so the panel has an edge
	// against the transcript it covers instead of melting into it.
	ui_rect(ui, {r.x - 1, r.y - 1, r.w + 2, r.h + 2}, color_alpha(TEXT, 0.12 * a), 15)
	ui_rect(ui, r, color_alpha(PANEL_HI, a), 14)

	// What you are choosing, said once at the top. Two chips sit side by side
	// and open the same shaped list, and without this the only way to tell
	// which one you had clicked was to read the words in it.
	ui_text(ui, &ui.bold, head, {r.x + TEXT_X, r.y + 9}, 12, color_alpha(FAINT, a))
	ui_rect(ui, {r.x + PAD_X, r.y + head_h + 1, r.w - PAD_X * 2, 1}, color_alpha(TEXT, 0.08 * a))

	// One lit row that slides between them, rather than a rectangle blinking
	// on and off wherever the pointer lands. It rests on the row that is
	// chosen when the pointer is elsewhere, so the list is never showing
	// nothing at all — and where it slid from is what says the row you left
	// and the row you are on are the same kind of thing.
	pos := ui_anim(ui, ui_id(tag, PICKER_PILL), f32(hover >= 0 ? hover : at), 30)
	pill := row_at(r, head_h, row_h, 0)
	pill.y += pos * row_h
	ui_rect(ui, pill, color_alpha(color_mix(PANEL, ACCENT, hover >= 0 ? 0.34 : 0.16), a), 10)

	for label, i in labels {
		row := row_at(r, head_h, row_h, i)
		on := i == at
		lit := on || i == hover
		if on {
			ui_circle(ui, {row.x + DOT_X - 6, row.y + 14}, 7, color_alpha(ACCENT_DIM, 0.4 * a))
			ui_circle(ui, {row.x + DOT_X - 6, row.y + 14}, 3.5, color_alpha(ACCENT, a))
		}
		ui_text(ui, on ? &ui.bold : &ui.regular, label, {row.x + TEXT_X - 6, row.y + 6}, LABEL_PX, color_alpha(lit ? TEXT : MUTED, a))
		if i < len(notes) {
			ui_text(ui, &ui.regular, notes[i], {row.x + TEXT_X - 6, row.y + 25}, NOTE_PX, color_alpha(lit ? MUTED : FAINT, a))
		}
		if i < len(hints) {
			hw := font_width(&ui.mono, hints[i], HINT_PX)
			ui_text(ui, &ui.mono, hints[i], {row.x + row.w - PAD_X - hw, row.y + 9}, HINT_PX, color_alpha(lit ? MUTED : FAINT, a))
		}
		if gauge do draw_gauge(ui, {row.x + row.w - PAD_X - GAUGE_W, row.y + 15}, i, len(labels), lit, a)
	}
	return
}

// How far up the ladder a row stands, as a shape rather than as a word. The
// five efforts are five claims that it is a lot, and only somebody who has
// read the enum knows that Max is past Xhigh.
@(private = "file")
draw_gauge :: proc(ui: ^UI, left_mid: [2]f32, level, of: int, lit: bool, a: f32) {
	bar := f32(5)
	gap := (GAUGE_W - bar * f32(of)) / f32(max(of - 1, 1))
	for j in 0 ..< of {
		bh := 4 + f32(j) * 2
		col := color_alpha(TEXT, 0.12)
		if j <= level do col = lit ? ACCENT : color_mix(ACCENT, MUTED, 0.45)
		ui_rect(ui, {left_mid.x + f32(j) * (bar + gap), left_mid.y + 6 - bh, bar, bh}, color_alpha(col, a), 1.5)
	}
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
draw_chips :: proc(app: ^App, full, box: Rect, y: f32) {
	ui := &app.ui
	right := chips_right(full, box)
	cx := draw_chip(app, ui_id("model-chip"), right, y, model_label[app.model], app.overlay == .Model)
	if ui.pressed && ui.hot == ui_id("model-chip") do app.overlay = app.overlay == .Model ? .None : .Model
	app.model_chip = Rect{cx, y - 5, right - cx, 26}
	ex := draw_chip(app, ui_id("effort-chip"), cx - 8, y, effort_label[app.effort], app.overlay == .Effort)
	if ui.pressed && ui.hot == ui_id("effort-chip") do app.overlay = app.overlay == .Effort ? .None : .Effort
	app.effort_chip = Rect{ex, y - 5, cx - 8 - ex, 26}
}

// Where the chip row ends. The box's own right edge, except where the corner
// that says what the harness has cost is standing in it: that panel keeps a
// floor under its width and is drawn last and opaque, so at the width the
// composer actually is — centred, 880 wide, in a 1180 window — it came down
// over the box's bottom right corner, which is exactly where these two chips
// are. The chips move in rather than the panel moving out, because where the
// panel stands is fixed on purpose: it is the one thing in the window that
// never changes, and it used to jump every time the box grew a line.
chips_right :: proc(full, box: Rect) -> f32 {
	right := box.x + box.w - 12
	if corner := usage_rect(full, box); corner.w > 0 do right = min(right, corner.x - 12)
	return right
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
		"which model answers",
		slice.enumerated_array(&model_label),
		slice.enumerated_array(&model_note),
		slice.enumerated_array(&model_flag),
		false,
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
		"how hard it thinks",
		slice.enumerated_array(&effort_label),
		slice.enumerated_array(&effort_note),
		nil,
		true,
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
	bg := color_mix(hovered ? PANEL_HI : color_alpha(PANEL_HI, 0.5), color_mix(PANEL_HI, ACCENT, 0.55), lit)
	ui_rect(ui, r, bg, 13)
	ui_circle(ui, {r.x + 12, r.y + 13}, 3.5, color_mix(ACCENT, TEXT, lit))
	ui_text(ui, &ui.regular, label, {r.x + 21, y}, 14, color_mix(hovered ? TEXT : MUTED, TEXT, lit))
	return r.x
}

// --- an editable text box ---------------------------------------------------

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

@(private = "file")
byte_at_x :: proc(font: ^Font, text: string, px, target: f32) -> int {
	scale := font_scale(font, px)
	w: f32
	for ch, i in text {
		cw := font_glyph(font, ch).advance * scale
		if w + cw / 2 > target do return i
		w += cw
	}
	return len(text)
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
		off := byte_at_x(font, text[span.start:span.end], px, ui.mouse.x - r.x)
		e.cursor = span.start + off
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
	lo, hi := editor_selection(e)
	y := r.y
	for i in first ..< min(first + shown, len(e.lines)) {
		span := e.lines[i]
		line := text[span.start:span.end]
		if hi > lo && span.end >= lo && span.start <= hi {
			s := max(lo, span.start) - span.start
			t := min(hi, span.end) - span.start
			x0 := font_width(font, line[:s], px)
			x1 := font_width(font, line[:t], px)
			ui_rect(ui, {r.x + x0, y, max(x1 - x0, 2), lh}, color_alpha(ACCENT, 0.30), 2)
		}
		ui_text(ui, font, line, {r.x, y + 2}, px, TEXT)
		y += lh
	}

	if focused {
		row, off := editor_locate(e, e.cursor)
		span := e.lines[clamp(row, 0, len(e.lines) - 1)]
		cx := r.x + font_width(font, text[span.start:span.start + off], px)
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
		w := px * 0.55
		if e.cursor < span.end {
			under = text[e.cursor:next_rune(text, e.cursor)]
			w = max(font_width(font, under, px), px * 0.35)
		}
		top := r.y + f32(row) * lh + 2
		height := (font.ascent - font.descent) * font_scale(font, px)
		ui_rect(ui, {cx, top, w, height}, color_alpha(ACCENT, alpha), 1.5)
		if under != "" && alpha > 0.6 {
			ui_text(ui, font, under, {cx, top}, px, BG)
		}
	}
}

// True if the pointer was pressed inside `r` this frame, regardless of what
// widget claimed it — used to move keyboard focus.
clicked_in :: proc(app: ^App, r: Rect) -> bool {
	ui := &app.ui
	return ui.pressed && rect_contains(r, ui.mouse)
}
