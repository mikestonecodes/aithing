package aithing

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// The application: a sidebar of every session Claude Code has ever written, a
// transcript, and a composer. All state is plain data — the UI is rebuilt from
// it every frame — except the transcript itself, which grows as events arrive.

// Colours are packed the way the shader reads them: 0xAABBGGRR.
BG :: Color(0xc8242626)
SIDEBAR_BG :: Color(0xc01d1e1f)
PANEL :: Color(0xff2c2f30)
PANEL_HI :: Color(0xff34383a)
BORDER :: Color(0xff373b3d)
TEXT :: Color(0xffe9f0f2)
MUTED :: Color(0xff8c959a)
FAINT :: Color(0xff62686d)
ACCENT :: Color(0xff5777d9)
ACCENT_DIM :: Color(0x805777d9)
USER_BG :: Color(0xff303436)
CODE_BG :: Color(0xff18191a)
CODE_TEXT :: Color(0xffa0c4e8)
GREEN :: Color(0xff69b07f)
RED :: Color(0xff5a6ce0)

SIDEBAR_W :: f32(320)
CONTENT_MAX :: f32(880)

Focus :: enum {
	Composer,
	Search,
}

App :: struct {
	win:       Window,
	gpu:       Gpu,
	ui:        UI,

	sessions:  []Session,
	visible:   [dynamic]int, // working sessions, after the search filter
	archived:  [dynamic]int, // the rest, behind one row at the bottom
	archive:   Archive,
	show_archive: bool,
	selected:  int, // index into sessions; -1 while composing a new chat
	rescan:    bool,
	scan:      Scan_Job, // the sidebar, read on a worker thread
	load:      Load_Job, // the open transcript, parsed on a worker thread
	scanned:   bool, // false until the first scan lands
	// Clicks are recorded during the frame and acted on once it is over:
	// opening or filing a session rebuilds the very lists the sidebar is in
	// the middle of walking. They name the session by id rather than by row,
	// because a scan can land in that gap and renumber every row — an index
	// from last frame can point at a different session, or past the end of a
	// list that came back shorter.
	pending_open:    string,
	pending_archive: string,
	pending_state:   bool,

	chat:      Chat,
	runner:    Runner,
	editor:    Editor,
	search:    Editor,
	focus:     Focus,

	attach:    [dynamic]Attachment,
	transcript: Scroll,
	sidebar:   Scroll,
	stick:     bool, // keep the transcript pinned to the bottom

	status:    string,
	model:     Model,
	model_open: bool, // the picker, open over the composer
	model_chip: Rect, // where it opens from
	cwd:       string, // where a new chat runs
	cur_msg:   int,
	// The session a running turn belongs to. Switching away mid-turn is
	// allowed: the harness keeps writing to its own session file, so the
	// answer is not lost, it just stops being drawn.
	run_session: string,
	run_index:   int,
	// Messages typed while a turn was still running. One `claude -p` at a
	// time is the whole design, so a follow-up cannot just be started; it
	// waits here and goes out the moment the turn it was typed over finishes.
	queue:       [dynamic]Pending,
	// Message heights, cached: measuring a long transcript every frame is what
	// would make typing feel heavy. Rebuilt when the width or the chat change.
	heights:   [dynamic]f32,
	heights_w: f32,
	heights_at: int,
	chat_ver:  int,
	total_h:   f32,
	open:      map[u64]Ref, // stream content-block index -> where it landed
	cost:      f64,
	profile:   bool,
}

// A message waiting for the turn ahead of it.
Pending :: struct {
	prompt:  string,
	session: string, // "" when the chat had not been given an id yet
	cwd:     string,
	msg:     int, // where it sits in the transcript, so it can stop looking queued
}

@(private = "file")
pending_destroy :: proc(p: ^Pending) {
	delete(p.prompt)
	delete(p.session)
	delete(p.cwd)
}

app_init :: proc(app: ^App) {
	app.selected = -1
	app.stick = true
	cwd, _ := os.get_working_directory(context.allocator)
	app.cwd = cwd
	app.status = strings.clone("ready")
	archive_load(&app.archive)
	app.model = model_load()
	app.profile = os.get_env("AITHING_PROFILE", context.temp_allocator) != ""
	chat_new(app)
	app_rescan(app)
}

app_destroy :: proc(app: ^App) {
	runner_destroy(&app.runner)
	scan_destroy(&app.scan)
	load_destroy(&app.load)
	chat_destroy(&app.chat)
	editor_destroy(&app.editor)
	editor_destroy(&app.search)
	archive_save(&app.archive)
	archive_destroy(&app.archive)
	sessions_free(app.sessions)
	delete(app.visible)
	delete(app.archived)
	for &a in app.attach do attachment_destroy(&a)
	delete(app.attach)
	delete(app.open)
	delete(app.heights)
	delete(app.status)
	delete(app.run_session)
	delete(app.cwd)
	delete(app.pending_open)
	delete(app.pending_archive)
	for &p in app.queue do pending_destroy(&p)
	delete(app.queue)
}

