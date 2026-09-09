package aithing

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import stbi "vendor:stb/image"

// A picture of the window without a window. `aithing --shot out.png --scene
// grid` builds an App by hand, draws it into an image of our own (see
// gpu_init_offscreen) and writes the pixels out.
//
// Two things make this worth having over pointing a camera at a running
// window. The state is built, not arrived at: a scene says what is on the
// grid, which card is running and what the failed one said, so the same PNG
// comes out on a machine that has never run a turn. And it needs no
// compositor, so it runs over ssh, in a container, and from an agent editing
// this source — which is the only way anything here gets looked at without a
// person driving it.
//
// It is not a golden-image test on its own. It is the thing a golden-image
// test would be made of, and the thing to look at when a layout change needs
// looking at.

Scene :: enum {
	Grid, // every project's cards, in the states a card can be in
	Project, // narrowed to one, so the box under the grid is there
	Paste, // a picture pasted into that box, with the pointer on its thumbnail
	Thread, // a card opened: transcript and composer over the grid
	Opening, // that same card halfway there: the panel still growing out of it
	Peek, // the same thread with the pointer resting on a tile of its path
	Command, // the pointer on a shell stone: the command, and what it printed
	Plan, // the pointer on a plan stone: its items, with their boxes
	Picker, // the model picker, open off the composer's chip
	Launcher, // the menu, with a query typed into it
	Usage, // the pointer on the dial, so what each ring is is on screen
	Dismiss, // a card's x just pressed: the card imploding and the wave leaving it
	Added, // a line just sent from the box: the card rising out of it, the row making room
}

@(private = "file")
scene_names := [Scene]string {
	.Grid     = "grid",
	.Project  = "project",
	.Paste    = "paste",
	.Thread   = "thread",
	.Opening  = "opening",
	.Peek     = "peek",
	.Command  = "command",
	.Plan     = "plan",
	.Picker   = "picker",
	.Launcher = "launcher",
	.Usage    = "usage",
	.Dismiss  = "dismiss",
	.Added    = "added",
}

scene_parse :: proc(name: string) -> (Scene, bool) {
	for n, s in scene_names do if n == name do return s, true
	return .Grid, false
}

scene_list :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for n, s in scene_names {
		if s != Scene(0) do strings.write_string(&b, ", ")
		strings.write_string(&b, n)
	}
	return strings.to_string(b)
}

// The window's own background is translucent — the compositor blends it with
// whatever is behind it — and a screenshot has nothing behind it. The same
// colour, opaque, so the file is the picture rather than a picture of the
// alpha channel.
SHOT_BG :: Color(0xff242626)

// Frames spent letting the animations settle before the picture is taken.
// Everything here eases toward a target and snaps once it is within a
// thousandth, so a handful of frames at a fixed step is enough for all of them
// — and a fixed step is the point: the same scene draws the same pixels
// whether the machine is fast or busy.
SHOT_DT :: f32(1.0 / 60)
SHOT_SETTLE :: 240
// Where the opening scene is caught. A quarter of the way through, counting
// the extra frame every shot draws at the end — early enough that the panel
// is still visibly the card it grew out of, which is the part of the movement
// worth being able to look at.
SHOT_OPENING :: 2
// Frames after the x is let go before the dismissal is caught: the ghost is
// mid-implosion and the wave is about a third of the way across the grid.
SHOT_DISMISS :: 8
// Frames after the line is sent: partway up, the section still shifting.
SHOT_ADDED :: 6

