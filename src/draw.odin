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
BLINK :: f32(0.55) // caret on/off, in seconds
RESULT_BYTES :: 4000 // how much of a tool result is ever shown
RESULT_LINES :: 40
ROW_H :: f32(42)

draw_app :: proc(app: ^App) {
	ui := &app.ui
	ui.cursor_text = false

	side := Rect{0, 0, SIDEBAR_W, ui.size.y}
	main := Rect{SIDEBAR_W, 0, ui.size.x - SIDEBAR_W, ui.size.y}

	ui_rect(ui, side, SIDEBAR_BG)
	ui_rect(ui, {SIDEBAR_W - 1, 0, 1, ui.size.y}, BORDER)

	draw_sidebar(app, side)

	composer_h := composer_height(app, main.w)
	draw_transcript(app, {main.x, 0, main.w, main.h - composer_h})
	draw_composer(app, {main.x, main.h - composer_h, main.w, composer_h})
	// Drawn last so it sits over the composer: there is no z order here, only
	// the order things are put in the list.
	if app.model_open do draw_model_picker(app)
}

// --- sidebar ----------------------------------------------------------------

draw_sidebar :: proc(app: ^App, r: Rect) {
	ui := &app.ui

	// A new-chat button and a search box; the list is the rest.
	new_r := Rect{r.x + r.w - PAD - 34, r.y + 14, 34, 34}
	clicked, hovered := ui_invisible_button(ui, ui_id("new-chat"), new_r)
	ui_rect(ui, new_r, hovered ? PANEL_HI : PANEL, 8)
	ui_rect(ui, {new_r.x + 16, new_r.y + 9, 2, 16}, hovered ? TEXT : MUTED, 1)
	ui_rect(ui, {new_r.x + 9, new_r.y + 16, 16, 2}, hovered ? TEXT : MUTED, 1)
	if clicked && !runner_busy(&app.runner) do chat_new(app)

	// Search.
	search_r := Rect{r.x + 12, r.y + 14, r.w - 24 - 40, 34}
	focused := app.focus == .Search
	ui_rect(ui, search_r, focused ? PANEL_HI : PANEL, 8)
	if focused do ui_rect(ui, search_r, ACCENT_DIM, 8)
	if clicked_in(app, search_r) do app.focus = .Search
	if ui_hovered(ui, search_r) do ui.cursor_text = true

	query := editor_text(&app.search)
	inner := Rect{search_r.x + 14, search_r.y + 6, search_r.w - 28, 24}
	if query == "" && !focused {
		ui_text(ui, &ui.regular, "Search", {inner.x, inner.y}, 16.5, FAINT)
	} else {
		editor_layout_lines(ui, &app.search, inner.w, &ui.regular, 16.5)
		draw_editor(app, &app.search, inner, &ui.regular, 16.5, focused)
	}

	// The list: what you are working on, then everything filed away behind one
	// row. No date headers — ten rows do not need to be sorted into days.
	list := Rect{r.x, r.y + 60, r.w, r.h - 60}
	content := f32(len(app.visible)) * ROW_H + 8
	if len(app.archived) > 0 {
		content += ROW_H
		if app.show_archive do content += f32(len(app.archived)) * ROW_H
	}

	ui_begin_scroll(ui, list, &app.sidebar, content)
	y := list.y + 4 - app.sidebar.offset
	for idx in app.visible {
		if y + ROW_H > list.y && y < list.y + list.h {
			draw_session_row(app, &app.sessions[idx], idx, {list.x + 8, y, list.w - 16, ROW_H - 4}, false)
		}
		y += ROW_H
	}

	if len(app.archived) > 0 {
		head := Rect{list.x + 8, y, list.w - 16, ROW_H - 4}
		if y + ROW_H > list.y && y < list.y + list.h {
			clicked, hovered := ui_invisible_button(ui, ui_id("archive-head"), head)
			if clicked do app.show_archive = !app.show_archive
			chevron(ui, {head.x + 12, head.y + head.h / 2}, app.show_archive, hovered ? MUTED : FAINT)
			label_buf: [32]u8
			label := fmt.bprintf(label_buf[:], "Archived  %d", len(app.archived))
			ui_text(ui, &ui.bold, label, {head.x + 26, head.y + 8}, 13, hovered ? MUTED : FAINT)
		}
		y += ROW_H

		if app.show_archive {
			for idx in app.archived {
				if y + ROW_H > list.y && y < list.y + list.h {
					draw_session_row(app, &app.sessions[idx], idx, {list.x + 8, y, list.w - 16, ROW_H - 4}, true)
				}
				y += ROW_H
			}
		}
	}
	ui_end_scroll(ui, list, &app.sidebar)

	// A scrollbar, drawn only while there is something to scroll.
	if content > list.h {
		frac := list.h / content
		bar_h := max(list.h * frac, 30)
		t := app.sidebar.offset / max(content - list.h, 1)
		ui_rect(ui, {list.x + list.w - 5, list.y + t * (list.h - bar_h), 3, bar_h}, PANEL_HI, 2)
	}
}