// Kicks off a rescan. Nothing blocks: the list is swapped in whenever the
// worker gets round to finishing.
app_rescan :: proc(app: ^App) {
	scan_start(&app.scan)
}

// Called once a frame: takes whatever the workers have finished.
// Applies whatever the last frame's clicks asked for.
app_apply_clicks :: proc(app: ^App) -> bool {
	acted := app.pending_archive != "" || app.pending_open != ""
	if id := app.pending_archive; id != "" {
		defer delete(id)
		app.pending_archive = ""
		archive_set(&app.archive, id, app.pending_state)
		archive_save(&app.archive)
		app_filter(app)
	}
	if id := app.pending_open; id != "" {
		defer delete(id)
		app.pending_open = ""
		// The row may have moved, or be gone entirely if the session was
		// deleted between the click and here; app_open ignores -1.
		app_open(app, session_index(app, id))
		app_filter(app) // an opened session belongs in the working list
	}
	return acted
}

// Where a session sits in the current list, or -1 if it is no longer in it.
session_index :: proc(app: ^App, id: string) -> int {
	for s, i in app.sessions do if s.id == id do return i
	return -1
}

app_poll_jobs :: proc(app: ^App) -> bool {
	changed := false
	scan_reap(&app.scan)
	load_reap(&app.load)
	load_poll(&app.load)
	// Every frame rather than off the Done event: a turn that dies without
	// finishing cleanly still frees the process, and a follow-up waiting on it
	// should go out either way.
	app_pump_queue(app)

	if list, ok := scan_take(&app.scan); ok {
		// Remember the open session by id: a rescan can shift every index.
		keep: string
		if app.selected >= 0 && app.selected < len(app.sessions) {
			keep = strings.clone(app.sessions[app.selected].id, context.temp_allocator)
		} else if app.chat.session_id != "" {
			keep = strings.clone(app.chat.session_id, context.temp_allocator)
		}

		sessions_free(app.sessions)
		app.sessions = list
		app.scanned = true
		app.selected = -1
		if keep != "" {
			for s, i in app.sessions {
				if s.id != keep do continue
				app.selected = i
				// A new session has its title written by the harness a moment
				// after the first turn; adopt it so the header stops saying
				// "New chat" once there is something better to call it.
				if s.title != "" && s.title != app.chat.title {
					delete(app.chat.title)
					app.chat.title = strings.clone(s.title)
				}
				break
			}
		}
		app_filter(app)
		changed = true
	}

	if chat, ok := load_take(&app.load); ok {
		chat := chat
		chat_destroy(&app.chat)
		clear(&app.open)
		app.chat = chat
		app.cur_msg = -1
		app.stick = true
		app.chat_ver += 1
		app.transcript.offset = 1e9 // clamped to the bottom on the next layout
		app.transcript.target = 1e9
		app_status(app, "ready")
		changed = true
	}
	return changed
}

app_filter :: proc(app: ^App) {
	clear(&app.visible)
	clear(&app.archived)
	query := strings.to_lower(strings.trim_space(editor_text(&app.search)), context.temp_allocator)
	for s, i in app.sessions {
		if query != "" {
			title := strings.to_lower(s.title, context.temp_allocator)
			preview := strings.to_lower(s.preview, context.temp_allocator)
			project := strings.to_lower(s.project, context.temp_allocator)
			if !strings.contains(title, query) &&
			   !strings.contains(preview, query) &&
			   !strings.contains(project, query) {
				continue
			}
		}
		// The session being read stays in the working list even if it is
		// filed away, so opening something from the archive does not make it
		// vanish out from under the pointer.
		if archive_is(&app.archive, s.id, i) && app.selected != i {
			append(&app.archived, i)
		} else {
			append(&app.visible, i)
		}
	}
}

// Both of these only record what was clicked; app_apply_clicks acts on it once
// the frame that is walking the sidebar is over.
app_archive :: proc(app: ^App, id: string, archived: bool) {
	delete(app.pending_archive)
	app.pending_archive = strings.clone(id)
	app.pending_state = archived
}

app_select :: proc(app: ^App, id: string) {
	delete(app.pending_open)
	app.pending_open = strings.clone(id)
}

chat_new :: proc(app: ^App) {
	chat_destroy(&app.chat)
	clear(&app.open)
	app.chat.cwd = strings.clone(app.cwd)
	app.chat.title = strings.clone("New chat")
	app.selected = -1
	app.cur_msg = -1
	app.stick = true
	app.chat_ver += 1
	app.transcript.target = 0
	app.transcript.offset = 0
}