shot_run :: proc(path: string, scene: Scene, width, height: int) -> bool {
	// Nothing here is allowed to read or write the real thing: a screenshot
	// that picked up the cards on this machine would be a different picture on
	// every machine, and one that saved would overwrite them.
	SHOT_CONFIG :: "/tmp/aithing-shot"
	os.make_directory_all(SHOT_CONFIG)
	_ = os.set_env("AITHING_CONFIG", SHOT_CONFIG)

	app := new(App)
	if !gpu_init_offscreen(&app.gpu, width, height) do return false
	defer gpu_destroy(&app.gpu)

	regular, bold, mono, fonts_ok := font_atlas_load(&app.gpu)
	white := [4]byte{255, 255, 255, 255}
	white_slot := texture_upload(&app.gpu, white[:], 1, 1, 4)
	if !fonts_ok || white_slot != WHITE_TEX {
		fmt.eprintln("could not set up fonts")
		return false
	}
	app.ui.regular, app.ui.bold, app.ui.mono = regular, bold, mono

	shot_build(app, scene)

	// Off screen and out of reach: a pointer at the origin would hover
	// whatever the layout happens to put in the corner, and a lit card is not
	// what the scene asked for.
	app.win.input.mouse = {-1e6, -1e6}

	// Except where the picture is of what the pointer does: a stone on the
	// path carries a mark and nothing else, and the panel that opens under it
	// is where every word of the transcript now lives. Which stone, worked out
	// from the path's own spacing rather than written down as a pixel — the
	// spot used to be {349, 39}, which said nothing about which of the
	// seventeen stones it was and would have to be found again by hand every
	// time one was added to the scene.
	if at := scene_stone(scene); at >= 0 {
		app.win.input.mouse = {SNAKE_PAD + f32(at) * (TILE + TILE_GAP) + TILE / 2, PAD + TILE / 2}
		app.win.input.has_mouse = true
	}

	// The picture under the pointer is the whole of what this scene is of: in
	// the words it is the size of the letters around it, and the point of the
	// hover is everything that size lost. Where it lands is wherever the
	// sentence puts it, which is not known until the box has been drawn once —
	// so one frame is drawn with the pointer away, the cell it recorded is
	// read back, and the settle below starts with the pointer on it.
	if scene == .Paste {
		ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT)
		draw_app(app)
		ui_end(&app.ui)
		if cell, ok := capture_thumb(app, 0); ok {
			app.win.input.mouse = {cell.x + cell.w / 2, cell.y + cell.h / 2}
			app.win.input.has_mouse = true
		}
	}

	// The dial says everything it says in three arcs; what each arc is only
	// comes up under the pointer, so the only way to look at that is to put
	// the pointer on it. The middle of the rings, worked out rather than
	// written down, so the spot follows the dial if it ever moves.
	if scene == .Usage {
		// Asked with no box beside it, which at this size is the same answer:
		// the dial only moves once the box along the bottom is wide enough to
		// crowd it, and a shot is 1180 across.
		dial := usage_rect({0, 0, f32(width), f32(height)}, {})
		app.win.input.mouse = {dial.x + dial.w / 2, dial.y + dial.h / 2}
		app.win.input.has_mouse = true
	}

	// The opening scene is the one picture that is not of a settled window:
	// it is the card on its way to being a thread, stopped partway, which is
	// the only way to look at that movement without a camera pointed at a
	// screen.
	frames := scene == .Opening ? SHOT_OPENING : SHOT_SETTLE
	for i in 0 ..< frames {
		ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT)
		draw_app(app)
		ui_end(&app.ui)
		if scene != .Opening && !app.ui.animating do break
	}
	// The dismissal is the one thing that cannot be built into the state,
	// because it is a moment: the grid is settled, then the x on the running
	// card is pressed as a pointer would press it, and the picture is taken a
	// few frames on with the card still going and its wave still crossing
	// the others.
	if scene == .Dismiss {
		card, _ := canvas_node_rect(app, "s-2")
		app.win.input.mouse = {card.x + card.w - 14 - 14, card.y + 14 - 4 + 14}
		app.win.input.has_mouse = true
		ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT) // arrive
		draw_app(app)
		ui_end(&app.ui)
		app.win.input.down[0], app.win.input.pressed[0] = true, true
		ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT) // press
		draw_app(app)
		ui_end(&app.ui)
		app.win.input.down[0], app.win.input.pressed[0], app.win.input.released[0] = false, false, true
		ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT) // let go
		draw_app(app)
		ui_end(&app.ui)
		app.win.input.released[0] = false
		app.win.input.mouse = {-1e6, -1e6}
		_ = app_apply_clicks(app)
		for _ in 0 ..< SHOT_DISMISS {
			ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT)
			draw_app(app)
			ui_end(&app.ui)
		}
	}
	// Adding is a moment the same way: the grid is settled, then a line is
	// sent from the box, and the picture is of the card on its way up out of
	// it with the row still sliding along to make room.
	if scene == .Added {
		// By hand rather than through app_capture, which would start a turn
		// — a real process — behind the card.
		id := todos_add(&app.todos, "pin the cost of a rebuild", "", PROJ)
		canvas_born(app, id)
		canvas_set_sel(app, id)
		for _ in 0 ..< SHOT_ADDED {
			ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT)
			draw_app(app)
			ui_end(&app.ui)
		}
	}
	// The shader clock drives the running card's pulse, so the frame that is
	// kept starts it from a known place rather than from however many frames
	// the settling happened to take. Not for the dismissal, which is read off
	// that same clock and would be over before it began.
	if scene != .Dismiss do app.ui.time = 0
	ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT)
	draw_app(app)
	ui_end(&app.ui)
	gpu_draw(&app.gpu, &app.ui, SHOT_BG)

	pixels := gpu_capture(&app.gpu)
	defer delete(pixels)
	shot_flatten(pixels)

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if stbi.write_png(cpath, i32(width), i32(height), 4, raw_data(pixels), i32(width * 4)) == 0 {
		fmt.eprintfln("could not write %s", path)
		return false
	}
	fmt.printfln("%s: %s %dx%d", scene_names[scene], path, width, height)
	// No app_destroy: it saves the cards, the archive and where the window
	// was, and this app is a fixture rather than anything anyone worked in.
	return true
}

