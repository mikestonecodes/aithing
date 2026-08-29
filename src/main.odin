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

FRAME_BUDGET :: time.Duration(16 * time.Millisecond)
ATLAS_PX :: f32(34)

main :: proc() {
	g_ctx = context
	redirect_log()

	open_last := true // by default, pick up where the last session left off
	model := Model.Default
	prompt_parts := make([dynamic]string, context.temp_allocator)
	want_model := false
	for arg in os.args[1:] {
		if want_model {
			want_model = false
			for m in Model do if model_label[m] == arg do model = m
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
	// pixel by convention; everything after them is a pasted image.
	px := ATLAS_PX * f32(app.win.scale)
	regular, r_ok := font_load(&app.gpu, "/usr/share/fonts/noto/NotoSans-Regular.ttf", px)
	white := [4]byte{255, 255, 255, 255}
	white_slot := texture_upload(&app.gpu, white[:], 1, 1, 4)
	bold, b_ok := font_load(&app.gpu, "/usr/share/fonts/noto/NotoSans-Bold.ttf", px)
	mono, m_ok := font_load(&app.gpu, "/usr/share/fonts/noto/NotoSansMono-Regular.ttf", px * 0.9)
	if !r_ok || !b_ok || !m_ok || white_slot != WHITE_TEX {
		fmt.eprintln("could not set up fonts")
		return
	}
	app.ui.regular, app.ui.bold, app.ui.mono = regular, bold, mono
	defer ui_destroy(&app.ui)

	app_init(app)
	defer app_destroy(app)
	app.model = model

	if open_last {
		// The scan is on a worker thread; wait for it just this once.
		for !app.scanned {
			app_poll_jobs(app)
			time.sleep(4 * time.Millisecond)
		}
		if len(app.sessions) > 0 do app_open(app, 0)
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

	last_frame := time.now()
	last_draw := time.now()
	needs_draw := true

	// AITHING_PROFILE=1 reports how long a frame actually takes, and how long
	// a keystroke waited between arriving and being presented.
	profile := os.get_env("AITHING_PROFILE", context.temp_allocator) != ""
	prof_window := time.now()
	prof_frames := 0
	prof_worst_build, prof_worst_draw, prof_worst_latency: f64

	for !app.win.should_close {
		// Idle costs nothing: the window sleeps on the compositor's socket
		// until something happens, and any event cuts the wait short. While
		// Claude is answering the timeout drops so streamed text lands
		// promptly.
		timeout: i32 = 500
		if needs_draw {
			// Something is animating. Wait out the rest of the frame budget
			// rather than spinning — a keystroke arriving mid-wait still
			// wakes the poll immediately.
			left := FRAME_BUDGET - time.since(last_draw)
			timeout = left > 0 ? i32(time.duration_milliseconds(left)) : 0
		} else if runner_busy(&app.runner) {
			timeout = 30
		}
		if ms, pending := window_repeat_timeout(&app.win); pending {
			timeout = min(timeout, ms)
		}
		window_poll(&app.win, timeout)
		input_at := time.now()

		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_frame, now)))
		last_frame = now

		if app.win.resized {
			app.gpu.ui_scale = f32(app.win.scale)
			gpu_resize(&app.gpu, window_pixel_size(&app.win))
			needs_draw = true
		}
		if cycle && app.scanned && time.duration_milliseconds(time.since(cycle_at)) > 400 {
			cycle_at = time.now()
			if cycle_index < len(app.sessions) {
				fmt.eprintfln("cycle %d/%d", cycle_index, len(app.sessions))
				app_open(app, cycle_index)
				cycle_index += 1
			} else {
				app.win.should_close = true
			}
		}

		fresh_input := window_has_input(&app.win)
		if fresh_input do needs_draw = true
		if app_apply_events(app) do needs_draw = true
		if app_poll_jobs(app) do needs_draw = true
		if app.rescan && !runner_busy(&app.runner) {
			app.rescan = false
			app_rescan(app)
			needs_draw = true
		}
		app_input(app)
		if app_apply_clicks(app) do needs_draw = true

		if !needs_draw {
			free_all(context.temp_allocator)
			continue
		}
		// Anything the pointer or keyboard did is drawn on the spot: a frame
		// held back to pace an animation is exactly what makes typing feel
		// mushy. Animation-only frames wait for the budget instead, which the
		// poll above already did.
		if !fresh_input && time.since(last_draw) < FRAME_BUDGET {
			free_all(context.temp_allocator)
			continue
		}

		last_draw = time.now()
		build_start := time.now()
		ui_begin(&app.ui, app.win.width, app.win.height, &app.win.input, dt)
		draw_app(app)
		ui_end(&app.ui)
		build_ms := time.duration_milliseconds(time.since(build_start))

		draw_start := time.now()
		if !gpu_draw(&app.gpu, &app.ui, BG) {
			gpu_resize(&app.gpu, window_pixel_size(&app.win))
		}
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
					"%d fps  worst build %.2fms  draw %.2fms  input->present %.2fms",
					prof_frames,
					prof_worst_build,
					prof_worst_draw,
					prof_worst_latency,
				)
				prof_window = time.now()
				prof_frames = 0
				prof_worst_build, prof_worst_draw, prof_worst_latency = 0, 0, 0
			}
		}

		needs_draw = app.ui.animating || app.ui.time_effects || runner_busy(&app.runner)
		free_all(context.temp_allocator)
	}
}

// Launched from a desktop entry there is nowhere for a message to go, so when
// stderr is not a terminal it is pointed at a file. Anything the program says
// on the way down — a Vulkan complaint, a bounds check — ends up there.
redirect_log :: proc() {
	if terminal.is_terminal(os.stderr) do return
	path := cache_path("last-run.log", context.temp_allocator)
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

	target := app.focus == .Search ? &app.search : &app.editor
	search_changed := false

	for k in win.input.keys {
		// Window-level shortcuts first; anything left goes to the caret.
		if .Ctrl in k.mods {
			switch k.code {
			case KEY_N:
				if !runner_busy(&app.runner) do chat_new(app)
				continue
			case KEY_F:
				app.focus = .Search
				continue
			case KEY_R:
				app.rescan = true
				continue
			case KEY_M:
				app.model = Model((int(app.model) + 1) % len(Model))
				continue
			}
		}

		switch editor_key(target, k, ui.time) {
		case .Submit:
			if app.focus == .Search {
				// Enter in the search box opens the top result.
				if len(app.visible) > 0 do app_open(app, app.visible[0])
				app.focus = .Composer
			} else {
				app_send(app)
			}
		case .Cancel:
			if app.focus == .Search {
				editor_clear(&app.search)
				app.focus = .Composer
				search_changed = true
			} else if runner_busy(&app.runner) {
				app_interrupt(app)
			}
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
		editor_insert(target, string(win.input.text[:]))
		target.last_edit = ui.time
		if app.focus == .Search do search_changed = true
	}

	if search_changed do app_filter(app)
}

// Ctrl+V: an image on the clipboard becomes an attachment, anything else is
// pasted as text.
app_paste :: proc(app: ^App, target: ^Editor) {
	if target == &app.editor {
		if data, mime, ok := clipboard_image(&app.win); ok {
			defer delete(data)
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

app_interrupt :: proc(app: ^App) {
	if !runner_busy(&app.runner) do return
	runner_stop(&app.runner)
	app_status(app, "interrupted")
}
