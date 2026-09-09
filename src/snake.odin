package aithing

import "core:math"
import "core:strings"

// A thread is a snake of stones, not a column of prose.
//
// Every block of the chat is one tile, every tile is the same square, and the
// squares run left to right until the row ends, turn, and run back. What a
// turn did is one shape you take in at a glance: a row of blue is a turn that
// read, a run of orange is a turn that changed things.
//
// A tile carries a mark, not a sentence. The first go at this put the tool's
// name and a line of its argument in every box, which meant every box was a
// different width, the row never lined up, and the path read as a paragraph
// with borders — the thing it was meant to replace. Words are what the pointer
// is for: rest on a tile and it opens with the whole of what it is holding,
// the paragraph, the picture at its own size, the command and what came back.
//
// The answer is the last stone on the path and it is gold, so the end of a
// turn is a place on the shape rather than a section underneath it. Its panel
// hangs off it, open, because the answer is the one thing nobody should have
// to go looking for.
//
// The tiles are derived, never stored: `snake_gather` and `snake_place`
// rebuild the list every frame from the chat. There is nothing to invalidate
// when a block arrives mid-stream, and an index into a list that grew cannot
// go stale because no index outlives the frame that made it.

TILE :: f32(46) // every tile, every time
TILE_GAP :: f32(14)
TILE_ROW :: f32(30) // between rows: the pipe's turn lives in here
TILE_ROUND :: f32(4)
WIRE :: f32(8) // the pipe between tiles
SNAKE_PAD :: f32(26)
PEEK_W :: f32(520)
PEEK_MAX :: f32(470) // how tall an opened tile is allowed to get: the rest scrolls
PEEK_LINES :: 400 // of a tool result, the most the panel will ever lay out
PEEK_HEAD :: f32(30)
ANSWER_GAP :: f32(26) // between the gold stone and the answer hanging off it

// The tile colours, in the shader's own 0xAABBGGRR. Each family of tools has
// one, so a turn reads as a pattern before a single word of it is read.
TILE_READ :: Color(0xffe8c49a)
TILE_EDIT :: Color(0xff6ac0ea)
TILE_RUN :: Color(0xff79c08a)
TILE_FIND :: Color(0xffe092a8)
TILE_WEB :: Color(0xffc8bc78)
TILE_ANY :: Color(0xffa8a29c) // whatever the harness grew since this was written
TILE_SAID :: Color(0xff9aa8ac)
GOLD :: Color(0xff5ac8f0)

// The mark on the stone. Drawn from rectangles and circles rather than from a
// glyph: the font is a distance field of one alphabet, and a tool icon set is
// not something to grow a second atlas for.
Icon :: enum {
	You, // what you said: a bubble with its tail on your side
	Said, // what came back: the same bubble, the other way about
	Answer,
	Error,
	Image,
	Read,
	Edit,
	Run,
	Find,
	Web,
	Agent,
	Plan,
	Tool, // anything the harness grew since
}

Tile :: struct {
	ref:    Ref,
	r:      Rect, // content space: add the scroll offset and the view's top
	col:    Color,
	icon:   Icon,
	kind:   Block_Kind,
	name:   string, // the tool, or who said it: the head of the open panel
	user:   bool,
	answer: bool, // the gold one: the last thing said, with nothing after it
	live:   bool, // a tool still running: the tile breathes
	depth:  int, // inside a subagent
}

// --- laying the path out ------------------------------------------------------

// Every block in the chat, in order, as one flat run of tiles — a subagent's
// own blocks included, sitting in the path right after the call that started
// them.
@(private = "file")
snake_gather :: proc(app: ^App) {
	clear(&app.snake)
	summary := snake_summary(app)
	for &m, mi in app.chat.msgs {
		for &b, bi in m.blocks {
			ref := Ref{mi, bi, -1}
			t := tile_of(&b, ref, m.role, 0)
			t.answer = ref == summary
			if t.answer {
				t.col = GOLD
				t.icon = .Answer
				t.name = "answer"
			}
			append(&app.snake, t)
			for &s, si in b.sub {
				append(&app.snake, tile_of(&s, Ref{mi, bi, si}, .Assistant, 1))
			}
		}
	}
	// Between one block and the next — the turn is away, and there is nothing
	// open to be written into — the work is still where the path ends. Read
	// off the turn rather than written on a tile, so it is right on the frame
	// the last block closes and there is nothing to clear afterwards.
	if len(app.snake) > 0 && app_chat_busy(app) {
		working := false
		for t in app.snake do if t.live do working = true
		if !working do app.snake[len(app.snake) - 1].live = true
	}
}