// The window is see-through in places on purpose — the composer and the
// launcher punch their alpha out so the compositor can blur the desktop
// through them (see ui_punch) — and a file has no desktop behind it. This puts
// the window's own colour there instead, which is what a compositor would do
// minus the blur. Without it those panels come out as holes, and a viewer that
// paints transparency white turns the composer into a white slab.
//
// The blending writes premultiplied colour, so the background goes under it
// rather than being mixed with it.
@(private = "file")
shot_flatten :: proc(pixels: []byte) {
	bg := [3]u32 {
		u32(SHOT_BG) & 0xff,
		(u32(SHOT_BG) >> 8) & 0xff,
		(u32(SHOT_BG) >> 16) & 0xff,
	}
	for i := 0; i < len(pixels); i += 4 {
		a := u32(pixels[i + 3])
		for c in 0 ..< 3 {
			pixels[i + c] = u8(min(u32(pixels[i + c]) + bg[c] * (255 - a) / 255, 255))
		}
		pixels[i + 3] = 255
	}
}

// --- the scenes -------------------------------------------------------------

@(private = "file")
PROJ :: "/home/mike/Source/aithing"
@(private = "file")
OTHER :: "/home/mike/Source/toomanymachines"

@(private = "file")
shot_build :: proc(app: ^App, scene: Scene) {
	app.cwd = PROJ
	app.status = "ready"
	app.model = .Sonnet
	app.effort = EFFORT_DEFAULT
	app.stick = true
	app.scanned = true // otherwise an empty grid says it is still reading
	app.scan_at = time.now()

	app.sessions = shot_sessions()

	// The cards, oldest first — todos_add hands out the number that orders
	// them and the grid draws a project newest first, so the last one added is
	// the one at the top. Fixed ages, so the stamps in the corners read the
	// same on any day.
	shot_card(app, OTHER, "snapshot every turn by build id", .Done, "s-6", 30 * time.Hour)
	shot_card(app, OTHER, "the timeline scrubs past the last build", .Open, "", 26 * time.Hour)
	asked := shot_card(app, PROJ, "the composer keeps what is half-typed", .Asked, "s-5", 5 * time.Hour)
	shot_card(app, PROJ, "one variable per question, across the canvas", .Merged, "s-4", 3 * time.Hour)
	failed := shot_card(app, PROJ, "backspace types a 1 on the second keymap", .Failed, "s-3", 40 * time.Minute)
	running := shot_card(app, PROJ, "measure the grid at a thousand cards", .Running, "s-2", 2 * time.Minute)
	shot_card(app, PROJ, "the composer eats the first character after a paste", .Open, "s-1", 4 * time.Minute)

	// Why the two that need a reason have one. A headless turn has nowhere
	// else to put it, and a card that says `failed` and nothing more is the
	// thing this was added for.
	app.notes[failed] = "keymap-wtype.txt has no level 3, so the lookup fell through"
	app.notes[asked] = "worktree or in place? both were asked for above"

	// The running card, read off a turn rather than written on the card: see
	// todo_display_state. No process behind it — nothing here starts one.
	at := turn_slot(app)
	t := app.turns[at]
	t^ = Turn {
		live    = true,
		session = "s-2",
		cwd     = PROJ,
		todo    = running,
		tool    = "Read",
		arg     = "src/canvas.odin",
	}
	t.runner.running = true

	// An allowance part spent, so the corner has something to say. Fixed
	// against a reset an hour and a day out, so it reads the same on any
	// afternoon.
	now := time.time_to_unix(time.now())
	app.usage.limits = Limits {
		session = {util = 0.41, resets = now + 2 * 60 * 60 + 40 * 60},
		week    = {util = 0.68, resets = now + 3 * 24 * 60 * 60},
		fable   = {util = 0.83, resets = now + 3 * 24 * 60 * 60},
	}

	switch scene {
	case .Grid:
	case .Project:
		app.canvas.project = PROJ
		editor_set_text(&app.capture, "split the grid measurement out of the frame\n*\ncheck it at 1200 sessions")
	case .Paste:
		// A paste puts a path in the box and nothing else; the picture drawn
		// in the sentence is that path read back. So the scene writes a
		// picture to disk and types its path, which is exactly what pasting
		// does.
		app.canvas.project = PROJ
		png := shot_png()
		editor_set_text(&app.capture, fmt.tprintf("the ring is too pale here %s", png))
	case .Thread, .Opening, .Peek, .Command, .Plan, .Picker:
		app.canvas.project = PROJ
		app.page = .Thread
		shot_thread(app)
		if scene == .Picker do app.overlay = .Model
	case .Usage, .Dismiss, .Added:
		app.canvas.project = PROJ
	case .Launcher:
		app.overlay = .Launcher
		editor_set_text(&app.search, "grid")
	}
}

