package aithing

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:terminal"
import "core:time"

// A native front end for the real thing: every turn is a `claude -p` process,
// so the harness, the tools, the permissions and the session files are all
// Claude Code's own. This program only draws.

g_ctx: runtime.Context

// How long an animation frame waits for the compositor before going out
// unpaced: a hidden window gets no frame callbacks at all.
FRAME_FALLBACK :: time.Duration(100 * time.Millisecond)
// How often the session list is re-read when nothing asked for it.
RESCAN_EVERY :: time.Duration(10 * time.Second)
// How often what is on screen is written down, so that a window that never
// gets to close cleanly still opens where it was.
STATE_EVERY :: time.Duration(2 * time.Second)

main :: proc() {
	g_ctx = context
	redirect_log()
	crash_report_install()

	open_last := true // by default, pick up where the last session left off
	model := MODEL_DEFAULT
	model_set := false
	effort := EFFORT_DEFAULT
	effort_set := false
	prompt_parts := make([dynamic]string, context.temp_allocator)
	want_model := false
	want_effort := false
	// A run that draws one frame into a file and exits: see shot.odin.
	shot_path, shot_scene := "", "grid"
	shot_w, shot_h := 1180, 800
	want_shot, want_scene, want_size := false, false, false
	for arg in os.args[1:] {
		if want_model {
			want_model = false
			model, model_set = model_parse(arg)
			continue
		}
		if want_effort {
			want_effort = false
			effort, effort_set = effort_parse(arg)
			continue
		}
		if want_shot {
			want_shot = false
			shot_path = arg
			continue
		}
		if want_scene {
			want_scene = false
			shot_scene = arg
			continue
		}
		if want_size {
			want_size = false
			if w, h, ok := size_parse(arg); ok {
				shot_w, shot_h = w, h
			} else {
				fmt.eprintfln("--size wants WxH, not %q", arg)
				os.exit(2)
			}
			continue
		}
		switch arg {
		case "-h", "--help":
			fmt.println("aithing - a window around `claude -p`")
			fmt.println("  aithing                 reopen the most recent session")
			fmt.println("  aithing --new           start a blank chat instead")
			fmt.println("  aithing --model haiku   pick the model for this run")
			fmt.println("  aithing --effort high   how hard it thinks, this run")
			fmt.println("  aithing <prompt...>     a new chat, sent straight away")
			fmt.printfln("  aithing --shot out.png [--scene %s] [--size 1180x800]", scene_list())
			fmt.println("                          draw one frame of a built-up scene, no window")
			fmt.println("  sessions are read from ~/.claude/projects")
			return
		case "--version":
			fmt.println("aithing 0.1")
			return
		case "--last", "-c", "--continue":
			open_last = true
		case "--new", "-n":
			open_last = false
		case "--model":
			want_model = true
		case "--effort":
			want_effort = true
		case "--shot":
			want_shot = true
		case "--scene":
			want_scene = true
		case "--size":
			want_size = true
		case:
			append(&prompt_parts, arg)
		}
	}

	// Before the window, because there is not going to be one: a shot builds
	// its own state and draws it into an image of its own.
	if shot_path != "" {
		scene, ok := scene_parse(shot_scene)
		if !ok {
			fmt.eprintfln("no scene called %q — try one of: %s", shot_scene, scene_list())
			os.exit(2)
		}
		if !shot_run(shot_path, scene, shot_w, shot_h) do os.exit(1)
		return
	}

	app := new(App)
	defer free(app)

	if !window_open(&app.win, "aithing", 1180, 800) do return
	defer window_close(&app.win)

	if !gpu_init(&app.gpu, &app.win) do return
	defer gpu_destroy(&app.gpu)

	// Slots 0 and 1 of the bindless table are the glyph atlas and a white
	// pixel by convention; everything after them is a pasted image. All three
	// fonts are on the one sheet, so this is a single upload and the window
	// scale no longer decides how sharp text is.
	regular, bold, mono, fonts_ok := font_atlas_load(&app.gpu)
	white := [4]byte{255, 255, 255, 255}
	white_slot := texture_upload(&app.gpu, white[:], 1, 1, 4)
	if !fonts_ok || white_slot != WHITE_TEX {
		fmt.eprintln("could not set up fonts")
		return
	}
	app.ui.regular, app.ui.bold, app.ui.mono = regular, bold, mono
	defer ui_destroy(&app.ui)

	app_init(app)
	defer app_destroy(app)
	// Work that lands in this repository rebuilds this program: see build.odin.
	build_init()
	defer build_destroy()
	watchdog_start()
	defer watchdog_stop()
	if model_set do app.model = model
	if effort_set do app.effort = effort

	// What the last window had on screen when it was closed: see state.odin.
	state := state_read(config_path("state"))
	defer state_free(&state)
	state_restore(app, state, model_set, effort_set)

	if open_last {
		// The scan is on a worker thread; wait for it just this once.
		for !app.scanned {
			app_poll_jobs(app)
			time.sleep(4 * time.Millisecond)
		}
		// Newest first, so 0 is the right answer unless the state file named
		// the session the last window was looking at.
		open_at := 0
		if state.session != "" {
			for sn, i in app.sessions do if sn.id == state.session {
				open_at = i
				break
			}
		}
		// The canvas is the home view: the last thread is only zoomed open
		// again when the window this one continues had it open.
		if len(app.sessions) > 0 {
			app_open(app, open_at)
			app.page = state.ok && state.opened ? .Thread : .Grid
		}
	}
	// AITHING_CYCLE=1 walks the whole session list, one every 400ms. It is how
	// the transcript reader gets exercised against every session on disk.
	cycle := os.get_env("AITHING_CYCLE", context.temp_allocator) != ""
	cycle_at := time.now()
	cycle_index := 0
	if len(prompt_parts) > 0 {
		editor_set_text(&app.editor, strings.join(prompt_parts[:], " ", context.temp_allocator))
		app_send(app)
	}

	last_draw := time.now()
	needs_draw := true
	wake_at: Maybe(time.Time) // when something asked to be redrawn next

	// AITHING_PROFILE=1 reports how long a frame actually takes, and how long
	// a keystroke waited between arriving and being presented.
	profile := os.get_env("AITHING_PROFILE", context.temp_allocator) != ""
	prof_window := time.now()
	prof_frames := 0
	prof_worst_build, prof_worst_draw, prof_worst_latency: f64
	// Frames drawn for input, on the compositor's cue, and after giving up
	// waiting for it.
	prof_input, prof_paced, prof_fallback: int

	for !app.win.should_close {
		// Idle costs nothing: the window sleeps on the compositor's socket
		// until something happens, and any event cuts the wait short. While
		// Claude is answering the timeout drops so streamed text lands
		// promptly.
		timeout: i32 = 500
		if needs_draw {
			// Something is animating. Wait for the compositor to ask for
			// the next frame rather than spinning — a keystroke arriving
			// mid-wait still wakes the poll immediately. A window nobody can
			// see is never asked, so the wait is capped and the frame goes
			// out anyway.
			if window_frame_pending(&app.win) {
				left := FRAME_FALLBACK - time.since(last_draw)
				timeout = left > 0 ? i32(time.duration_milliseconds(left)) : 0
			} else {
				timeout = 0
			}
		} else if app_busy(app) {
			timeout = 30
		}
		if ms, pending := window_repeat_timeout(&app.win); pending {
			timeout = min(timeout, ms)
		}
		if at, ok := wake_at.?; ok {
			left := time.duration_milliseconds(time.diff(time.now(), at))
			timeout = min(timeout, i32(max(left, 0)))
		}
		// A wait with a frame owed is a stall if it never ends; a wait with
		// nothing to draw is just an idle window.
		watch(needs_draw ? .Wait : .Poll)
		window_poll(&app.win, timeout)
		input_at := time.now()

		now := time.now()
		if app.win.resized {
			app.gpu.ui_scale = f32(app.win.scale)
			gpu_resize(&app.gpu, window_pixel_size(&app.win))
			needs_draw = true
		}
		if cycle && app.scanned && time.duration_milliseconds(time.since(cycle_at)) > 400 {
			cycle_at = time.now()
			if cycle_index < len(app.sessions) {
				fmt.eprintfln("cycle %d/%d", cycle_index, len(app.sessions))
				// Through the click path, not app_open directly, and with a
				// rescan racing it: an index recorded during a frame is only
				// acted on in the next one, by which time the list it came
				// from may have been swapped out under it.
				app_select(app, app.sessions[cycle_index].id)
				app.rescan = true
				cycle_index += 1
			} else {
				app.win.should_close = true
			}
		}

		fresh_input := window_has_input(&app.win)
		if fresh_input do needs_draw = true
		if at, ok := wake_at.?; ok && time.since(at) >= 0 {
			wake_at = nil
			needs_draw = true
		}
		watch(.Events)
		if app_apply_events(app) do needs_draw = true
		watch(.Jobs)
		if app_poll_jobs(app) do needs_draw = true
		if build_poll(app) do needs_draw = true
		// The map keeps itself current. Threads are re-read on a slow tick,
		// so a run that finished in another window, or work that has been
		// checked since, turns up on its own. Far enough apart to be free —
		// the read is on a worker thread and the frame it costs is one dot
		// changing colour.
		if !app.rescan && time.since(app.scan_at) > RESCAN_EVERY do app.rescan = true
		// Where you are, written down: a window closed by the compositor,
		// or killed, opens again exactly where it was.
		if time.since(app.state_at) > STATE_EVERY {
			app.state_at = time.now()
			state_save(app)
		}
		// Not while the thread on screen is streaming: a scan lands a new
		// session list, and the transcript should not stutter for it. Turns
		// running in the background are no reason to hold the map still.
		if app.rescan && !app_chat_busy(app) {
			app.rescan = false
			app_rescan(app)
			needs_draw = true
		}
		watch(.Input)
		app_input(app)
		if app_apply_clicks(app) do needs_draw = true

		if !needs_draw {
			free_all(context.temp_allocator)
			continue
		}
		// Anything the pointer or keyboard did is drawn on the spot: a frame
		// held back to pace an animation is exactly what makes typing feel
		// mushy. Animation-only frames wait for the compositor's frame
		// callback instead, so they land once per refresh.
		if !fresh_input && window_frame_pending(&app.win) && time.since(last_draw) < FRAME_FALLBACK {
			free_all(context.temp_allocator)
			continue
		}

		// Animations step by the time since the last frame that was actually
		// drawn; a loop that woke for a job or a pipe in between is not a
		// frame.
		dt := f32(time.duration_seconds(time.since(last_draw)))
		if profile {
			if fresh_input do prof_input += 1
			else if window_frame_pending(&app.win) do prof_fallback += 1
			else do prof_paced += 1
		}
		last_draw = time.now()
		window_request_frame(&app.win)
		watch(.Build)
		build_start := time.now()
		ui_begin(&app.ui, app.win.width, app.win.height, &app.win.input, dt)
		draw_app(app)
		ui_end(&app.ui)
		build_ms := time.duration_milliseconds(time.since(build_start))

		watch(.Draw)
		draw_start := time.now()
		if !gpu_draw(&app.gpu, &app.ui, BG) {
			gpu_resize(&app.gpu, window_pixel_size(&app.win))
		}
		// A frame the driver would not hand us an image for has not been
		// presented; keep asking rather than waiting for the next keystroke.
		skipped := app.gpu.frame_skipped
		// Nothing was committed, so the callback would never come.
		if skipped do window_cancel_frame(&app.win)
		if app.gpu.surface_lost do app.win.should_close = true
		draw_ms := time.duration_milliseconds(time.since(draw_start))

		if profile {
			prof_frames += 1
			prof_worst_build = max(prof_worst_build, build_ms)
			prof_worst_draw = max(prof_worst_draw, draw_ms)
			if fresh_input {
				prof_worst_latency = max(
					prof_worst_latency,
					time.duration_milliseconds(time.since(input_at)),
				)
			}
			if time.duration_seconds(time.since(prof_window)) >= 1 {
				fmt.eprintfln(
					"%d fps (%d input, %d paced, %d fallback)  worst build %.2fms  draw %.2fms  input->present %.2fms",
					prof_frames,
					prof_input,
					prof_paced,
					prof_fallback,
					prof_worst_build,
					prof_worst_draw,
					prof_worst_latency,
				)
				prof_window = time.now()
				prof_frames = 0
				prof_worst_build, prof_worst_draw, prof_worst_latency = 0, 0, 0
				prof_input, prof_paced, prof_fallback = 0, 0, 0
			}
		}

		needs_draw = skipped || app.ui.animating || app.ui.time_effects || app_busy(app)
		if app.ui.wake_in < NEVER {
			wake_at = time.time_add(time.now(), time.Duration(f64(app.ui.wake_in) * f64(time.Second)))
		}
		free_all(context.temp_allocator)
	}
}