@(private = "file")
draw_session_row :: proc(app: ^App, s: ^Session, index: int, r: Rect, archived: bool) {
	ui := &app.ui
	id := ui_id("session", index)
	active := app.selected == index
	over := ui_hovered(ui, r) || ui.active == id

	// The archive button is claimed before the row is, or the row would take
	// the press first and the button would never see it.
	right := r.x + r.w - 10
	if over {
		btn := Rect{right - 24, r.y + (r.h - 22) / 2, 24, 22}
		btn_id := ui_id("archive", index)
		clicked_btn, btn_hovered := ui_invisible_button(ui, btn_id, btn)
		ui_rect(ui, btn, btn_hovered ? PANEL_HI : Color(0), 6)
		mark := btn_hovered ? TEXT : MUTED
		// A tray: lid on top, and either dropping in or coming back out.
		ui_rect(ui, {btn.x + 6, btn.y + 5, 12, 2}, mark, 1)
		chevron_v(ui, {btn.x + 12, btn.y + 12}, !archived, mark)
		if clicked_btn {
			app_archive(app, s.id, !archived)
			return
		}
		right -= 28
	}

	clicked, hovered := ui_invisible_button(ui, id, r)
	glow := ui_anim(ui, id, hovered || active ? 1 : 0, 26)
	if glow > 0.01 {
		ui_rect(ui, r, color_alpha(active ? PANEL_HI : PANEL, glow), 8)
	}
	if active {
		ui_rect(ui, {r.x, r.y + 5, 3, r.h - 10}, ACCENT, 2)
	}

	text_x := r.x + 12
	stamp_buf: [16]u8
	stamp := relative_time(s.mtime, stamp_buf[:])
	stamp_w := font_width(&ui.regular, stamp, 13)
	if !over {
		ui_text(ui, &ui.regular, stamp, {right - stamp_w, r.y + 12}, 13, FAINT)
	}

	title_buf: [256]u8
	title_w := right - text_x - (over ? 4 : stamp_w + 10)
	title := font_ellipsize(&ui.bold, s.title, 16.5, title_w, title_buf[:])
	col := active ? TEXT : color_mix(TEXT, MUTED, archived ? 0.6 : 0.3)
	ui_text(ui, &ui.bold, title, {text_x, r.y + 10}, 16.5, col)

	if clicked do app_select(app, s.id)
}

