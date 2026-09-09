package aithing

import "core:math"
import "core:strings"

// A thread is a snake, not a column.
//
// The transcript used to be a scroll of prose with tool calls folded into it,
// which meant a turn that read nine files and wrote two was nine screens of
// paging to find out what it had done. What a turn is is a sequence of moves,
// and a sequence of moves is a path: every block becomes one tile, tiles run
// left to right, the row turns back on itself at the edge, and the whole turn
// is one shape you can take in at a glance. The prose that ends it — the
// answer, the thing you actually asked for — is not a tile. It is printed in
// full underneath, because it is the one part nobody wants summarized.
//
// A tile says what kind of move it was and one line of what it was about.
// Everything else is under the pointer: rest on a tile and it opens, with the
// paragraph, the image at its own size, the tool's output. Nothing is folded
// open and nothing has to be folded shut again, so reading a turn never
// changes its shape — which is what made the old transcript jump under you
// every time a disclosure triangle was pressed.
//
// The tiles are derived, never stored: `snake_gather` and `snake_place` rebuild the list every
// frame from the chat. There is nothing to invalidate when a block arrives
// mid-stream, and an index into a list that grew cannot go stale because no
// index outlives the frame that made it. What each block costs to place is a
// font measurement of one short line — the wrapping that would be expensive
// only happens for the summary and for whatever one tile is open, and both of
// those cache on the block itself.

TILE_H :: f32(56) // a tile, and therefore a row
TILE_GAP :: f32(11) // between tiles along a row
TILE_ROW :: f32(34) // between rows: the wire's turn lives in here
TILE_MIN :: f32(66)
TILE_MAX :: f32(236)
TILE_TOP_PX :: f32(11.5) // the kind, in mono
TILE_LABEL_PX :: f32(13) // the one line about it
WIRE :: f32(2)
SNAKE_PAD :: f32(26)
PEEK_W :: f32(460)
PEEK_MAX :: f32(340) // how tall an opened tile is allowed to get
PEEK_LINES :: 16 // of a tool result

// The tile colours, in the shader's own 0xAABBGGRR. Each family of tools has
// one, so a turn reads as a stripe pattern before a single word of it is read:
// blue looked at something, orange changed something, green ran something.
TILE_READ :: Color(0xffe8c49a)
TILE_EDIT :: Color(0xff6ac0ea)
TILE_RUN :: Color(0xff79c08a)
TILE_FIND :: Color(0xffe092a8)
TILE_WEB :: Color(0xffc8bc78)
TILE_ANY :: Color(0xffa8a29c) // whatever the harness grew since this was written

Tile :: struct {
	ref:    Ref,
	r:      Rect, // content space: add the scroll offset and the view's top
	col:    Color,
	top:    string, // what kind of move it was
	label:  string, // one line of what it was about
	radius: f32,
	kind:   Block_Kind,
	user:   bool,
	live:   bool, // a tool still running: the tile breathes
	depth:  int, // inside a subagent
}

// --- laying the path out ------------------------------------------------------

// Every block in the chat, in order, as one flat run of tiles — a subagent's
// own blocks included, sitting in the path right after the call that started
// them. The final answer is left out: `snake_summary` has it, printed in full
// at the end of the path.
@(private = "file")
snake_gather :: proc(app: ^App) {
	ui := &app.ui
	clear(&app.snake)
	summary := snake_summary(app)
	for &m, mi in app.chat.msgs {
		for &b, bi in m.blocks {
			ref := Ref{mi, bi, -1}
			if ref == summary do continue
			append(&app.snake, tile_of(ui, &b, ref, m.role, 0))
			for &s, si in b.sub {
				append(&app.snake, tile_of(ui, &s, Ref{mi, bi, si}, .Assistant, 1))
			}
		}
	}
}