@(private = "file")
tile_of :: proc(b: ^Block, ref: Ref, role: Role, depth: int) -> Tile {
	t := Tile {
		ref   = ref,
		kind  = b.kind,
		depth = depth,
		col   = MUTED,
	}
	switch b.kind {
	case .Text:
		t.user = role == .User
		t.col = t.user ? ACCENT : TILE_SAID
		t.icon = t.user ? .You : .Said
		t.name = t.user ? "you" : "claude"
	case .Error:
		t.col = RED
		t.icon = .Error
		t.name = "error"
	case .Image:
		t.col = TILE_WEB
		t.icon = .Image
		t.name = "image"
	case .Tool:
		t.col, t.icon = tool_style(b.name)
		t.name = b.name
	}
	// Whatever it is, it is working while it is still being written into.
	t.live = b.running
	return t
}

// Which family a tool belongs to. Anything the harness grew since this was
// written still gets a stone — in the house grey, under the generic mark —
// rather than being dropped off the path, which is how a transcript that only
// knew six tool names used to lose whole turns.
tool_style :: proc(name: string) -> (Color, Icon) {
	switch name {
	case "Read", "NotebookRead", "Glob", "LS":
		return TILE_READ, .Read
	case "Edit", "MultiEdit", "Write", "NotebookEdit":
		return TILE_EDIT, .Edit
	case "Bash", "BashOutput", "KillShell":
		return TILE_RUN, .Run
	case "Grep", "Search":
		return TILE_FIND, .Find
	case "Task", "Agent":
		return ACCENT, .Agent
	case "WebFetch", "WebSearch":
		return TILE_WEB, .Web
	case "TodoWrite", "ExitPlanMode", "ReportFindings":
		return TILE_ANY, .Plan
	}
	return TILE_ANY, .Tool
}

// Places the tiles on a fixed grid and snakes it: odd rows are read backwards,
// so the last stone of one row sits directly above the first of the next and
// the pipe between them is a straight drop. Every tile being the same size is
// what makes that true — the first version measured each tile's text and no
// two rows ever lined up.
@(private = "file")
snake_place :: proc(app: ^App, left, width: f32) -> f32 {
	cols := max(1, int((width + TILE_GAP) / (TILE + TILE_GAP)))
	for i in 0 ..< len(app.snake) {
		t := &app.snake[i]
		row := i / cols
		col := i % cols
		if row % 2 == 1 do col = cols - 1 - col
		t.r = {
			left + f32(col) * (TILE + TILE_GAP),
			f32(row) * (TILE + TILE_ROW),
			TILE,
			TILE,
		}
	}
	if len(app.snake) == 0 do return 0
	rows := (len(app.snake) + cols - 1) / cols
	return f32(rows) * (TILE + TILE_ROW) - TILE_ROW
}

// The end of the path: the last thing said, when nothing has happened since.
// A turn that answered and then went back to work has no answer stone yet —
// the text it left mid-way is a tile like any other, because it was not the
// end.
snake_summary :: proc(app: ^App) -> Ref {
	if len(app.chat.msgs) == 0 do return NO_REF
	mi := len(app.chat.msgs) - 1
	m := &app.chat.msgs[mi]
	if m.role != .Assistant || len(m.blocks) == 0 do return NO_REF
	bi := len(m.blocks) - 1
	b := &m.blocks[bi]
	if b.kind != .Text do return NO_REF
	if strings.trim_space(block_text(b)) == "" do return NO_REF
	return Ref{mi, bi, -1}
}

// --- drawing it ---------------------------------------------------------------

