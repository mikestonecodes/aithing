package aithing

import "core:fmt"
import "core:math"
import "core:time"
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
		draw_canvas(app, full)
		ui.mouse = canvas_mouse
	}

	// The panel: a growing box, then the real thing once it has arrived. The
	// box and its shadow only exist while it is growing — they are what makes
	// a card look like it is lifting off the grid, and by the time it has
	// arrived there is no grid left to lift off.
	if arrived {
		composer_h := composer_height(app, panel.w)
		draw_transcript(app, {panel.x, panel.y, panel.w, panel.h - composer_h})
		draw_composer(app, {panel.x, panel.y + panel.h - composer_h, panel.w, composer_h})
		if app.overlay == .Model do draw_model_picker(app)
	} else if t > 0.01 {
		ui_rect(ui, {panel.x + 2, panel.y + 8, panel.w, panel.h}, color_alpha(Color(0xff000000), 0.4 * (1 - t)), 14 * (1 - t))
		ui_rect(ui, panel, BG, 14 * (1 - t))
		ui_text(ui, &ui.bold, app_chat_title(app), {panel.x + 20, panel.y + 16}, 16, color_alpha(TEXT, t))
	} else {
		draw_project_head(app, full)
		if app_capture_open(app) do draw_capture(app, full)
	}
	draw_launcher(app, full)
	if t > 0.01 && !arrived do ui_wake_in(ui, 0)
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
	return CAPTURE_PAD * 2 + f32(lines) * (CAPTURE_PX * 1.5) + 22
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

	// What Enter will do with what is in the box. Where the split falls is
	// read off the text rather than being a rule the writer has to keep to,
	// so the only way to know a full stop just made a second card — and a
	// second thread with it — is to be told before pressing Enter. It went
	// away with the line above the box, and taking it away made the split
	// look broken: two cards appeared out of one line with no warning.
	note := ""
	if strings.trim_space(editor_text(&app.capture)) != "" {
		n := len(todos_split(editor_text(&app.capture)))
		note = n == 1 ? "enter · runs it" : fmt.tprintf("enter · %d cards, a thread each", n)
	}
	if note != "" {
		nw := font_width(&ui.regular, note, 12)
		ui_text(
			ui,
			&ui.regular,
			note,
			{box.x + box.w - COMPOSER_SIDE - nw, box.y + box.h - 20},
			12,
			FAINT,
		)
	}
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