// What one block looks like on the path. Width is the text it carries, so a
// one-word tool call is a chip and a paragraph is a slab — the shape of the
// row is already telling you how much happened.
@(private = "file")
tile_of :: proc(ui: ^UI, b: ^Block, ref: Ref, role: Role, depth: int) -> Tile {
	t := Tile {
		ref    = ref,
		kind   = b.kind,
		depth  = depth,
		radius = 10,
		col    = MUTED,
	}
	body := strings.trim_space(block_text(b))

	switch b.kind {
	case .Text:
		t.user = role == .User
		t.top = t.user ? "you" : "claude"
		t.col = t.user ? ACCENT : Color(0xff9aa8ac)
		t.label = one_line(body, 120)
		// The one you wrote is a bubble, the way it has always been; the
		// answer is a slab. Two kinds of thing, two silhouettes, no label
		// needed to tell them apart at a distance.
		t.radius = t.user ? TILE_H / 2 : 10

	case .Thinking:
		t.top = "thinking"
		t.col = FAINT
		t.label = one_line(body, 120)
		if t.label == "" do t.label = "..."
		t.radius = TILE_H / 2

	case .Error:
		t.top = "error"
		t.col = RED
		t.label = one_line(body, 120)
		t.radius = 4

	case .Image:
		t.top = "image"
		t.col = TILE_WEB
		t.radius = 8

	case .Tool:
		t.col, t.top = tool_style(b.name)
		t.label = tool_label(b)
		t.live = b.running
		// A tool call is a square-shouldered thing, and a subagent's own work
		// is the same shape one step in.
		t.radius = 6
	}

	w := f32(0)
	switch b.kind {
	case .Image:
		// The thumbnail is the tile. It keeps the picture's own proportions,
		// because a landscape screenshot squeezed into a square is a picture
		// of nothing.
		aspect := b.image.width > 0 && b.image.height > 0 ? f32(b.image.width) / f32(b.image.height) : 1.4
		w = clamp(TILE_H * aspect, 48, 160)
	case .Text, .Thinking, .Error, .Tool:
		top_w := font_width(&ui.mono, t.top, TILE_TOP_PX)
		lab_w := font_width(&ui.regular, t.label, TILE_LABEL_PX)
		w = clamp(max(top_w, lab_w) + 26, TILE_MIN, TILE_MAX)
	}
	t.r = {0, 0, w, TILE_H - f32(depth) * 8}
	return t
}

// Which family a tool belongs to. Anything the harness grew since this was
// written still gets a tile — in the house grey, named after itself — rather
// than being dropped off the path, which is how a transcript that only knew
// six tool names used to lose whole turns.
tool_style :: proc(name: string) -> (Color, string) {
	switch name {
	case "Read", "NotebookRead", "Glob", "LS":
		return TILE_READ, "read"
	case "Edit", "MultiEdit", "Write", "NotebookEdit":
		return TILE_EDIT, "edit"
	case "Bash", "BashOutput", "KillShell":
		return TILE_RUN, "run"
	case "Grep", "Search":
		return TILE_FIND, "find"
	case "Task", "Agent":
		return ACCENT, "agent"
	case "WebFetch", "WebSearch":
		return TILE_WEB, "web"
	case "TodoWrite", "ExitPlanMode", "ReportFindings":
		return TILE_ANY, "plan"
	}
	return TILE_ANY, "tool"
}

// The line under the kind: the end of a path, the head of a command, the
// tool's own name when it gave nothing to say about itself.
@(private = "file")
tool_label :: proc(b: ^Block) -> string {
	arg := one_line(b.arg, 140)
	if arg == "" do return b.name
	switch b.name {
	case "Read", "NotebookRead", "Edit", "MultiEdit", "Write", "NotebookEdit":
		return base_name(arg)
	}
	return arg
}

// Places the gathered tiles: left to right, turn at the edge, left to right
// again one row down. Returns how tall the path is.
//
// Odd rows are laid out forwards and then mirrored, which is the whole of the
// snake: the tile that ends one row is directly above the tile that starts the
// next, so the wire between them is a straight drop and the eye never has to
// jump back across the window.
@(private = "file")
snake_place :: proc(app: ^App, left, width: f32) -> f32 {
	row_start := 0
	x := f32(0)
	row := 0
	mirror :: proc(app: ^App, from, to: int, left, width: f32) {
		for i in from ..< to {
			t := &app.snake[i]
			t.r.x = left + width - (t.r.x - left) - t.r.w
		}
	}
	for i in 0 ..< len(app.snake) {
		t := &app.snake[i]
		if x > 0 && x + t.r.w > width {
			if row % 2 == 1 do mirror(app, row_start, i, left, width)
			row += 1
			row_start = i
			x = 0
		}
		t.r.x = left + x
		t.r.y = f32(row) * (TILE_H + TILE_ROW) + (TILE_H - t.r.h) / 2
		x += t.r.w + TILE_GAP
	}
	if row % 2 == 1 do mirror(app, row_start, len(app.snake), left, width)
	if len(app.snake) == 0 do return 0
	return f32(row + 1) * (TILE_H + TILE_ROW)
}

