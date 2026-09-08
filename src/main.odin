package aithing

import "base:runtime"
import "core:fmt"
import "core:os"
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
	reloaded := false // this run replaced an older one that saw a new binary
	model := MODEL_DEFAULT
	model_set := false
	prompt_parts := make([dynamic]string, context.temp_allocator)
	want_model := false
	for arg in os.args[1:] {
		if want_model {
			want_model = false
			model, model_set = model_parse(arg)
			continue
		}
		switch arg {
		case "-h", "--help":
			fmt.println("aithing - a window around `claude -p`")
			fmt.println("  aithing                 reopen the most recent session")
			fmt.println("  aithing --new           start a blank chat instead")
			fmt.println("  aithing --model haiku   pick the model for this run")
			fmt.println("  aithing <prompt...>     a new chat, sent straight away")
			fmt.println("  sessions are read from ~/.claude/projects")
			return
		case "--version":
			fmt.println("aithing 0.1")
			return
		case "--last", "-c", "--continue":
			open_last = true
		case "--new", "-n":
			open_last = false
		case RELOAD_FLAG:
			reloaded = true
		case "--model":
			want_model = true
		case:
			append(&prompt_parts, arg)
		}
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
	watchdog_start()
	defer watchdog_stop()
	reload_init()
	if model_set do app.model = model

	// What the process this one replaced was in the middle of — or, on a
	// plain launch, what the last window had on screen when it was closed.
	// Both are the same picture written by the same serializer: see
	// state.odin.
	state := reloaded ? reload_restore() : state_read(config_path("state"))
	defer state_free(&state)
	state_restore(app, state, model_set)
	if reloaded do state_restore_queue(app, state)

	if open_last {
		// The scan is on a worker thread; wait for it just this once.
		for !app.scanned {
			app_poll_jobs(app)
			time.sleep(4 * time.Millisecond)
		}
		// Newest first, so 0 is the right answer unless a reload named the
		// session it was looking at.
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
			app.canvas.opened = state.ok && state.opened
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
		// A rebuilt binary takes over here, between one frame and the next,
		// but never in the middle of a turn: exec would take the pipe the
		// answer is still arriving on with it, and anything queued behind it
		// only exists in this process.
		if reload_build_poll(app) do needs_draw = true
		reload_swap(app)

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

	// Where the caret is, which follows what is on screen: the launcher's
	// query, the composer inside an open thread, or the box under the grid.
	if app.canvas.launcher {
		app.focus = .Search
	} else if app.canvas.opened {
		if app.focus != .Composer do app.focus = .Composer
	} else {
		app.focus = .Capture
	}
	target := focused_editor(app)
	search_changed := false

	for k in win.input.keys {
		// The grid and its launcher are driven from the keyboard; the caret
		// only gets what they do not want.
		if app.canvas.launcher {
			switch k.code {
			case KEY_UP:
				app.canvas.menu_at = max(app.canvas.menu_at - 1, 0)
				continue
			case KEY_DOWN:
				app.canvas.menu_at += 1
				continue
			}
		} else if !app.canvas.opened {
			// While something is being typed into the box under the grid the
			// caret has the horizontal arrows; the cards keep the vertical
			// ones, which is the only way to reach them from the box.
			typing := editor_text(&app.capture) != ""
			switch k.code {
			case KEY_LEFT:
				if typing do break
				canvas_move_sel(app, -1, 0)
				continue
			case KEY_RIGHT:
				if typing do break
				canvas_move_sel(app, 1, 0)
				continue
			case KEY_UP:
				canvas_move_sel(app, 0, -1)
				continue
			case KEY_DOWN:
				canvas_move_sel(app, 0, 1)
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
				cwd := app.canvas.opened ? app.chat.cwd : app.canvas.project
				if cwd == "" do cwd = app.cwd
				canvas_new_chat(app, cwd)
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
			}
		}

		target = focused_editor(app)
		switch editor_key(target, k, ui.time) {
		case .Submit:
			if app.canvas.launcher {
				launcher_confirm(app)
			} else if !app.canvas.opened {
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
			if lo, hi := editor_selection(target); hi > lo {
				clipboard_set_text(win, editor_text(target)[lo:hi])
			}
		case .Cut:
			if lo, hi := editor_selection(target); hi > lo {
				clipboard_set_text(win, editor_text(target)[lo:hi])
				editor_delete_selection(target)
				search_changed = app.focus == .Search
			}
		case .Paste:
			app_paste(app, target)
			search_changed = app.focus == .Search
		case .None:
			if app.focus == .Search do search_changed = true
		}
	}

	if len(win.input.text) > 0 {
		typed := string(win.input.text[:])
		// Typing on the grid writes the list: it lands in the box along the
		// bottom. `/` over an empty box is the way into the launcher, which
		// is where searching lives.
		if !app.canvas.opened && !app.canvas.launcher && typed == "/" && editor_text(&app.capture) == "" {
			app_launcher(app, true)
			typed = ""
		}
		if typed != "" {
			target = focused_editor(app)
			editor_insert(target, typed)
			target.last_edit = ui.time
			if app.focus == .Search do search_changed = true
		}
	}

	if search_changed do app.canvas.menu_at = 0

	if search_changed do app_filter(app)
}

// The box a keystroke goes to. The focus is settled at the top of app_input,
// so this is only ever the one that is on screen.
focused_editor :: proc(app: ^App) -> ^Editor {
	switch app.focus {
	case .Search:
		return &app.search
	case .Capture:
		return &app.capture
	case .Composer:
		return &app.editor
	}
	return &app.editor
}

// Super+V: an image on the clipboard becomes an attachment, anything else is
// pasted as text.
app_paste :: proc(app: ^App, target: ^Editor) {
	if target == &app.editor {
		if data, mime, ok := clipboard_image(&app.win); ok {
			defer delete(data)
			if len(app.attach) == cap(app.attach) {
				app_status(app, "that is as many attachments as one message takes")
				return
			}
			if a, made := attachment_make(&app.gpu, data, mime); made {
				append(&app.attach, a)
				app_status(app, fmt.tprintf("attached %s", base_name(a.path)))
				return
			}
		}
	}
	if text, ok := clipboard_text(&app.win); ok {
		defer delete(text)
		editor_insert(target, strings.trim_null(text))
	}
}

// Esc. Inside a thread it stops that thread's turn and the follow-ups typed
// behind it, and leaves whatever is running elsewhere alone. From the grid
// there is no one turn it could mean, so it stops the lot.
// Esc inside a thread: stops the turn running in that thread and the
// follow-ups typed behind it, and leaves everything running elsewhere alone.
// There is no gesture that stops the lot, on purpose — a key that could do
// that by being pressed one time too many is how work stopped for no reason
// anyone could see.
// Ctrl+C: stop the work in front of you. Inside a
// thread that is the thread's turn and the follow-ups typed behind it; on the
// grid it is the card the cursor is on, running or merely queued.
//
// One thing, never everything. A key that stops four turns you cannot see is
// how work stopped for no reason anyone could make out — which is what Esc
// used to do, and why it no longer stops anything at all.
app_interrupt :: proc(app: ^App) {
	if app.canvas.opened {
		at := turn_chat(app)
		if at < 0 && len(app.queue) == 0 do return
		app_queue_clear_messages(app)
		if at >= 0 do turn_stop(app, at)
		app_status(app, "stopped")
		return
	}
	at := todos_find(&app.todos, app.canvas.sel)
	if at < 0 do return
	batch := strings.clone(app.todos.list[at].batch, context.temp_allocator)
	stopped := false
	if len(app.run_queue) > 0 {
		before := len(app.run_queue)
		app_unqueue_batch(app, batch)
		if len(app.run_queue) != before {
			todos_batch_state(&app.todos, batch, .Open)
			todos_save(&app.todos)
			app_filter(app)
			stopped = true
		}
	}
	if turn := turn_for_batch(app, batch); turn >= 0 {
		turn_stop(app, turn)
		stopped = true
	}
	if stopped do app_status(app, "stopped")
}