draw_transcript :: proc(app: ^App, r: Rect) {
	ui := &app.ui

	path_w := max(r.w - SNAKE_PAD * 2, TILE)
	snake_gather(app)
	path_h := snake_place(app, r.x + SNAKE_PAD, path_w)

	// The answer hangs off the gold stone, inside the scroll, so it is part of
	// the path rather than a panel floating over it. Its height is content the
	// scroll has to make room for. It is as wide as the path, not capped and
	// centred: the pipe drops straight out of the stone, and a stone can end
	// a row anywhere along the path, so the panel has to be under all of it.
	// The text inside still wraps at the readable width.
	ans_w := path_w
	ans_x := r.x + SNAKE_PAD
	sum := snake_summary(app)
	ans_h := f32(0)
	if b := chat_block(&app.chat, sum); b != nil {
		md_layout(ui, b, min(ans_w, CONTENT_MAX) - 28)
		ans_h = b.height + ANSWER_GAP + 26
	}

	total := PAD + path_h + ans_h + 40

	if app.stick {
		app.transcript.target = max(total - r.h, 0)
		app.transcript.offset = app.transcript.target
	}

	// What is open: whatever the pointer is on, else whatever was pressed to
	// stay open, else nothing — the answer is not in this, because it is not a
	// panel that opens, it is a piece of the path that is always there. It is
	// worked out before the path scrolls, because the wheel has to be handed
	// to one of them: turned over an open panel, or over the stone holding it
	// open, it moves the panel's text and not the path underneath. The path
	// is asked with the wheel taken away, and given it back after.
	top := r.y + PAD - app.transcript.offset
	open := snake_open(app, r, top)
	peek: Peek
	if ref_valid(open) do peek = peek_layout(app, open, r, top)
	taken := peek.ok && peek.tall && (ui_hovered(ui, peek.stone) || ui_hovered(ui, peek.box))
	wheel, wheel_px := ui.scroll, ui.scroll_px
	if taken do ui.scroll, ui.scroll_px = 0, 0
	before := app.transcript.target
	ui_begin_scroll(ui, r, &app.transcript, total)
	ui.scroll, ui.scroll_px = wheel, wheel_px
	if app.transcript.target != before {
		app.stick = app.transcript.target >= max(total - r.h, 0) - 4
	}

	top = r.y + PAD - app.transcript.offset
	draw_pipes(app, top, r)

	for tile in app.snake {
		sr := Rect{tile.r.x, tile.r.y + top, tile.r.w, tile.r.h}
		if sr.y > r.y + r.h || sr.y + sr.h < r.y do continue
		draw_tile(app, tile, sr, tile.ref == open && !tile.answer)
	}

	// A turn in flight says so on the path itself — the stone it is working
	// on breathes, and the last one grows as the answer arrives. There used to
	// be a line of "working..." under all of it as well, which is a caption on
	// a thing that is already moving.
	if b := chat_block(&app.chat, sum); b != nil {
		box := Rect{ans_x, top + path_h + ANSWER_GAP, ans_w, b.height + 26}
		for t in app.snake do if t.answer {
			draw_answer_pipe(app, {t.r.x, t.r.y + top, t.r.w, t.r.h}, box)
		}
		draw_answer(app, b, box)
	}
	ui_end_scroll(ui, r, &app.transcript)

	if len(app.snake) == 0 {
		ui_text_centred(ui, &ui.regular, "nothing said yet", r, 17, FAINT)
	}

	// Outside the scroll's clip, so a tile on the last row can still open
	// upward over the rest of the path rather than being cut off by it.
	if peek.ok do draw_peek(app, peek_layout(app, open, r, top))
}

// Which stone is open this frame: the one under the pointer, else the one
// pressed to stay open. One answer, so one panel — there is no list of open
// stones to get two entries in.
@(private = "file")
snake_open :: proc(app: ^App, view: Rect, top: f32) -> Ref {
	ui := &app.ui
	for t in app.snake {
		if t.answer do continue
		sr := rect_intersect({t.r.x, t.r.y + top, t.r.w, t.r.h}, view)
		b := chat_block(&app.chat, t.ref)
		if b == nil do continue
		if ui_hovered(ui, sr) || ui.active == ui_id_ptr(b) do return t.ref
	}
	if chat_block(&app.chat, app.pinned) != nil do return app.pinned
	return NO_REF
}

// The answer, in full, hanging off the gold stone at the end of the path: a
// stub of pipe down into it and a gold edge, so it reads as the last thing on
// the snake and not as a second view of the same thread.
// The last length of pipe: straight out of the bottom of the gold stone and
// into the top of the panel hanging off it. It used to elbow across to the
// panel's left edge, which drew a bright gold rule the width of the window —
// a bigger mark than either of the things it was joining — and then it elbowed
// the other way, over to a centred panel narrower than the path. Neither: the
// panel is the width of the path now, so straight down always lands in it.
@(private = "file")
draw_answer_pipe :: proc(app: ^App, stone, box: Rect) {
	ui := &app.ui
	x := stone.x + stone.w / 2
	r := Rect{x - WIRE / 2, stone.y + stone.h - 2, WIRE, box.y - stone.y - stone.h + 4}
	if r.h <= 0 do return
	// One past the last segment of the path, so the pulse carries on down
	// into the answer in step with the run it came off rather than restarting.
	ui_quad(ui, r, {0, 0}, {1, 1}, color_alpha(GOLD, 0.5), WHITE_TEX, 2, .Wire, wire_param(len(app.snake), false))
}