// Everything the typed text finds: the projects first, because narrowing to
// one is the commonest thing to want, then the threads themselves.
launcher_hits :: proc(app: ^App, query: string) -> []Hit {
	out := make([dynamic]Hit, context.temp_allocator)
	// The way back out of a narrowed grid, offered where the narrowing was
	// chosen. Esc does not do this: a project you picked is a thing you said,
	// and a key that backs out of everything else should not undo it.
	if app.canvas.project != "" {
		append(&out, Hit{session = -1, cwd = "", name = "all projects", sub = "everything"})
	}
	if query != "" {
		seen := make(map[string]int, context.temp_allocator)
		for s in app.sessions {
			name := strings.to_lower(base_name(s.cwd), context.temp_allocator)
			if !strings.contains(name, query) do continue
			if at, has := seen[s.cwd]; has {
				out[at].count += 1
				continue
			}
			seen[s.cwd] = len(out)
			append(&out, Hit{session = -1, cwd = s.cwd, name = base_name(s.cwd), sub = "project", count = 1})
		}
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

	// One card holding the whole menu, so the grid behind it reads as a
	// backdrop rather than as something still being offered.
	lower0 := strings.to_lower(strings.trim_space(editor_text(&app.search)), context.temp_allocator)
	rows := f32(len(launcher_hits(app, lower0)))
	card := Rect{x - 34, y - 34, w + 68, 128 + max(rows, 1) * 52 + 46}
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

	lower := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	hits := launcher_hits(app, lower)
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
	query := strings.to_lower(strings.trim_space(editor_text(&app.search)), context.temp_allocator)
	hits := launcher_hits(app, query)
	if len(hits) == 0 do return
	launcher_take(app, hits[clamp(app.canvas.menu_at, 0, len(hits) - 1)])
}

// --- transcript -------------------------------------------------------------

draw_transcript :: proc(app: ^App, r: Rect) {
	ui := &app.ui
	width := composer_width(r.w)
	x := r.x + (r.w - width) / 2

	// Heights are measured only when something actually changed; on every
	// other frame this is a lookup, which is what keeps a long transcript from
	// making the composer feel heavy.
	if app.heights_w != width || app.heights_at != app.chat_ver {
		measure_start := time.now()
		app.heights_w = width
		app.heights_at = app.chat_ver
		clear(&app.heights)
		total := f32(PAD)
		for &m, i in app.chat.msgs {
			h := layout_message(app, &m, i, x, 0, width, false)
			append(&app.heights, h)
			total += h
		}
		app.total_h = total + 40
		ms := time.duration_milliseconds(time.since(measure_start))
		if app.profile && ms > 1 {
			fmt.eprintfln("measure %d messages: %.1fms", len(app.chat.msgs), ms)
		}
	}
	total := app.total_h
	if app_chat_busy(app) && len(app.open) == 0 do total += 30

	// Pin to the bottom while new output is arriving, unless the reader has
	// scrolled up to look at something.
	if app.stick {
		app.transcript.target = max(total - r.h, 0)
		app.transcript.offset = app.transcript.target
	}
	before := app.transcript.target
	ui_begin_scroll(ui, r, &app.transcript, total)
	if app.transcript.target != before {
		app.stick = app.transcript.target >= max(total - r.h, 0) - 4
	}

	y := r.y + PAD - app.transcript.offset
	for &m, i in app.chat.msgs {
		h := i < len(app.heights) ? app.heights[i] : layout_message(app, &m, i, x, y, width, false)
		// Only what is on screen is drawn; the rest is just an offset.
		if y + h > r.y && y < r.y + r.h {
			_ = layout_message(app, &m, i, x, y, width, true)
		}
		y += h
	}

	if app_chat_busy(app) && len(app.open) == 0 {
		ellipsis := "working..."
		dots := int(ui.time * 3) % 4
		ui_text(ui, &ui.regular, ellipsis[:7 + dots], {x, y}, 17, MUTED)
		ui.time_effects = true
	}
	ui_end_scroll(ui, r, &app.transcript)

}

// One message. Returns its height; only draws when `draw` is set, so the same
// code measures the transcript for the scrollbar.
@(private = "file")
layout_message :: proc(app: ^App, m: ^Msg, at: int, x, y, width: f32, draw: bool) -> f32 {
	ui := &app.ui

	if m.role == .User {
		// A right-hand bubble, sized to its content and capped at 80% width.
		body := &m.blocks[0] if len(m.blocks) > 0 else nil
		inner := width * 0.8 - 24
		h := f32(0)
		for &b in m.blocks {
			h += layout_block(app, &b, x, y, inner, false, 0)
		}
		bw := width * 0.8
		bx := x + width - bw
		if draw {
			// Every bubble looks the same, because every message is in the
			// same state: sent. A dimmed one used to mean waiting behind a
			// running turn, and nothing waits any more.
			ui_rect(ui, {bx, y, bw, h + 20}, USER_BG, 12)
			yy := y + 10
			for &b in m.blocks {
				yy += layout_block(app, &b, bx + 12, yy, inner, true, 0)
			}
		}
		_ = body
		return h + 32
	}

	h := f32(0)
	for &b in m.blocks {
		h += layout_block(app, &b, x, y + h, width, draw, 0)
	}
	return h + 14
}

// One block: prose, thinking, a tool call with its result, an image, an error.
// `depth` is how deep inside a subagent we are.
layout_block :: proc(app: ^App, b: ^Block, x, y, width: f32, draw: bool, depth: int) -> f32 {
	ui := &app.ui

	switch b.kind {
	case .Text:
		md_layout(ui, b, width)
		if !draw do return b.height + 6
		ui_hover_text(ui, {x, y, width, b.height}, strings.to_string(b.text))
		yy := y
		for l in b.lines {
			yy += md_draw_line(ui, l, x, yy, width, TEXT, MUTED)
		}
		return b.height + 6

	case .Error:
		md_layout(ui, b, width - 24)
		h := b.height + 20
		if draw {
			ui_hover_text(ui, {x, y, width, h}, strings.to_string(b.text))
			ui_rect(ui, {x, y, width, h}, color_alpha(RED, 0.12), 8)
			ui_rect(ui, {x, y, 3, h}, RED, 2)
			yy := y + 10
			for l in b.lines {
				yy += md_draw_line(ui, l, x + 14, yy, width - 24, RED, RED)
			}
		}
		return h + 8

	case .Image:
		thumb_w := min(width, f32(280))
		aspect := b.image.height > 0 ? f32(b.image.height) / f32(b.image.width) : 0.6
		h := thumb_w * aspect
		if draw {
			ui_image(ui, {x, y, thumb_w, h}, b.image.tex, 8)
		}
		return h + 10

	case .Thinking:
		// Folded away by default: the reasoning is there if you want it, but
		// it is not what you came to read.
		id := ui_id_ptr(b, 1)
		head := Rect{x, y, width, 29}
		if draw {
			clicked, hovered := ui_invisible_button(ui, id, head)
			if clicked {
				b.expanded = !b.expanded
				app.chat_ver += 1
			}
			chevron(ui, {x + 5, y + 11}, b.expanded, hovered ? MUTED : FAINT)
			teaser_buf: [160]u8
			label := b.expanded ? "Thinking" : thinking_teaser(b, teaser_buf[:])
			ui_text(ui, &ui.regular, label, {x + 22, y + 4}, 15, FAINT)
		}
		if !b.expanded do return 33

		md_layout(ui, b, width - 20)
		if draw {
			ui_rect(ui, {x + 4, y + 24, 2, b.height}, color_alpha(MUTED, 0.3), 1)
			yy := y + 24
			for l in b.lines {
				yy += md_draw_line(ui, l, x + 18, yy, width - 20, MUTED, MUTED)
			}
		}
		return 24 + b.height + 10

	case .Tool:
		return layout_tool(app, b, x, y, width, draw, depth)
	}
	return 0
}

@(private = "file")
thinking_teaser :: proc(b: ^Block, buf: []u8) -> string {
	text := strings.trim_space(block_text(b))
	if text == "" do return "Thinking..."
	return fmt.bprintf(buf, "Thinking: %s", one_line(text, 90))
}

layout_tool :: proc(app: ^App, b: ^Block, x, y, width: f32, draw: bool, depth: int) -> f32 {
	ui := &app.ui
	id := ui_id_ptr(b)
	// The subagent tool is called Agent in current builds and Task in older
	// ones; either way, anything with nested output is drawn as a subagent.
	is_task := b.name == "Task" || b.name == "Agent" || len(b.sub) > 0

	head_h := f32(31)
	h := head_h

	if draw {
		clicked, hovered := ui_invisible_button(ui, id, {x, y, width, head_h})
		if clicked {
			b.expanded = !b.expanded
			app.chat_ver += 1
		}

		dot := b.running ? ACCENT : GREEN
		if b.running {
			// A pulse, so a long tool call does not look stalled.
			pulse := 0.5 + 0.5 * f32(int(ui.time * 4) % 2)
			dot = color_alpha(ACCENT, 0.4 + 0.6 * pulse)
			ui.time_effects = true
		}
		ui_circle(ui, {x + 6, y + 13}, 4, dot)

		name_col := hovered ? TEXT : color_mix(TEXT, MUTED, 0.4)
		nw := ui_text(ui, &ui.mono, b.name, {x + 20, y + 5}, 15.5, name_col)
		arg_x := x + 18 + nw + 10
		if b.arg != "" {
			arg_buf: [512]u8
			arg := font_ellipsize(&ui.mono, b.arg, 14.5, width - (arg_x - x) - 20, arg_buf[:])
			ui_text(ui, &ui.mono, arg, {arg_x, y + 6}, 14.5, FAINT)
		}
	}

	if !b.expanded do return h + 4

	// A subagent shows its own transcript, indented behind an accent rail.
	if is_task && len(b.sub) > 0 {
		sub_x := x + 20
		sub_w := width - 20
		sub_h := f32(4)
		for &s in b.sub {
			sub_h += layout_block(app, &s, sub_x, y + h + sub_h, sub_w, draw, depth + 1)
		}
		if draw {
			ui_rect(ui, {x + 8, y + h, 2, sub_h}, ACCENT_DIM, 1)
		}
		h += sub_h
	}

	// Tool output is shown as a fixed window onto the result: the first lines
	// of the first few kilobytes. Nothing here copies the result — it is
	// walked in place, because some of them are megabytes.
	result := strings.trim_space(strings.to_string(b.result))
	if result != "" {
		shown := result
		if len(shown) > RESULT_BYTES do shown = shown[:RESULT_BYTES]

		count := 0
		counter := each_line(shown)
		for _ in iter_next(&counter) {
			count += 1
			if count >= RESULT_LINES do break
		}

		lh := CODE_LH
		box_h := f32(count) * lh + 12
		if draw {
			ui_rect(ui, {x + 16, y + h, width - 16, box_h}, CODE_BG, 8)
			yy := y + h + 6
			drawn := 0
			it := each_line(shown)
			for l in iter_next(&it) {
				if drawn >= RESULT_LINES do break
				line_buf: [512]u8
				text := font_ellipsize(&ui.mono, l, CODE_PX, width - 48, line_buf[:])
				ui_text(ui, &ui.mono, text, {x + 26, yy}, CODE_PX, color_mix(CODE_TEXT, MUTED, 0.3))
				yy += lh
				drawn += 1
			}
		}
		h += box_h + 6
	}
	return h + 6
}

@(private = "file")
chevron :: proc(ui: ^UI, at: [2]f32, open: bool, col: Color) {
	// A small triangle drawn as a stack of rows: the rounded-rect path
	// antialiases, and a raw triangle would be the only jagged thing left.
	rows :: 5
	s := f32(4)
	for i in 0 ..< rows {
		t := f32(i) / f32(rows - 1)
		if open {
			w := s * 2 * (1 - t)
			ui_rect(ui, {at.x - w / 2, at.y - s / 2 + t * s, w, 1.4}, col, 0.7)
		} else {
			h := s * 2 * (1 - t)
			ui_rect(ui, {at.x - s / 2 + t * s, at.y - h / 2, 1.4, h}, col, 0.7)
		}
	}
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

	// The only control in the window: which model answers. Permissions are
	// whatever the harness is already configured to do.
	chip_y := box.y + box.h - COMPOSER_CHIPS / 2 - 8
	cx := draw_chip(app, ui_id("model-chip"), box.x + box.w - 12, chip_y, model_label[app.model], MUTED)
	if ui.pressed && ui.hot == ui_id("model-chip") do app.overlay = app.overlay == .Model ? .None : .Model
	app.model_chip = Rect{cx, chip_y - 5, box.x + box.w - 12 - cx, 26}
	if app_chat_busy(app) {
		// While a turn is in flight the same corner says so, and stops it.
		stop := Rect{box.x + 14, chip_y - 3, 58, 22}
		clicked, hovered := ui_invisible_button(ui, ui_id("stop"), stop)
		ui_rect(ui, stop, hovered ? PANEL_HI : Color(0x00000000), 6)
		ui_rect(ui, {stop.x + 8, stop.y + 7, 8, 8}, RED, 2)
		ui_text(ui, &ui.regular, "stop", {stop.x + 22, stop.y + 3}, 13, hovered ? TEXT : MUTED)
		if clicked do app_interrupt(app)
	}
	// A rebuilt window waiting for the turn to finish. It goes next to the
	// model chip rather than in the status, which is busy saying what the
	// turn is doing.
	if reload_waiting() {
		label := "update ready"
		w := font_width(&ui.regular, label, 12) + 8
		ui_text(ui, &ui.regular, label, {cx - w - 8, chip_y + 3}, 12, GREEN)
	}

	// The strip that used to carry the status is gone, so it says its piece
	// down here instead, out of the way of the text.
	if app.status != "" && app.status != "ready" {
		buf: [128]u8
		room := box.w - 220 - (app_chat_busy(app) ? 66 : 0)
		msg := font_ellipsize(&ui.regular, app.status, 13, room, buf[:])
		ui_text(ui, &ui.regular, msg, {box.x + 14 + (app_chat_busy(app) ? 66 : 0), chip_y + 3}, 13, FAINT)
	}
}

// The picker itself: the models, stacked above the chip that opened it.
@(private = "file")
draw_model_picker :: proc(app: ^App) {
	ui := &app.ui
	row_h := f32(34)
	w := max(app.model_chip.w, 150)
	h := row_h * f32(len(Model)) + 10
	r := Rect{app.model_chip.x + app.model_chip.w - w, app.model_chip.y - h - 6, w, h}

	// Anywhere else closes it.
	if ui.pressed && !rect_contains(r, ui.mouse) && !rect_contains(app.model_chip, ui.mouse) {
		app.overlay = .None
		return
	}

	ui_rect(ui, {r.x + 2, r.y + 3, r.w, r.h}, Color(0x50000000), 12)
	ui_rect(ui, r, PANEL_HI, 12)

	y := r.y + 5
	for m in Model {
		row := Rect{r.x + 5, y, r.w - 10, row_h}
		clicked, hovered := ui_invisible_button(ui, ui_id("model", int(m)), row)
		if hovered do ui_rect(ui, row, PANEL, 8)
		if m == app.model do ui_circle(ui, {row.x + 14, row.y + row_h / 2}, 3.5, ACCENT)
		ui_text(ui, &ui.regular, model_label[m], {row.x + 26, y + 8}, 15, m == app.model ? TEXT : MUTED)
		if clicked {
			app.model = m
			model_save(m)
			app.overlay = .None
		}
		y += row_h
	}
}

// A small text chip, right-aligned at `right`. Returns its left edge.
@(private = "file")
draw_chip :: proc(app: ^App, id: u64, right, y: f32, label: string, col: Color) -> f32 {
	ui := &app.ui
	w := font_width(&ui.regular, label, 14) + 30
	r := Rect{right - w, y - 5, w, 26}
	_, hovered := ui_invisible_button(ui, id, r)
	ui_rect(ui, r, hovered ? PANEL_HI : color_alpha(PANEL_HI, 0.5), 13)
	ui_circle(ui, {r.x + 12, r.y + 13}, 3.5, ACCENT)
	ui_text(ui, &ui.regular, label, {r.x + 21, y}, 14, hovered ? TEXT : col)
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