// Which stone of the path a scene rests the pointer on, counting from the
// start of the thread, and -1 for a scene that is not about a stone. They are
// all on the first row: nineteen fit across a shot, and shot_thread is
// seventeen stones long.
@(private = "file")
scene_stone :: proc(scene: Scene) -> int {
	#partial switch scene {
	case .Peek:
		return 5 // the edit — a diff is what the panel is most for
	case .Command:
		return 4 // a shell command, and what it printed
	case .Plan:
		return 8 // a plan, with its boxes
	}
	return -1
}

// A picture to have pasted: a corner of a window with a ring in it, drawn
// rather than shipped so the shot needs nothing beside the binary. Wide and
// short, the shape a screenshot is, which is the shape the square cell in the
// words has to crop and the hover has to give back.
@(private = "file")
shot_png :: proc() -> string {
	w, h :: 640, 360
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := (y * w + x) * 4
			dx := f32(x) - f32(w) / 2
			dy := f32(y) - f32(h) / 2
			d := math.sqrt(dx * dx + dy * dy)
			ring := abs(d - 120) < 14 ? f32(1) : 0
			pixels[i + 0] = u8(40 + 180 * ring)
			pixels[i + 1] = u8(44 + 120 * ring + f32(x) / f32(w) * 40)
			pixels[i + 2] = u8(48 + 60 * ring + f32(y) / f32(h) * 60)
			pixels[i + 3] = 255
		}
	}
	path := "/tmp/aithing-shot/paste-1.png"
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	stbi.write_png(cpath, w, h, 4, raw_data(pixels), w * 4)
	return path
}

@(private = "file")
shot_sessions :: proc() -> []Session {
	rows := [?]struct {
		id, title, cwd: string,
		minutes:        int,
		prompts:        int,
	} {
		{"s-2", "measure the grid at a thousand cards", PROJ, 2, 6},
		{"s-1", "the composer eats the first character", PROJ, 4, 3},
		{"s-3", "backspace types a 1", PROJ, 40, 9},
		{"s-4", "one variable per question", PROJ, 180, 22},
		{"s-5", "the composer draft", PROJ, 300, 11},
		{"s-6", "snapshot every turn by build id", OTHER, 1800, 14},
	}
	out := make([]Session, len(rows))
	for r, i in rows {
		out[i] = Session {
			id      = r.id,
			title   = r.title,
			cwd     = r.cwd,
			project = r.cwd,
			path    = fmt.aprintf("%s/%s.jsonl", r.cwd, r.id),
			mtime   = time.time_add(time.now(), -time.Duration(r.minutes) * time.Minute),
			size    = i64(4096 * (i + 1)),
			prompts = r.prompts,
		}
	}
	return out
}