// The end of the path: the last thing said, when nothing has happened since.
// A turn that answered and then went back to work has no summary yet — the
// text it left mid-way is a tile like any other, because it was not the end.
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

	path_w := max(r.w - SNAKE_PAD * 2, 200)
	snake_gather(app)
	path_h := snake_place(app, r.x + SNAKE_PAD, path_w)

	// The answer, in full, under the path. It is the only thing here that is
	// wrapped, and it wraps at reading width rather than window width because
	// a paragraph eighteen hundred pixels wide is not one anybody reads.
	sum_w := min(path_w, CONTENT_MAX)
	sum_x := r.x + (r.w - sum_w) / 2
	sum := snake_summary(app)
	sum_h := f32(0)
	if b := chat_block(&app.chat, sum); b != nil {
		md_layout(ui, b, sum_w)
		sum_h = b.height + 46
	}

	total := PAD + path_h + sum_h + 40
	if app_chat_busy(app) do total += 30

	if app.stick {
		app.transcript.target = max(total - r.h, 0)
		app.transcript.offset = app.transcript.target
	}
	before := app.transcript.target
	ui_begin_scroll(ui, r, &app.transcript, total)
	if app.transcript.target != before {
		app.stick = app.transcript.target >= max(total - r.h, 0) - 4
	}

	top := r.y + PAD - app.transcript.offset
	draw_wires(app, top, r)

	open := NO_REF
	for tile in app.snake {
		sr := Rect{tile.r.x, tile.r.y + top, tile.r.w, tile.r.h}
		if sr.y > r.y + r.h || sr.y + sr.h < r.y do continue
		if draw_tile(app, tile, sr) do open = tile.ref
	}

	y := top + path_h
	if b := chat_block(&app.chat, sum); b != nil {
		// A rule and the word, so the answer is plainly the end of the path
		// and not one more thing on it.
		ui_rect(ui, {sum_x, y + 12, sum_w, 1}, color_alpha(BORDER, 0.9))
		ui_text(ui, &ui.mono, "answer", {sum_x, y + 20}, TILE_TOP_PX, FAINT)
		y += 46
		ui_hover_text(ui, {sum_x, y, sum_w, b.height}, block_text(b))
		for l in b.lines {
			y += md_draw_line(ui, l, sum_x, y, sum_w, TEXT, MUTED)
		}
	}

	if app_chat_busy(app) {
		ellipsis := "working..."
		dots := int(ui.time * 3) % 4
		ui_text(ui, &ui.regular, ellipsis[:7 + dots], {sum_x, y + 8}, 17, MUTED)
		ui.time_effects = true
	}
	ui_end_scroll(ui, r, &app.transcript)

	if len(app.snake) == 0 && sum_h == 0 && !app_chat_busy(app) {
		ui_text_centred(ui, &ui.regular, "nothing said yet", r, 17, FAINT)
	}

	// Outside the scroll's clip, so a tile on the last row can still open
	// upward over the rest of the path rather than being cut off by it.
	if ref_valid(open) do draw_peek(app, open, r, top)
}

// The thread the tiles hang off: a segment between neighbours along a row, and
// a drop at the turn. It is drawn under everything, in one pass, because a
// wire is between two tiles and neither of them owns it.
@(private = "file")
draw_wires :: proc(app: ^App, top: f32, view: Rect) {
	ui := &app.ui
	for i in 0 ..< len(app.snake) - 1 {
		a := app.snake[i]
		b := app.snake[i + 1]
		ay := a.r.y + top + a.r.h / 2
		by := b.r.y + top + b.r.h / 2
		if max(ay, by) < view.y - TILE_H || min(ay, by) > view.y + view.h + TILE_H do continue
		col := color_alpha(color_mix(a.col, b.col, 0.5), 0.5)
		// Same row: a straight run between the two edges, travelling whichever
		// way the row reads.
		if abs(ay - by) < 1 {
			back := b.r.x < a.r.x
			x0 := back ? b.r.x + b.r.w : a.r.x + a.r.w
			x1 := back ? a.r.x : b.r.x
			ui_quad(
				ui,
				{x0, ay - WIRE / 2, max(x1 - x0, 0), WIRE},
				{0, 0},
				{1, 1},
				col,
				WHITE_TEX,
				1,
				.Wire,
				f32(i) + (back ? 10 : 0),
			)
			continue
		}
		// The turn: down out of the tile that ended the row, across the gap
		// between the rows, and down into the one that starts the next. The
		// two are usually all but stacked — that is what mirroring the odd
		// rows is for — but a row that ended early leaves a real gap, and a
		// single drop at the old tile's centre then hung in the air pointing
		// at nothing, which is the one place a path is allowed to look broken.
		ax := a.r.x + a.r.w / 2
		bx := b.r.x + b.r.w / 2
		y0 := ay + a.r.h / 2
		y1 := by - b.r.h / 2
		mid := (y0 + y1) / 2
		wire :: proc(ui: ^UI, r: Rect, col: Color, phase: f32) {
			if r.w <= 0 || r.h <= 0 do return
			ui_quad(ui, r, {0, 0}, {1, 1}, col, WHITE_TEX, 1, .Wire, phase)
		}
		wire(ui, {ax - WIRE / 2, y0, WIRE, mid - y0}, col, f32(i))
		wire(ui, {min(ax, bx) - WIRE / 2, mid - WIRE / 2, abs(bx - ax) + WIRE, WIRE}, col, f32(i))
		wire(ui, {bx - WIRE / 2, mid, WIRE, y1 - mid}, col, f32(i))
	}
}