@(private = "file")
draw_answer :: proc(app: ^App, b: ^Block, box: Rect) {
	ui := &app.ui
	ui_rect(ui, {box.x, box.y, box.w, box.h}, color_alpha(GOLD, 0.06), 8)
	ui_rect(ui, {box.x, box.y + 6, 3, box.h - 12}, color_alpha(GOLD, 0.8), 2)
	ui_hover_text(ui, box, block_text(b))
	y := box.y + 13
	for l in b.lines {
		y += md_draw_line(ui, l, box.x + 20, y, box.w - 28, TEXT, MUTED)
	}
}

// The pipe the stones are strung on: a fat run between neighbours along a row,
// and a straight drop at the turn. It is drawn under everything, in one pass,
// because a pipe is between two tiles and neither of them owns it.
@(private = "file")
draw_pipes :: proc(app: ^App, top: f32, view: Rect) {
	ui := &app.ui
	for i in 0 ..< len(app.snake) - 1 {
		a := app.snake[i]
		b := app.snake[i + 1]
		ay := a.r.y + top + a.r.h / 2
		by := b.r.y + top + b.r.h / 2
		if max(ay, by) < view.y - TILE || min(ay, by) > view.y + view.h + TILE do continue
		col := color_alpha(color_mix(a.col, b.col, 0.5), 0.45)
		if abs(ay - by) < 1 {
			back := b.r.x < a.r.x
			x0 := back ? b.r.x + b.r.w : a.r.x + a.r.w
			x1 := back ? a.r.x : b.r.x
			ui_quad(
				ui,
				{x0 - 1, ay - WIRE / 2, max(x1 - x0, 0) + 2, WIRE},
				{0, 0},
				{1, 1},
				col,
				WHITE_TEX,
				2,
				.Wire,
				wire_param(i, back),
			)
			continue
		}
		// The turn. Both are on the same column — that is what the fixed grid
		// buys — so it is one straight drop through the gap between the rows.
		x := a.r.x + a.r.w / 2
		ui_quad(
			ui,
			{x - WIRE / 2, ay + a.r.h / 2 - 1, WIRE, by - a.r.h / 2 - ay + 2},
			{0, 0},
			{1, 1},
			col,
			WHITE_TEX,
			2,
			.Wire,
			wire_param(i, false),
		)
	}
}

// Where a length of pipe sits in the run, and which way that run is read, in
// the one float a quad gets. The sign is the direction and the magnitude is
// the position, offset by one so that segment nought still has a sign.
//
// They used to be one positive number with 10 added to mean right-to-left,
// and the eleventh segment of any path is 10: from the eleventh stone on,
// every forward run and every drop between rows ran its pulse backwards.
wire_param :: proc(at: int, back: bool) -> f32 {
	p := f32(at) + 1
	return back ? -p : p
}

