package aithing

import "core:fmt"
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
	Thread, // a card opened: transcript and composer over the grid
	Launcher, // the menu, with a query typed into it
}

@(private = "file")
scene_names := [Scene]string {
	.Grid     = "grid",
	.Project  = "project",
	.Thread   = "thread",
	.Launcher = "launcher",
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

	for i in 0 ..< SHOT_SETTLE {
		ui_begin(&app.ui, width, height, &app.win.input, SHOT_DT)
		draw_app(app)
		ui_end(&app.ui)
		if !app.ui.animating do break
	}
	// The shader clock drives the running card's pulse, so the frame that is
	// kept starts it from a known place rather than from however many frames
	// the settling happened to take.
	app.ui.time = 0
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
	case .Thread:
		app.canvas.project = PROJ
		app.page = .Thread
		shot_thread(app)
	case .Launcher:
		app.overlay = .Launcher
		editor_set_text(&app.search, "grid")
	}
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
	shot_tool(app, "Read", "src/canvas.odin", "126: canvas_layout :: proc(app: ^App) -> f32 {")
	shot_text(
		app,
		.Assistant,
		.Text,
		"About half a millisecond at 1200 sessions and 400 cards, and frames are only drawn on input or animation — so a cache here would be a second copy of the grid bought with nothing.",
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
	app.chat_ver += 1
}

@(private = "file")
shot_tool :: proc(app: ^App, name, arg, result: string) {
	m := chat_append(&app.chat, .Assistant)
	b := Block {
		kind   = .Tool,
		text   = strings.builder_make(),
		name   = name,
		arg    = arg,
		result = strings.builder_make(),
	}
	strings.write_string(&b.result, result)
	msg_append_block(&app.chat, m, b)
	app.chat_ver += 1
}