// Launched from a desktop entry there is nowhere for a message to go, so when
// stderr is not a terminal it is pointed at a file. Anything the program says
// on the way down — a Vulkan complaint, a bounds check — ends up there.
// "1180x800". Its own proc because two numbers that have to agree with each
// other are exactly the kind of thing that gets half-parsed inline.
@(private = "file")
size_parse :: proc(arg: string) -> (w, h: int, ok: bool) {
	at := strings.index_byte(arg, 'x')
	if at <= 0 do return 0, 0, false
	w, ok = strconv.parse_int(arg[:at])
	if !ok do return 0, 0, false
	h, ok = strconv.parse_int(arg[at + 1:])
	if !ok || w <= 0 || h <= 0 do return 0, 0, false
	return w, h, true
}

redirect_log :: proc() {
	if terminal.is_terminal(os.stderr) do return
	// One shared name, so a second instance would truncate the first one's
	// log out from under it; AITHING_LOG is how a test run stays out of the
	// way of a window someone is actually using.
	name := os.get_env("AITHING_LOG", context.temp_allocator)
	if name == "" do name = "last-run.log"
	path := cache_path(name, context.temp_allocator)
	f, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil do return
	linux.dup2(linux.Fd(os.fd(f)), linux.Fd(2))
	os.close(f)
}