// One stone. `open` is whether it is the one whose panel is up — under the
// pointer, or pressed to keep it open once the pointer has gone.
@(private = "file")
draw_tile :: proc(app: ^App, t: Tile, r: Rect, open: bool) {
	ui := &app.ui
	b := chat_block(&app.chat, t.ref)
	if b == nil do return
	id := ui_id_ptr(b)

	clicked, hovered := ui_invisible_button(ui, id, r)
	// A press pins it, a second press lets it go, and pinning one lets go of
	// whichever was pinned before: one stone stays open, never two.
	if clicked do app.pinned = app.pinned == t.ref ? NO_REF : t.ref
	pinned := app.pinned == t.ref

	// It arrives by growing into place, and it comes up under the pointer the
	// way a card on the grid does: its width and height swell on two springs
	// wound to different rates, so it wobbles for a moment before it holds, a
	// press squashes it down until it is let go, and it lifts off a shadow.
	// It used to scale on the one spring the panel grows on, which is a stone
	// that inflates evenly and stops — the cards have give in them and the
	// stones sat beside them looking stiff. That spring is still ticked here,
	// by the stone, so the panel's own spring is wound back down while the
	// panel is shut and can pop again next time.
	ui_spring_seed(ui, id + 1, 0)
	born := ui_spring(ui, id + 1, 1, 160, 9)
	up := open ? f32(1) : 0
	pop := ui_spring(ui, id + 2, up, 380, 12)
	_ = ui_spring(ui, id + 3, up, 300, 13)
	sw := ui_spring(ui, id + 5, up, 330, 9)
	sh := ui_spring(ui, id + 6, up, 190, 8)
	press := ui_spring(ui, id + 7, ui.active == id ? f32(1) : 0, 500, 18)
	if ui_entered(ui, id, hovered) do ui_ripple(ui, id + 4, {r.x + r.w / 2, r.y + r.h / 2}, TOUCH, r.w * 1.6)
	ui_draw_ripples(ui, id + 4)
	// A stone that is working breathes, and the sheen the shader crosses a
	// lit tile with crosses this one too — the halo alone was a stone a
	// shade warmer than its neighbours, which is not something you notice
	// unless you already know which one to look at.
	live := t.live ? 0.5 + 0.5 * math.sin(ui.time * 4.5) : 0
	if t.live do ui.time_effects = true
	lift := max(pop, live * 0.6)

	// A subagent's own work is the same stone one step in, so a nested run
	// reads as nested without a second layout to place it.
	nest := t.depth > 0 ? f32(0.76) : 1
	scale_w := (0.86 + 0.14 * born + 0.12 * sw - 0.05 * press + 0.05 * live) * nest
	scale_h := (0.86 + 0.14 * born + 0.18 * sh - 0.08 * press + 0.05 * live) * nest
	cx, cy := r.x + r.w / 2, r.y + r.h / 2 - 2 * pop
	rr := Rect{cx - r.w * scale_w / 2, cy - r.h * scale_h / 2, r.w * scale_w, r.h * scale_h}
	if pop > 0.01 do ui_rect(ui, {rr.x + 1, rr.y + 3 + 3 * pop, rr.w, rr.h}, color_alpha(Color(0xff000000), 0.3 * pop), TILE_ROUND)

	// A halo, only while it is up: the glow is static in the shader, so
	// leaving one behind costs nothing to hold on screen but says the wrong
	// thing about a stone nobody is looking at.
	if lift > 0.01 {
		lit := max(pop, live * 0.7)
		g := f32(24) * lit
		ui_quad(
			ui,
			{rr.x - g, rr.y - g, rr.w + g * 2, rr.h + g * 2},
			{0, 0},
			{1, 1},
			color_alpha(t.col, 0.3 * lit),
			WHITE_TEX,
			NO_ROUND,
			.Glow,
		)
	}

	if t.kind == .Image {
		// The picture is the stone. Hovering it gives the picture, which is
		// the whole reason a screenshot in a thread is worth keeping.
		ui_image(ui, rr, app_preview(app, b.image).tex, TILE_ROUND)
		ui_quad(ui, rr, {0, 0}, {1, 1}, color_alpha(t.col, 0.1 + 0.45 * pop), WHITE_TEX, TILE_ROUND, .Pop, lift)
		ui_hover_text(ui, rr, t.name)
		return
	}

	base := color_mix(PANEL, t.col, 0.16 + 0.2 * pop + 0.12 * live)
	if t.answer do base = color_mix(PANEL, GOLD, 0.3 + 0.25 * pop)
	if t.user do base = color_mix(USER_BG, ACCENT, 0.14 + 0.24 * pop)
	ui_quad(ui, rr, {0, 0}, {1, 1}, color_alpha(base, born), WHITE_TEX, TILE_ROUND, .Pop, lift)
	// The mark takes its size from the stone's width alone, so a stone
	// wobbling taller than it is wide does not stretch the mark with it.
	mark := Rect{cx - rr.w / 2, cy - rr.w / 2, rr.w, rr.w}
	draw_icon(ui, t.icon, mark, color_alpha(t.col, (0.85 + 0.15 * pop) * born), base)
	// Pressed open stays open: a dot in the corner says which one you left
	// that way, because otherwise a panel with no pointer near it looks stuck.
	if pinned do ui_circle(ui, {rr.x + rr.w - 6, rr.y + 6}, 3, t.col)
	// What a copy with nothing selected takes: the block itself, not the mark
	// that stands for it.
	ui_hover_text(ui, rr, t.kind == .Tool ? tool_hover(b) : block_text(b))
}

// --- the marks ----------------------------------------------------------------