// Opens a session. The transcript is parsed on a worker thread, so the click
// lands instantly even on a session file that runs to tens of megabytes.
app_open :: proc(app: ^App, index: int) {
	if index < 0 || index >= len(app.sessions) do return
	if app.selected == index && !load_busy(&app.load) do return

	s := &app.sessions[index]
	chat_destroy(&app.chat)
	clear(&app.open)
	app.chat.session_id = strings.clone(s.id)
	app.chat.cwd = strings.clone(s.cwd)
	app.chat.title = strings.clone(s.title)
	app.chat.path = strings.clone(s.path)
	app.selected = index
	app.cur_msg = -1
	app.stick = true
	app.chat_ver += 1
	app.transcript.offset = 0
	app.transcript.target = 0
	app_status(app, "loading...")
	load_start(&app.load, s^)
}

app_status :: proc(app: ^App, msg: string) {
	delete(app.status)
	app.status = strings.clone(msg)
}

// --- sending ----------------------------------------------------------------

app_send :: proc(app: ^App) {
	text := strings.trim_space(editor_text(&app.editor))
	if text == "" && len(app.attach) == 0 do return

	prompt := attachments_prompt(text, app.attach[:], context.temp_allocator)

	// Show the turn straight away; the harness echoes it back later, but the
	// UI should never feel like it swallowed what was typed.
	m := chat_append(&app.chat, .User)
	ref := msg_append_block(&app.chat, m, Block{kind = .Text})
	strings.write_string(&chat_block(&app.chat, ref).text, text)
	for a in app.attach {
		img := msg_append_block(&app.chat, m, Block{kind = .Image, image = a})
		_ = img
	}
	clear(&app.attach) // the blocks own the attachments now
	app.chat_ver += 1

	cwd := app.chat.cwd != "" ? app.chat.cwd : app.cwd
	editor_clear(&app.editor)

	// A turn is still running: the message is already in the transcript where
	// it was typed, so all that is left is to remember to send it. Dropping it
	// here — which is what used to happen — looked exactly like a broken
	// Enter key.
	if runner_busy(&app.runner) {
		app.chat.msgs[m].queued = true
		append(
			&app.queue,
			Pending {
				prompt = strings.clone(prompt),
				session = strings.clone(app.chat.session_id),
				cwd = strings.clone(cwd),
				msg = m,
			},
		)
		app.stick = true
		app_status(app, fmt.tprintf("queued (%d)", len(app.queue)))
		return
	}

	if !runner_start(&app.runner, cwd, app.chat.session_id, prompt, model_flag[app.model]) {
		app_status(app, "could not start claude")
		return
	}
	delete(app.run_session)
	app.run_session = strings.clone(app.chat.session_id)
	app.run_index = app.selected
	app.cur_msg = -1
	app.stick = true
	app_status(app, "thinking...")
}

// Sends the next message that was typed over a running turn. Called when one
// finishes, which is the only time there is a process free to run it.
app_pump_queue :: proc(app: ^App) {
	if len(app.queue) == 0 || runner_busy(&app.runner) do return
	p := app.queue[0]
	ordered_remove(&app.queue, 0)
	defer pending_destroy(&p)

	// A message queued against a chat that had no id yet belongs to whichever
	// id the harness handed back for the turn that has just finished.
	session := p.session != "" ? p.session : app.run_session
	// It is going out now, so it stops being drawn as waiting — unless the
	// reader has moved to another session, in which case that transcript is
	// gone and there is nothing to unmark.
	if p.session == app.chat.session_id && p.msg >= 0 && p.msg < len(app.chat.msgs) {
		app.chat.msgs[p.msg].queued = false
		app.chat_ver += 1
	}
	if !runner_start(&app.runner, p.cwd, session, p.prompt, model_flag[app.model]) {
		app_status(app, "could not start claude")
		return
	}
	delete(app.run_session)
	app.run_session = strings.clone(session)
	app.run_index = session_index(app, session)
	app.cur_msg = -1
	app_status(app, "thinking...")
}

// Throws away what is waiting. Interrupting a turn should not be followed by
// the next queued message starting up on its own.
app_queue_clear :: proc(app: ^App) {
	for &p in app.queue {
		if p.session == app.chat.session_id && p.msg >= 0 && p.msg < len(app.chat.msgs) {
			app.chat.msgs[p.msg].queued = false
		}
		pending_destroy(&p)
	}
	if len(app.queue) > 0 do app.chat_ver += 1
	clear(&app.queue)
}

// --- applying what the runner streams ---------------------------------------

@(private = "file")
open_key :: proc(parent: string, index: int) -> u64 {
	return ui_id(parent, index + 1)
}

app_apply_events :: proc(app: ^App) -> bool {
	events := runner_drain(&app.runner, context.temp_allocator)
	if len(events) == 0 do return false

	for &e in events {
		app_apply(app, &e)
		event_destroy(&e)
	}
	return true
}