// One tile. Returns whether it is the one that is open — under the pointer, or
// pressed to keep it open once the pointer has gone.
@(private = "file")
draw_tile :: proc(app: ^App, t: Tile, r: Rect) -> bool {
	ui := &app.ui
	b := chat_block(&app.chat, t.ref)
	if b == nil do return false
	id := ui_id_ptr(b)

	clicked, hovered := ui_invisible_button(ui, id, r)
	if clicked {
		b.expanded = !b.expanded
	}
	open := hovered || b.expanded

	// Two movements, and they are both the tile's own: it arrives by growing
	// into place, and it lifts under the pointer. Both are eased off one
	// stored number each, so a tile that arrives while another is up does not
	// disturb it.
	born := ui_anim(ui, id + 1, 1, 9)
	pop := ui_anim(ui, id + 2, open ? 1 : 0, 20)
	scale := 0.86 + 0.14 * born + 0.05 * pop
	cx, cy := r.x + r.w / 2, r.y + r.h / 2
	rr := Rect{cx - r.w * scale / 2, cy - r.h * scale / 2, r.w * scale, r.h * scale}

	live := t.live ? 0.5 + 0.5 * math.sin(ui.time * 4.5) : 0
	if t.live do ui.time_effects = true

	// A halo, only while it is up: the glow is static in the shader, so
	// leaving one behind costs nothing to hold on screen but says the wrong
	// thing about a tile nobody is looking at.
	if pop > 0.01 {
		g := f32(26) * pop
		ui_quad(
			ui,
			{rr.x - g, rr.y - g, rr.w + g * 2, rr.h + g * 2},
			{0, 0},
			{1, 1},
			color_alpha(t.col, 0.26 * pop),
			WHITE_TEX,
			NO_ROUND,
			.Glow,
		)
	}

	if t.kind == .Image {
		// The picture is the tile, with its own colour as the rim.
		ui_image(ui, rr, b.image.tex, t.radius)
		ui_quad(ui, rr, {0, 0}, {1, 1}, color_alpha(t.col, 0.12 + 0.5 * pop), WHITE_TEX, t.radius, .Pop, pop)
		return open
	}

	// The body of the tile is the kind's own colour, kept dark enough to read
	// white on: the colour says what happened, the words say what it was.
	base := color_mix(PANEL, t.col, 0.13 + 0.14 * pop + 0.1 * live)
	if t.user do base = color_mix(USER_BG, ACCENT, 0.1 + 0.2 * pop)
	ui_quad(ui, rr, {0, 0}, {1, 1}, color_alpha(base, born), WHITE_TEX, t.radius, .Pop, pop)
	// The kind's colour as a stripe down the leading edge, which is the one
	// mark that survives being read at arm's length.
	ui_rect(ui, {rr.x, rr.y + 8, 3, rr.h - 16}, color_alpha(t.col, (0.75 + 0.25 * live) * born), 2)

	tx := rr.x + 13
	tw := rr.w - 24
	buf: [256]u8
	top_text := font_ellipsize(&ui.mono, t.top, TILE_TOP_PX, tw, buf[:])
	ui_text(ui, &ui.mono, top_text, {tx, rr.y + 9}, TILE_TOP_PX, color_alpha(t.col, born))
	if t.label != "" {
		lbuf: [256]u8
		label := font_ellipsize(&ui.regular, t.label, TILE_LABEL_PX, tw, lbuf[:])
		ui_text(
			ui,
			&ui.regular,
			label,
			{tx, rr.y + rr.h - 22},
			TILE_LABEL_PX,
			color_alpha(open ? TEXT : MUTED, born),
		)
	}
	// Pressed open stays open: a dot in the corner says which ones you left
	// that way, because otherwise a panel with no pointer near it looks stuck.
	if b.expanded do ui_circle(ui, {rr.x + rr.w - 8, rr.y + 8}, 3, t.col)
	// What a copy with nothing selected takes: the block itself, not the one
	// line of it the tile had room for.
	ui_hover_text(ui, rr, t.kind == .Tool ? tool_hover(b) : block_text(b))
	return open
}