// Every icon is drawn inside a 20x20 box in the middle of the stone, out of
// bars, dots and rings. `bg` is the stone under it, which is how a ring is
// made: a disc of the mark's colour with a disc of the stone punched back into
// the middle of it.
draw_icon :: proc(ui: ^UI, icon: Icon, r: Rect, col, bg: Color) {
	s := r.w / TILE // the stone's own scale, so a nested one shrinks its mark
	cx := r.x + r.w / 2
	cy := r.y + r.h / 2
	bar :: proc(ui: ^UI, cx, cy, w, h: f32, col: Color) {
		ui_rect(ui, {cx - w / 2, cy - h / 2, w, h}, col, min(w, h) / 2)
	}
	ring :: proc(ui: ^UI, cx, cy, rad, thick: f32, col, bg: Color) {
		ui_circle(ui, {cx, cy}, rad, col)
		ui_circle(ui, {cx, cy}, rad - thick, bg)
	}

	switch icon {
	case .You, .Said:
		// A speech bubble: a slab with a tail under one corner. Which corner
		// is the whole difference between what you said and what came back —
		// the two used to be the same mark in two colours, which is a
		// difference nobody reads at this size.
		ui_rect(ui, {cx - 9 * s, cy - 8 * s, 18 * s, 12 * s}, col, 3 * s)
		tail := icon == .You ? cx + 2 * s : cx - 8 * s
		ui_rect(ui, {tail, cy + 3 * s, 6 * s, 5 * s}, col, 1.5 * s)
	case .Answer:
		// A four-pointed spark, which is what the end of a turn deserves.
		bar(ui, cx, cy, 3 * s, 22 * s, col)
		bar(ui, cx, cy, 22 * s, 3 * s, col)
		bar(ui, cx, cy, 13 * s, 13 * s, color_alpha(col, 0.5))
	case .Error:
		bar(ui, cx, cy - 3 * s, 3.5 * s, 12 * s, col)
		ui_circle(ui, {cx, cy + 7 * s}, 2.2 * s, col)
	case .Image:
		// Only drawn when the picture itself failed to load: a frame with a
		// hill and a sun in it, which is the shape everything uses for this.
		ring(ui, cx, cy, 11 * s, 2 * s, col, bg)
		ui_circle(ui, {cx - 3 * s, cy - 3 * s}, 2 * s, col)
	case .Read:
		// A page with lines on it.
		ui_rect(ui, {cx - 8 * s, cy - 10 * s, 16 * s, 20 * s}, color_alpha(col, 0.35), 2 * s)
		for i in 0 ..< 3 {
			bar(ui, cx, cy - 5 * s + f32(i) * 5 * s, 10 * s, 2 * s, col)
		}
	case .Edit:
		// A pencil: the shaft on the diagonal and a tip at the end of it.
		ui_line(ui, {cx - 7 * s, cy + 7 * s}, {cx + 6 * s, cy - 6 * s}, 3.5 * s, col)
		ui_circle(ui, {cx + 7 * s, cy - 7 * s}, 2.4 * s, col)
		bar(ui, cx, cy + 9 * s, 18 * s, 2.5 * s, color_alpha(col, 0.55))
	case .Run:
		// A prompt: a chevron and the line it is waiting on.
		ui_line(ui, {cx - 8 * s, cy - 6 * s}, {cx - 1 * s, cy}, 3 * s, col)
		ui_line(ui, {cx - 1 * s, cy}, {cx - 8 * s, cy + 6 * s}, 3 * s, col)
		bar(ui, cx + 5 * s, cy + 6 * s, 8 * s, 3 * s, col)
	case .Find:
		// A lens with a handle.
		ring(ui, cx - 2 * s, cy - 2 * s, 8 * s, 2.6 * s, col, bg)
		ui_line(ui, {cx + 3 * s, cy + 3 * s}, {cx + 9 * s, cy + 9 * s}, 3 * s, col)
	case .Web:
		// A globe: the ring, the equator, and one meridian. The meridian was a
		// nine-pixel bar to begin with, which with the equator over it filled
		// the ring in and made the web stone a plain disc.
		ring(ui, cx, cy, 10 * s, 2.2 * s, col, bg)
		bar(ui, cx, cy, 20 * s, 2 * s, col)
		bar(ui, cx, cy, 2 * s, 20 * s, color_alpha(col, 0.55))
	case .Agent:
		// Three of them, which is what a subagent is: work happening beside
		// the work.
		ui_circle(ui, {cx, cy - 7 * s}, 3.4 * s, col)
		ui_circle(ui, {cx - 7 * s, cy + 5 * s}, 3.4 * s, col)
		ui_circle(ui, {cx + 7 * s, cy + 5 * s}, 3.4 * s, col)
		ui_line(ui, {cx, cy - 7 * s}, {cx - 7 * s, cy + 5 * s}, 1.6 * s, color_alpha(col, 0.6))
		ui_line(ui, {cx, cy - 7 * s}, {cx + 7 * s, cy + 5 * s}, 1.6 * s, color_alpha(col, 0.6))
	case .Plan:
		// A list, ticked.
		for i in 0 ..< 3 {
			y := cy - 7 * s + f32(i) * 7 * s
			ui_circle(ui, {cx - 7 * s, y}, 2.2 * s, col)
			bar(ui, cx + 3 * s, y, 12 * s, 2.2 * s, color_alpha(col, 0.8))
		}
	case .Tool:
		// The generic mark, for a tool this build has never heard of: a nut,
		// which is as much as anything can say about a name alone.
		ring(ui, cx, cy, 10 * s, 3.2 * s, col, bg)
		ui_circle(ui, {cx, cy}, 3 * s, col)
	}
}