// A card, through the one door cards come through: todos_add hands out the id
// and keeps the per-thread count in step, which is the whole reason that cache
// is allowed to exist. Only the age is set afterwards, because a scene is a
// picture of work that has been sitting there rather than of seven cards typed
// this instant.
@(private = "file")
shot_card :: proc(
	app: ^App,
	cwd, text: string,
	state: Todo_State,
	session: string,
	ago: time.Duration,
) -> string {
	// Running is never written down — the turn is what says it — so a scene
	// that asks for a running card gets an open one here and the turn beside
	// it does the rest.
	stored := state == .Running ? Todo_State.Open : state
	id := todos_add(&app.todos, text, session, cwd, stored)
	if at := todos_find(&app.todos, id); at >= 0 {
		app.todos.list[at].at = time.time_add(time.now(), -ago)
	}
	return id
}

@(private = "file")
shot_thread :: proc(app: ^App) {
	app.chat.session_id = "s-2"
	app.chat.cwd = PROJ
	app.chat.title = "measure the grid at a thousand cards"

	shot_text(app, .User, .Text, "the grid is rebuilt every frame — how much does that actually cost at a thousand sessions?")
	shot_text(
		app,
		.Assistant,
		.Text,
		"Measuring it rather than guessing. `canvas_layout` walks the cards and `app_filter` rebuilds the view; both are one pass, so the answer should scale with the number of cards and not with the sessions behind them.",
	)
	// A turn's worth of moves, which is what the path is for: enough of them,
	// and enough kinds of them, that the snake turns a row and every tile
	// style is in the picture — including a tool nothing here has heard of,
	// which gets the generic tile rather than being dropped off the path.
	shot_tool(app, "Read", `{"file_path": "src/canvas.odin", "offset": 120, "limit": 40}`, "   126→canvas_layout :: proc(app: ^App) -> f32 {\n   127→\tc := &app.canvas\n   128→\tapp_filter(app)\n   129→\tfor id, i in app.todo_view {\n   130→\t\tcanvas_place(app, id, i)\n   131→\t}")
	shot_tool(app, "Grep", `{"pattern": "canvas_layout", "path": "src", "output_mode": "files_with_matches"}`, "src/canvas.odin:126\nsrc/draw.odin:41\nsrc/app.odin:812")
	shot_tool(app, "Bash", `{"command": "grep -n \"PEEK_\\|Row_Kind\" src/peek.odin", "description": "Find what the panel's own numbers are called"}`, "30:PEEK_W :: f32(560) // the column a panel opens at, and no wider\n43:PEEK_SIGN :: f32(16) // the + / - column of a diff\n57:Row_Kind :: enum { Head, Note, Mono, Cmd, Add, Del, Same, Skip, Path, Check, Gap }\n92:peek_rows :: proc(app: ^App, b: ^Block, inner: f32) -> []Row { rows := &app.rows; clear(rows); if b.kind != .Tool do return rows[:] }\n196:\tnumbered := icon != .Find && output_numbered(result) // one answer for the whole of it")
	shot_tool(app, "Edit", `{"file_path": "src/canvas.odin", "old_string": "\tcols := max(1, int(width / TILE))\n\tfor i in 0 ..< len(app.snake) {\n\t\tt := &app.snake[i]\n\t\tt.r = {left + f32(i % cols) * TILE, f32(i / cols) * TILE, TILE, TILE}\n\t}\n", "new_string": "\tcols := max(1, int((width + TILE_GAP) / (TILE + TILE_GAP)))\n\tfor i in 0 ..< len(app.snake) {\n\t\tt := &app.snake[i]\n\t\trow := i / cols\n\t\tcol := i % cols\n\t\tif row % 2 == 1 do col = cols - 1 - col\n\t\tt.r = {left + f32(col) * (TILE + TILE_GAP), f32(row) * (TILE + TILE_ROW), TILE, TILE}\n\t}\n"}`, "The file src/canvas.odin has been updated.")
	shot_tool(app, "WebFetch", `{"url": "https://odin-lang.org/docs/overview", "prompt": "how dynamic arrays are grown"}`, "A dynamic array grows by doubling; append is amortised constant time and the backing memory belongs to the array's allocator.")
	shot_tool(app, "Task", `{"description": "measure the sweep", "prompt": "Measure the session sweep at 1200 sessions and say where the time goes. Do not change anything; report the numbers."}`, "The worktree cache was asked for once per session, which is a mkdir per session per call, and the search lowercased four fields of every session into fresh copies on top.")
	shot_tool(app, "TodoWrite", `{"todos": [{"content": "measure the rebuild at 1200 sessions", "status": "completed"}, {"content": "pin the cost in a test", "status": "in_progress"}, {"content": "take the mkdir out of the sweep", "status": "pending"}, {"content": "stop lowercasing four fields a session", "status": "pending"}]}`, "Todos have been modified successfully.")
	shot_tool(app, "Write", `{"file_path": "src/grid_cost_test.odin", "content": "package aithing\n\nimport \"core:testing\"\n\n// The number in CLAUDE.md is a test, not a claim.\n@(test)\nthe_grid_is_cheap_to_rebuild :: proc(t: ^testing.T) {\n\tlist := shot_sessions(1200)\n\tdefer delete(list)\n}\n"}`, "Wrote 118 lines to src/grid_cost_test.odin")
	shot_tool(app, "Read", `{"file_path": "src/app.odin", "offset": 140, "limit": 12}`, "   148→\theights: [dynamic]f32,\n   149→\tchat_ver: int,")
	shot_tool(app, "Bash", `{"command": "./build.sh", "description": "Rebuild the binary the user launches"}`, "built ./aithing")
	shot_tool(app, "Glob", `{"pattern": "src/*.odin"}`, "src/app.odin\nsrc/canvas.odin\nsrc/peek.odin\nsrc/snake.odin\n36 files")
	shot_tool(app, "Sparkle", `{"wish": "a tool this build has never heard of", "count": 3}`, "and it still gets a stone, and a panel that says what it was called with")
	shot_tool(app, "Edit", `{"file_path": "src/sessions.odin", "old_string": "\tfor s in sessions {\n\t\tif worktree_of(s.cwd) == cwd do return s\n\t}\n", "new_string": "\tfor s in sessions {\n\t\tif s.cwd == cwd do return s\n\t}\n"}`, "The file src/sessions.odin has been updated.")
	shot_tool(app, "Bash", `{"command": "odin test src", "description": "The suite, once more"}`, "All tests were successful.")
	shot_err(app, "turn stopped: the harness closed the stream mid-answer")
	shot_text(
		app,
		.Assistant,
		.Text,
		"About half a millisecond at 1200 sessions and 400 cards, and frames are only drawn on input or animation — so a cache here would be a second copy of the grid bought with nothing.\n\n| what | before | after |\n|:--|--:|--:|\n| `canvas_layout` | 41.2 ms | 0.38 ms |\n| the sweep, per session | one `mkdir` | none |\n| **search, lowercased** | 4 copies a session | none |\n\nThe table is in the scene because a pipe table is only worth what it looks like, and this is the only way to look at one without a compositor.",
	)
}

@(private = "file")
shot_text :: proc(app: ^App, role: Role, kind: Block_Kind, text: string) {
	m := chat_append(&app.chat, role)
	b := Block {
		kind = kind,
		text = strings.builder_make(),
	}
	strings.write_string(&b.text, text)
	msg_append_block(&app.chat, m, b)
}

@(private = "file")
shot_err :: proc(app: ^App, text: string) {
	shot_text(app, .Assistant, .Error, text)
}

@(private = "file")
shot_tool :: proc(app: ^App, name, input, result: string) {
	m := chat_append(&app.chat, .Assistant)
	b := Block {
		kind   = .Tool,
		text   = strings.builder_make(),
		name   = name,
		input  = strings.builder_make(),
		result = strings.builder_make(),
	}
	strings.write_string(&b.input, input)
	strings.write_string(&b.result, result)
	msg_append_block(&app.chat, m, b)
}