// --- input ------------------------------------------------------------------

app_input :: proc(app: ^App) {
	win := &app.win
	ui := &app.ui
	if len(win.input.keys) == 0 && len(win.input.text) == 0 do return

	target := focused_editor(app)
	search_changed := false

	for k in win.input.keys {
		// The grid and its launcher are driven from the keyboard; the caret
		// only gets what they do not want.
		if app.overlay == .Launcher {
			switch k.code {
			case KEY_UP:
				app.canvas.menu_at = max(app.canvas.menu_at - 1, 0)
				continue
			case KEY_DOWN:
				app.canvas.menu_at += 1
				continue
			}
		} else if app.page == .Grid {
			// Up and down are the box's history — the line typed a minute ago,
			// back again — and the cards have left and right. They used to be
			// split the other way round, so what had already been written
			// could not be got back at all.
			typing := editor_text(&app.capture) != ""
			switch k.code {
			case KEY_UP:
				if app_history(app, 1) do continue
			case KEY_DOWN:
				if app_history(app, -1) do continue
			case KEY_LEFT:
				if typing do break
				canvas_step_sel(app, -1)
				continue
			case KEY_RIGHT:
				if typing do break
				canvas_step_sel(app, 1)
				continue
			}
		}
		// Window-level shortcuts first; anything left goes to the caret.
		if .Ctrl in k.mods {
			switch k.code {
			case KEY_N:
				// A new thread in whatever project you are looking at: the
				// open thread's, or the one the grid is narrowed to. A turn
				// running elsewhere is no reason to refuse — it is running in
				// its own slot and its own thread.
				canvas_new_chat(app, app_project(app))
				route_off(app) // said by hand: do not route this one away
				continue
			case KEY_F:
				app_launcher(app, true)
				continue
			case KEY_R:
				app.rescan = true
				continue
			case KEY_M:
				app.model = Model((int(app.model) + 1) % len(Model))
				model_save(app.model)
				continue
			case KEY_E:
				app.effort = Effort((int(app.effort) + 1) % len(Effort))
				effort_save(app.effort)
				continue
			}
		}

		// Every page has a box, so every key has a caret to go to, and the
		// ones that are not about text — Enter, Esc, ctrl c — come back out
		// of the editor as actions. There was a second copy of that switch
		// here for the grid that had no box, and being a copy it drifted:
		// paste and cut were only ever in one of them.
		target = focused_editor(app)
		action := editor_key(target, k, ui.time)
		switch action {
		case .Submit:
			if app.overlay == .Launcher {
				launcher_confirm(app)
			} else if app.page == .Grid {
				// Enter over a written list makes the cards; over an empty
				// box it opens the card the cursor is on.
				if strings.trim_space(editor_text(&app.capture)) != "" {
					app_capture(app)
				} else {
					canvas_open_sel(app)
				}
			} else {
				app_send(app)
			}
		case .Cancel:
			if app_cancel(app) do search_changed = true
		case .Stop:
			app_interrupt(app)
		case .Copy:
			app_copy(app, target)
		case .Cut:
			if lo, hi := editor_selection(target); hi > lo {
				clipboard_set_text(win, editor_text(target)[lo:hi])
				editor_delete_selection(target)
				search_changed = app_focus(app) == .Search
			}
		case .Paste:
			app_paste(app, target)
			search_changed = app_focus(app) == .Search
		case .None:
			if app_focus(app) == .Search do search_changed = true
		}
	}

	if len(win.input.text) > 0 {
		typed := string(win.input.text[:])
		// Typing on the grid writes the list: it lands in the box along the
		// bottom. `/` over an empty box is the way into the launcher, which
		// is where searching lives.
		if app.page == .Grid && app.overlay == .None && typed == "/" && editor_text(&app.capture) == "" {
			app_launcher(app, true)
			typed = ""
		}
		if typed != "" && focused_editor(app) != nil {
			target = focused_editor(app)
			editor_insert(target, typed)
			target.last_edit = ui.time
			// Typing over something the history put there makes it yours: the
			// next Up starts from the newest card again rather than carrying
			// on from wherever the walk had got to.
			if target == &app.capture do app.history_at = 0
			if app_focus(app) == .Search do search_changed = true
		}
	}

	if search_changed do app.canvas.menu_at = 0
}