// A tool call in words, for a copy taken off the tile: what was asked and what
// came back, which is the pair anybody pasting it into a message wants.
@(private = "file")
tool_hover :: proc(b: ^Block) -> string {
	if result := strings.trim_space(strings.to_string(b.result)); result != "" do return result
	return b.arg != "" ? b.arg : b.name
}

// What a tile is holding, at reading size: the paragraph, the picture, the
// tool's arguments and what it gave back. It opens next to the tile and it is
// drawn last, over everything, so it is never the thing that is cut off.
@(private = "file")
draw_peek :: proc(app: ^App, ref: Ref, view: Rect, top: f32) {
	ui := &app.ui
	b := chat_block(&app.chat, ref)
	if b == nil do return
	tile: Tile
	found := false
	for t in app.snake do if t.ref == ref {
		tile = t
		found = true
		break
	}
	if !found do return

	w := min(PEEK_W, view.w - PAD * 2)
	inner := w - 28
	body := strings.trim_space(block_text(b))

	// How tall it wants to be, which is the one number the frame and its
	// contents have to agree on.
	head_h := f32(30)
	h := head_h + 14
	img_h := f32(0)
	switch b.kind {
	case .Image:
		aspect := b.image.width > 0 && b.image.height > 0 ? f32(b.image.height) / f32(b.image.width) : 0.62
		img_h = min(inner * aspect, PEEK_MAX)
		h += img_h
	case .Text, .Thinking, .Error:
		md_layout(ui, b, inner)
		h += min(b.height, PEEK_MAX)
	case .Tool:
		if b.arg != "" do h += 22
		lines := 0
		it := each_line(strings.trim_space(strings.to_string(b.result)))
		for _ in iter_next(&it) {
			lines += 1
			if lines >= PEEK_LINES do break
		}
		if lines == 0 do h += b.running ? 22 : 0
		h += f32(lines) * CODE_LH + (lines > 0 ? 10 : 0)
	}
	h = min(h, PEEK_MAX + head_h + 24)

	tr := Rect{tile.r.x, tile.r.y + top, tile.r.w, tile.r.h}
	x := clamp(tr.x + tr.w / 2 - w / 2, view.x + PAD, view.x + view.w - PAD - w)
	// Below the tile if there is room for it there, above it if there is not.
	y := tr.y + tr.h + 12
	if y + h > view.y + view.h - 8 do y = tr.y - h - 12
	y = clamp(y, view.y + 6, max(view.y + view.h - h - 6, view.y + 6))
	box := Rect{x, y, w, h}

	// The same ground the composer stands on: cut out of the window, so what
	// is behind it is the desktop rather than the path it is covering.
	ui_punch(ui, box, COMPOSER_BG, 12)
	ui_rect(ui, box, color_alpha(tile.col, 0.55), 12)
	ui_text(ui, &ui.mono, tile.top, {box.x + 14, box.y + 9}, TILE_TOP_PX, tile.col)
	if b.kind == .Tool && b.name != "" {
		nw := font_width(&ui.mono, b.name, TILE_TOP_PX)
		ui_text(ui, &ui.mono, b.name, {box.x + box.w - 14 - nw, box.y + 9}, TILE_TOP_PX, FAINT)
	}

	ui_push_clip(ui, box)
	iy := box.y + head_h
	ix := box.x + 14
	switch b.kind {
	case .Image:
		// The actual picture, not the chip of it on the path — which is the
		// whole reason a screenshot in a thread is worth keeping.
		ui_image(ui, {ix, iy, inner, img_h}, b.image.tex, 8)
	case .Text, .Thinking, .Error:
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
				if drawn >= PEEK_LINES do break
				lbuf: [512]u8
				text := font_ellipsize(&ui.mono, l, CODE_PX, inner, lbuf[:])
				ui_text(ui, &ui.mono, text, {ix, iy}, CODE_PX, color_mix(CODE_TEXT, MUTED, 0.3))
				iy += CODE_LH
				drawn += 1
			}
		}
	}
	ui_pop_clip(ui)
}