@(private = "file")
app_apply :: proc(app: ^App, e: ^Event) {
	c := &app.chat

	// A turn that belongs to a session the reader has left still has to be
	// tracked — the id and the finish matter — but its text goes nowhere.
	watching := app.run_session == "" || app.run_session == c.session_id
	if !watching {
		#partial switch e.kind {
		case .Session:
			delete(app.run_session)
			app.run_session = strings.clone(e.id)
		case .Done:
			app.cur_msg = -1
			app.cost = app.runner.cost
			app_status(app, "ready")
			app.rescan = true
		}
		return
	}
	app.chat_ver += 1

	switch e.kind {
	case .Session:
		if e.id != "" && c.session_id != e.id {
			delete(c.session_id)
			c.session_id = strings.clone(e.id)
			delete(app.run_session)
			app.run_session = strings.clone(e.id)
		}

	case .Status:
		if e.text != "" do app_status(app, e.text)

	case .Msg_Start:
		if e.parent == "" do app.cur_msg = chat_append(c, .Assistant)

	case .Block_Start:
		block := Block {
			kind    = e.block_kind,
			running = e.block_kind == .Tool,
		}
		if e.block_kind == .Tool {
			block.name = strings.clone(e.name)
			block.tool_id = strings.clone(e.id)
			block.arg = strings.clone("")
		}
		ref := NO_REF
		if e.parent != "" {
			// A subagent's output belongs under the Task that spawned it.
			owner_ref := chat_find_tool(c, e.parent)
			owner := chat_block(c, owner_ref)
			if owner == nil {
				block_destroy(&block)
				return
			}
			append(&owner.sub, block)
			ref = Ref{owner_ref.msg, owner_ref.block, len(owner.sub) - 1}
		} else {
			if app.cur_msg < 0 || app.cur_msg >= len(c.msgs) do app.cur_msg = chat_append(c, .Assistant)
			ref = msg_append_block(c, app.cur_msg, block)
		}
		app.open[open_key(e.parent, e.index)] = ref

	case .Delta:
		ref, has := app.open[open_key(e.parent, e.index)]
		if !has do return
		b := chat_block(c, ref)
		if b != nil do strings.write_string(&b.text, e.text)

	case .Arg_Delta:
		ref, has := app.open[open_key(e.parent, e.index)]
		if !has do return
		b := chat_block(c, ref)
		if b == nil do return
		strings.write_string(&b.arg_json, e.text)
		delete(b.arg)
		b.arg = strings.clone(one_line(strings.to_string(b.arg_json), 200))

	case .Block_Stop:
		key := open_key(e.parent, e.index)
		ref, has := app.open[key]
		if has {
			if b := chat_block(c, ref); b != nil && b.kind != .Tool do b.running = false
			delete_key(&app.open, key)
		}

	case .Tool_Input:
		b := chat_block(c, chat_find_tool(c, e.id))
		if b == nil do return
		delete(b.arg)
		b.arg = strings.clone(e.text)

	case .Tool_Result:
		b := chat_block(c, chat_find_tool(c, e.id))
		if b == nil do return
		b.running = false
		strings.write_string(&b.result, e.text)

	case .Failed:
		m := chat_append(c, .System)
		ref := msg_append_block(c, m, Block{kind = .Error})
		strings.write_string(&chat_block(c, ref).text, e.text)
		app_status(app, "failed")

	case .Done:
		for &m in c.msgs {
			for &b in m.blocks {
				b.running = false
				for &s in b.sub do s.running = false
			}
		}
		clear(&app.open)
		app.cur_msg = -1
		app.cost = app.runner.cost
		app_status(app, "ready")
		app.rescan = true // the session file just changed; re-read the sidebar
	}
}

// --- formatting -------------------------------------------------------------

relative_time :: proc(t: time.Time, buf: []u8) -> string {
	secs := time.duration_seconds(time.since(t))
	switch {
	case secs < 60:
		return "now"
	case secs < 3600:
		return fmt.bprintf(buf, "%dm", int(secs / 60))
	case secs < 86400:
		return fmt.bprintf(buf, "%dh", int(secs / 3600))
	case secs < 86400 * 7:
		return fmt.bprintf(buf, "%dd", int(secs / 86400))
	}
	return fmt.bprintf(buf, "%dw", int(secs / (86400 * 7)))
}

// `/home/mike/Source/aithing` reads as `~/Source/aithing`, and a project slug
// is shown as just its last component.
short_path :: proc(path: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(path, home) {
		return fmt.tprintf("~%s", path[len(home):])
	}
	return path
}

base_name :: proc(path: string) -> string {
	if idx := strings.last_index_byte(path, '/'); idx >= 0 && idx + 1 < len(path) {
		return path[idx + 1:]
	}
	return path
}