// The box a keystroke goes to, worked out from the page rather than
// remembered: the one that is on screen is the one that is typed into. Nil on
// a grid of every project, where there is no box — and every key still has
// somewhere to go, because editor_key answers the ones that are not about
// text without an editor to answer them for.
focused_editor :: proc(app: ^App) -> ^Editor {
	switch app_focus(app) {
	case .Search:
		return &app.search
	case .Capture:
		return &app.capture
	case .Composer:
		return &app.editor
	case .None:
		return nil
	}
	return nil
}

// Super+C: the selection when there is one, and otherwise whatever the pointer
// is resting on — a card, a paragraph of an answer, an error. It used to be
// the selection or nothing, which on the grid was always nothing: there is no
// way to select a card, so the one place where the thing you want to copy is
// plainly under the pointer was the one place copy did not work.
app_copy :: proc(app: ^App, target: ^Editor) {
	if target != nil {
		if lo, hi := editor_selection(target); hi > lo {
			clipboard_set_text(&app.win, editor_text(target)[lo:hi])
			return
		}
	}
	text := ui_hovered_text(&app.ui)
	if text == "" do return
	clipboard_set_text(&app.win, text)
	app_status(app, "copied")
}

// Super+V: an image on the clipboard becomes something Claude can open,
// anything else is pasted as text.
//
// The image is only offered to the two boxes that say something to Claude. The
// launcher's query is a search over threads already on disk, and a screenshot
// dropped into it as a path would only ever match nothing.
app_paste :: proc(app: ^App, target: ^Editor) {
	if target == &app.editor || target == &app.capture {
		if data, mime, ok := clipboard_image(&app.win); ok {
			defer delete(data)
			if app_paste_image(app, target, data, mime) do return
		}
	}
	if text, ok := clipboard_text(&app.win); ok {
		defer delete(text)
		editor_insert(target, strings.trim_null(text))
	}
}