// A tool call in words, for a copy taken off the stone: what came back, or
// failing that what was asked.
@(private = "file")
tool_hover :: proc(b: ^Block) -> string {
	if result := strings.trim_space(strings.to_string(b.result)); result != "" do return result
	return b.arg != "" ? b.arg : b.name
}

// --- what the pointer opens ---------------------------------------------------

// Where a stone's panel goes and how much it is holding: the one set of
// numbers the wheel, the frame and the text inside it all read.
Peek :: struct {
	ok:     bool,
	tall:   bool, // more than fits: the wheel has something to do
	tile:   Tile,
	stone:  Rect, // the stone, on screen
	box:    Rect, // the panel, on screen
	body_h: f32, // the content under the head, before any is cut off
	img_h:  f32,
}

@(private = "file")
peek_layout :: proc(app: ^App, ref: Ref, view: Rect, top: f32) -> (p: Peek) {
	ui := &app.ui
	b := chat_block(&app.chat, ref)
	if b == nil do return
	found := false
	for t in app.snake do if t.ref == ref {
		p.tile = t
		found = true
		break
	}
	if !found do return

	w := min(PEEK_W, view.w - PAD * 2)
	inner := w - 28

	// How tall it wants to be, which is the one number the frame and its
	// contents have to agree on. What does not fit under PEEK_MAX is not
	// thrown away any more: it scrolls, so a long result is read by turning
	// the wheel over the stone rather than opening the transcript elsewhere.
	switch b.kind {
	case .Image:
		img := app_preview(app, b.image)
		aspect := img.width > 0 && img.height > 0 ? f32(img.height) / f32(img.width) : 0.62
		p.img_h = min(inner * aspect, PEEK_MAX)
		p.body_h = p.img_h
	case .Text, .Error:
		md_layout(ui, b, inner)
		p.body_h = b.height
	case .Tool:
		if b.arg != "" do p.body_h += 22
		lines := 0
		result := strings.trim_space(strings.to_string(b.result))
		if len(result) > RESULT_BYTES do result = result[:RESULT_BYTES]
		it := each_line(result)
		for _ in iter_next(&it) {
			lines += 1
			if lines >= PEEK_LINES do break
		}
		if lines == 0 do p.body_h += 22
		p.body_h += f32(lines) * CODE_LH + (lines > 0 ? 10 : 0)
	}
	h := PEEK_HEAD + 14 + min(p.body_h, PEEK_MAX)
	p.tall = p.body_h > PEEK_MAX

	p.stone = Rect{p.tile.r.x, p.tile.r.y + top, p.tile.r.w, p.tile.r.h}
	x := clamp(p.stone.x + p.stone.w / 2 - w / 2, view.x + PAD, view.x + view.w - PAD - w)
	// Below the stone if there is room for it there, above it if there is not.
	y := p.stone.y + p.stone.h + 12
	if y + h > view.y + view.h - 8 do y = p.stone.y - h - 12
	y = clamp(y, view.y + 6, max(view.y + view.h - h - 6, view.y + 6))
	p.box = Rect{x, y, w, h}
	p.ok = true
	return
}