// A small up/down arrow, built the same way as the chevron.
@(private = "file")
chevron_v :: proc(ui: ^UI, at: [2]f32, down: bool, col: Color) {
	rows :: 4
	s := f32(3.5)
	for i in 0 ..< rows {
		t := f32(i) / f32(rows - 1)
		w := s * 2 * (down ? 1 - t : t)
		y := at.y - s + (down ? t * s * 2 : t * s * 2)
		ui_rect(ui, {at.x - w / 2, y, w, 1.4}, col, 0.7)
	}
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
		for &m in app.chat.msgs {
			h := layout_message(app, &m, x, 0, width, false)
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
	if runner_busy(&app.runner) && len(app.open) == 0 do total += 30

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
		h := i < len(app.heights) ? app.heights[i] : layout_message(app, &m, x, y, width, false)
		// Only what is on screen is drawn; the rest is just an offset.
		if y + h > r.y && y < r.y + r.h {
			layout_message(app, &m, x, y, width, true)
		}
		y += h
	}

	if runner_busy(&app.runner) && len(app.open) == 0 {
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
layout_message :: proc(app: ^App, m: ^Msg, x, y, width: f32, draw: bool) -> f32 {
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
		yy := y
		for l in b.lines {
			yy += md_draw_line(ui, l, x, yy, width, TEXT, MUTED)
		}
		return b.height + 6

	case .Error:
		md_layout(ui, b, width - 24)
		h := b.height + 20
		if draw {
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

@(private = "file")
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
COMPOSER_MAX :: f32(300)
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
	h := COMPOSER_PAD * 2 + f32(max(len(app.editor.lines), 1)) * (COMPOSER_PX * 1.5)
	if len(app.attach) > 0 do h += COMPOSER_THUMB + 14
	return h + COMPOSER_CHIPS
}

@(private = "file")
composer_width :: proc(width: f32) -> f32 {
	return min(width - PAD * 2, CONTENT_MAX)
}

// What the layout above reserves for the whole strip: the box plus the 6px of
// air above it and the 12px below that draw_composer insets by.
composer_height :: proc(app: ^App, width: f32) -> f32 {
	return clamp(composer_box_height(app, width) + 18, COMPOSER_MIN, COMPOSER_MAX)
}

draw_composer :: proc(app: ^App, r: Rect) {
	ui := &app.ui
	width := composer_width(r.w)
	x := r.x + (r.w - width) / 2

	box := Rect{x, r.y + 6, width, r.h - 18}
	focused := app.focus == .Composer
	ui_rect(ui, box, PANEL, 14)
	ui_rect(ui, box, focused ? color_alpha(ACCENT, 0.35) : color_alpha(BORDER, 0.9), 14)
	ui_rect(ui, rect_inset(box, 1, 1), PANEL, 13)

	if clicked_in(app, box) do app.focus = .Composer
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

	// The text starts under the top padding and the box grows downward with it,
	// so the first line never moves as you type and the chip row stays clear.
	text_w := box.w - COMPOSER_SIDE * 2
	editor_layout_lines(ui, &app.editor, text_w, &ui.regular, COMPOSER_PX)
	text_h := f32(max(len(app.editor.lines), 1)) * (COMPOSER_PX * 1.5)
	text_r := Rect{box.x + COMPOSER_SIDE, inner_y, text_w, text_h}
	if editor_text(&app.editor) == "" && !focused {
		ui_text(ui, &ui.regular, "Reply to Claude...", {text_r.x, text_r.y + 2}, COMPOSER_PX, FAINT)
	}
	draw_editor(app, &app.editor, text_r, &ui.regular, COMPOSER_PX, focused)

	// The only control in the window: which model answers. Permissions are
	// whatever the harness is already configured to do.
	chip_y := box.y + box.h - COMPOSER_CHIPS / 2 - 8
	cx := draw_chip(app, ui_id("model-chip"), box.x + box.w - 12, chip_y, model_label[app.model], MUTED)
	if ui.pressed && ui.hot == ui_id("model-chip") do app.model_open = !app.model_open
	app.model_chip = Rect{cx, chip_y - 5, box.x + box.w - 12 - cx, 26}
	if ui.pressed && ui.hot == ui_id("model-chip") {
		app.model = Model((int(app.model) + 1) % len(Model))
	}
	if runner_busy(&app.runner) {
		// While a turn is in flight the same corner says so, and stops it.
		stop := Rect{box.x + 14, chip_y - 3, 58, 22}
		clicked, hovered := ui_invisible_button(ui, ui_id("stop"), stop)
		ui_rect(ui, stop, hovered ? PANEL_HI : Color(0x00000000), 6)
		ui_rect(ui, {stop.x + 8, stop.y + 7, 8, 8}, RED, 2)
		ui_text(ui, &ui.regular, "stop", {stop.x + 22, stop.y + 3}, 13, hovered ? TEXT : MUTED)
		if clicked do app_interrupt(app)
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
		app.model_open = false
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
			app.model_open = false
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

draw_editor :: proc(app: ^App, e: ^Editor, r: Rect, font: ^Font, px: f32, focused: bool) {
	ui := &app.ui
	text := editor_text(e)
	lh := px * 1.5

	// Click and drag to place the caret and select.
	id := ui_id_ptr(e)
	_, hovered := ui_invisible_button(ui, id, r)
	_ = hovered
	if (ui.pressed && ui_hovered(ui, r)) || (ui.down && ui.active == id) {
		row := clamp(int((ui.mouse.y - r.y) / lh), 0, max(len(e.lines) - 1, 0))
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
	for span, i in e.lines {
		if y > r.y + r.h do break
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