// A pasted image, put where the box it landed in can carry it.
//
// The composer holds it as an attachment because it has somewhere to draw the
// thumbnail and a send of its own to hang it off. The box under the grid has
// neither — what is typed there is cut into cards and joined back up as one
// prompt, and an attachment list beside it would be a second thing to keep in
// step with the text through every split, dismissal and requeue. So the path
// goes into the text, which is already what goes out. It is the same thing
// `attachments_prompt` does for the composer, said in the one place the grid
// already reads.
//
// False means the paste is not an image after all and the caller should try
// text; a full attachment list is still handled, and still true.
app_paste_image :: proc(app: ^App, target: ^Editor, data: []byte, mime: string) -> bool {
	if target == &app.capture {
		path, wrote := attachment_write(data, mime, context.temp_allocator)
		if !wrote do return false
		// Run onto the end of the last word, the path stops being a path.
		text := editor_text(target)
		if target.cursor > 0 && !is_space_byte(text[target.cursor - 1]) {
			editor_insert(target, " ")
		}
		editor_insert(target, path)
		app_status(app, fmt.tprintf("attached %s", base_name(path)))
		return true
	}
	if len(app.attach) == cap(app.attach) {
		app_status(app, "that is as many attachments as one message takes")
		return true
	}
	a, made := attachment_make(&app.gpu, data, mime)
	if !made do return false
	append(&app.attach, a)
	app_status(app, fmt.tprintf("attached %s", base_name(a.path)))
	return true
}

is_space_byte :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// There is no gesture that stops the lot, on purpose — a key that could do
// that by being pressed one time too many is how work stopped for no reason
// anyone could see.
//
// Ctrl+C: stop the work in front of you. Inside a thread that is the thread's
// turn; on the grid it is the turn the card the cursor is on is running.
//
// One thing, never everything. A key that stops turns you cannot see is how
// work stopped for no reason anyone could make out — which is what Esc used
// to do, and why it no longer stops anything at all.
app_interrupt :: proc(app: ^App) {
	if app.page == .Thread {
		at := turn_chat(app)
		if at < 0 do return
		turn_stop(app, at)
		app_status(app, "stopped")
		return
	}
	at := todos_find(&app.todos, app.canvas.sel)
	if at < 0 do return
	turn := turn_for_todo(app, app.todos.list[at].id)
	if turn < 0 do return
	turn_stop(app, turn)
	app_status(app, "stopped")
}