// What a stone is holding, at reading size: the paragraph, the picture, the
// tool's arguments and what it gave back. It opens beside the tile and is
// drawn last, over everything, so it is never the thing that gets cut off.
@(private = "file")
draw_peek :: proc(app: ^App, p: Peek) {
	ui := &app.ui
	b := chat_block(&app.chat, p.tile.ref)
	if b == nil do return
	tile := p.tile
	box := p.box
	inner := box.w - 28
	body := strings.trim_space(block_text(b))

	// It grows out of the stone it belongs to, on the spring the stone
	// ticks for it, and lands a shade too big. Only the drawing scales; the
	// panel takes no clicks, so nothing is hit anywhere but where it is.
	// Not while the thread itself is still zooming in — one zoom at a time.
	grow := clamp(ui.anim[ui_id_ptr(b) + 3].pos, 0, 1.3)
	zoomed := ui.zoom == 1
	if zoomed {
		sc := 0.82 + 0.18 * grow
		ax, ay := p.stone.x + p.stone.w / 2, p.stone.y + p.stone.h / 2
		ui_push_zoom(ui, sc, {ax * (1 - sc), ay * (1 - sc)})
	}
	defer if zoomed do ui_pop_zoom(ui)

	// The same ground the composer stands on: cut out of the window, so what
	// is behind it is the desktop rather than the path it is covering.
	ui_punch(ui, box, COMPOSER_BG, 10)
	// A wash of the stone's own colour over it, not a coat of it: at half
	// alpha the panel came out the colour of the tool and the text on it had
	// to fight the tint it was printed on.
	ui_rect(ui, box, color_alpha(tile.col, 0.14), 10)
	// The stone's mark again, small, and the name beside it: the panel says
	// what it belongs to without the path having to carry the words.
	draw_icon(ui, tile.icon, {box.x + 8, box.y + 5, 20, 20}, tile.col, COMPOSER_BG)
	ui_text(ui, &ui.mono, tile.name, {box.x + 34, box.y + 8}, 12.5, tile.col)

	// The text under the head scrolls, and the wheel reaches it from the
	// stone as well as from the panel, because the pointer resting on the
	// stone is what has the panel open. A panel for a different stone starts
	// at the top: the scroll is one number, and it belongs to whichever
	// panel is up, so the change of owner is what resets it.
	body_box := Rect{box.x, box.y + PEEK_HEAD, box.w, box.h - PEEK_HEAD - 8}
	if ui_changed(ui, ui_id("peek-of"), f32(ui_id_ptr(b) & 0xffff)) do app.peek = {}
	ui_begin_scroll(ui, body_box, &app.peek, p.body_h + 8, p.stone)
	iy := body_box.y - app.peek.offset
	ix := box.x + 14
	switch b.kind {
	case .Image:
		ui_image(ui, {ix, iy, inner, p.img_h}, app_preview(app, b.image).tex, 6)
	case .Text, .Error:
		ui_hover_text(ui, box, body)
		col := b.kind == .Error ? RED : TEXT
		for l in b.lines {
			if iy > box.y + box.h do break
			iy += md_draw_line(ui, l, ix, iy, inner, col, MUTED)
		}
	case .Tool:
		if b.arg != "" {
			abuf: [512]u8
			arg := font_ellipsize(&ui.mono, one_line(b.arg, 300), CODE_PX, inner, abuf[:])
			ui_text(ui, &ui.mono, arg, {ix, iy}, CODE_PX, CODE_TEXT)
			iy += 22
		}
		result := strings.trim_space(strings.to_string(b.result))
		if result == "" {
			ui_text(ui, &ui.regular, b.running ? "running..." : "nothing back", {ix, iy}, 13, FAINT)
		} else {
			ui_hover_text(ui, box, result)
			// Walked in place and stopped after a screenful: some results are
			// megabytes, and nothing here copies one to look at the top of it.
			shown := result
			if len(shown) > RESULT_BYTES do shown = shown[:RESULT_BYTES]
			drawn := 0
			it := each_line(shown)
			for l in iter_next(&it) {
				if drawn >= PEEK_LINES || iy > box.y + box.h do break
				if iy + CODE_LH >= body_box.y {
					lbuf: [512]u8
					text := font_ellipsize(&ui.mono, l, CODE_PX, inner, lbuf[:])
					ui_text(ui, &ui.mono, text, {ix, iy}, CODE_PX, color_mix(CODE_TEXT, MUTED, 0.3))
				}
				iy += CODE_LH
				drawn += 1
			}
		}
	}
	ui_end_scroll(ui, body_box, &app.peek)
	// A shade over whichever edge has more past it, so a panel that has been
	// cut off does not read as the end of what it holds.
	if p.tall && app.peek.offset > 1 {
		ui_rect(ui, {box.x, body_box.y, box.w, 18}, color_alpha(COMPOSER_BG, 0.5), 0)
	}
	if p.tall && app.peek.offset < app.peek.content - body_box.h - 1 {
		ui_rect(ui, {box.x, box.y + box.h - 26, box.w, 18}, color_alpha(COMPOSER_BG, 0.5), 0)
	}
}
