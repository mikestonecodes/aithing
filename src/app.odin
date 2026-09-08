package aithing

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The application: a sidebar of every session Claude Code has ever written, a
// transcript, and a composer. All state is plain data — the UI is rebuilt from
// it every frame — except the transcript itself, which grows as events arrive.

// Colours are packed the way the shader reads them: 0xAABBGGRR.
BG :: Color(0xc8242626)
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

CONTENT_MAX :: f32(880)

Focus :: enum {
	Composer,
	Search,
	Capture, // the box under the grid, where a todo list is typed
}

App :: struct {
	win:       Window,
	gpu:       Gpu,
	ui:        UI,

	sessions:  []Session,
	visible:   [dynamic]int, // the sessions the launcher offers, after the search
	archive:   Archive,
	selected:  int, // index into sessions; -1 while composing a new chat
	rescan:    bool,
	scan_at:   time.Time, // when the last scan was started: see the idle tick
	scan:      Scan_Job, // the sidebar, read on a worker thread
	load:      Load_Job, // the open transcript, parsed on a worker thread
	scanned:   bool, // false until the first scan lands
	// Clicks are recorded during the frame and acted on once it is over:
	// opening a session, or dropping a card, rebuilds the very lists the frame
	// is in the middle of walking. They name what was clicked by id rather
	// than by row, because a scan can land in that gap and renumber every row
	// — an index from last frame can point at a different session, or past the
	// end of a list that came back shorter.
	route_text: string, // the draft the manager last read: see manager.odin
	route_off:  bool, // ctrl n said this draft is its own thread
	pending_open:    string,
	// Cards the x was pressed on. Dismissing one mid-frame moves every index
	// after it in a list the grid is in the middle of walking, so the press is
	// recorded here and acted on once the frame is over.
	pending_dismiss: [dynamic;32]string,

	chat:      Chat,
	// Every turn in flight, one slot each: see turns.odin. A fixed array and
	// never compacted, because each running turn's reader thread holds a
	// pointer into its own slot.
	turns:     [MAX_TURNS]Turn,
	editor:    Editor,
	search:    Editor,
	capture:   Editor, // the box under the grid: what is typed there becomes cards
	focus:     Focus,

	attach:    [dynamic;8]Attachment,
	transcript: Scroll,
	sidebar:   Scroll,
	stick:     bool, // keep the transcript pinned to the bottom

	status:    string,
	model:     Model,
	model_open: bool, // the picker, open over the composer
	model_chip: Rect, // where it opens from
	cwd:       string, // where a new chat runs
	cur_msg:   int,
	// Messages typed into a thread while a turn was already running in it.
	// Two turns in one thread would be two `--resume`s of the same session
	// racing, so a follow-up waits here and goes out when the turn it was
	// typed over finishes.
	queue:       [dynamic;32]Pending,
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

	// The home view.
	canvas:    Canvas,
	groups:    Groups,
	layout_v:  int, // bumped whenever the set of nodes changes
	// The todos version app.todo_view was built from. Different means the
	// view indexes a list that has moved under it, and must be rebuilt.
	view_v:    int,

	// Why a batch failed, by batch. A card's turn is headless, so the message
	// the harness gave has nowhere else to go and used to be dropped on the
	// floor — leaving a card that said `failed` and nothing more.
	notes:     map[string]string,
	// The grid is todo items, not threads: see todos.odin. `todo_view` is
	// what the grid draws, in the order it draws it.
	todos:     Todos,
	todo_view: [dynamic]Card_Ref,
	// Cards asked to run, in the order they were asked for. Up to MAX_TURNS
	// of them go out at once, each in a thread of its own; the rest wait here.
	// Enter puts a card in it whether or not anything is running — one path,
	// so the key always does the same thing — and Esc empties it.
	run_queue: [dynamic;64]string,
	// An item names a message in its own thread, so opening one opens that
	// thread alone rather than every thread of its task end to end.
	open_single:  bool,
	// The last picture written to the state file, so a window sitting still
	// writes nothing: see state.odin.
	state_last: string,
	state_at:   time.Time,
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
	todos_load(&app.todos)
	groups_load(&app.groups)
	app.model = model_load()
	app.profile = os.get_env("AITHING_PROFILE", context.temp_allocator) != ""
	chat_new(app)
	app_rescan(app)
}

app_destroy :: proc(app: ^App) {
	// Before anything is torn down: what is on screen is written from the
	// live state, and a moment later none of it is live.
	state_save(app)
	turns_destroy(app)
	scan_destroy(&app.scan)
	load_destroy(&app.load)
	chat_destroy(&app.chat)
	editor_destroy(&app.editor)
	editor_destroy(&app.search)
	archive_save(&app.archive)
	archive_destroy(&app.archive)
	sessions_free(app.sessions)
	delete(app.visible)
	for &a in app.attach do attachment_destroy(&a)
	delete(app.open)
	delete(app.heights)
	delete(app.status)
	delete(app.route_text)
	delete(app.cwd)
	delete(app.pending_open)
	for &p in app.queue do pending_destroy(&p)
	editor_destroy(&app.capture)
	todos_save(&app.todos)
	todos_destroy(&app.todos)
	delete(app.todo_view)
	app_notes_destroy(app)
	for id in app.run_queue do delete(id)
	for id in app.pending_dismiss do delete(id)
	delete(app.state_last)
	groups_destroy(&app.groups)
	canvas_destroy(&app.canvas)
}

// Kicks off a rescan. Nothing blocks: the list is swapped in whenever the
// worker gets round to finishing.
app_rescan :: proc(app: ^App) {
	app.scan_at = time.now()
	scan_start(&app.scan)
}

// Called once a frame: takes whatever the workers have finished.
// Applies whatever the last frame's clicks asked for.
app_apply_clicks :: proc(app: ^App) -> bool {
	acted := app.pending_open != "" || len(app.pending_dismiss) > 0
	if len(app.pending_dismiss) > 0 {
		for id in app.pending_dismiss {
			app_drop_todo(app, id)
			delete(id)
		}
		clear(&app.pending_dismiss)
		todos_save(&app.todos)
		archive_save(&app.archive)
		app_filter(app)
	}
	if id := app.pending_open; id != "" {
		at := session_index(app, id)
		if at < 0 {
			// A thread this window made a moment ago, which the last scan
			// knew nothing about. The click is kept rather than dropped —
			// dropping it is why clicking a card that had just finished did
			// nothing at all — and a scan is asked for so the next frame can
			// honour it.
			app.rescan = true
		} else {
			delete(id)
			app.pending_open = ""
			app_open(app, at)
			app_filter(app) // an opened session belongs in the working list
		}
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
	// Slots whose process has gone and whose last event has been read go back
	// in the pool, and this is what frees both queues. Before them, not after:
	// a turn that dies without ever saying Done or Failed would otherwise
	// leave its card reading `processing` for good.
	if turns_reap(app) do changed = true
	// Every frame rather than off the Done event: a turn that dies without
	// finishing cleanly still frees the slot, and whatever was waiting on it
	// should go out either way.
	app_pump_queue(app)
	if app_pump_todos(app) do changed = true

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
		// The threads that arrived since the last scan are the only ones
		// without a task; the rest keep the one they were given.
		groups_assign(&app.groups, app.sessions)
		groups_save(&app.groups)
		app_filter(app)
		// Every thread on the map has a card, and the ones that have moved
		// since the agent last read them are queued to be read again.
		app_sync_todos(app)
		todos_save(&app.todos)
		app.chat_ver += 1
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

// The big menu, open or shut. Shutting it forgets what was typed, because the
// grid behind it is filtered by the same words and leaving them on would leave
// the grid narrowed by something no longer on screen.
app_launcher :: proc(app: ^App, open: bool) {
	app.canvas.launcher = open
	app.canvas.menu_at = 0
	app.focus = open ? .Search : .Composer
	if !open do editor_clear(&app.search)
	app_filter(app)
}

// The session list the launcher works from, and nothing else. The grid is not
// built out of this: it is built out of the cards, which are the state. That
// separation is the whole point — the rules that used to live here decided,
// every ten seconds and against the clock, which threads deserved a place,
// and the grid rearranged itself around the answer while you were looking at
// it.
app_filter :: proc(app: ^App) {
	app.layout_v += 1
	app.view_v = app.todos.ver
	clear(&app.visible)
	query := strings.to_lower(strings.trim_space(editor_text(&app.search)), context.temp_allocator)
	for s, i in app.sessions {
		if app.canvas.project != "" && s.cwd != app.canvas.project do continue
		if query != "" {
			// Searching looks everywhere: the archive and the abandoned
			// threads included. Something you go looking for by name is
			// something you want found, wherever it was filed.
			if !session_matches(s, query) do continue
		}
		append(&app.visible, i)
	}
	app_build_cards(app)
}

// How the grid is ordered, and it is worth saying plainly: by project, and
// within a project by the order the cards were made, newest first. Nothing in
// it is a clock or a file size, so a turn taken in another window cannot move
// a card, and a card put down keeps its place until it is dismissed or
// something is made above it.
//
// It used to be ordered by session mtime, so every turn anywhere reshuffled
// the whole grid, projects and all.
@(private = "file")
Card_Sort :: struct {
	cwd:  string,
	seq:  int,
	todo: int,
}

@(private = "file")
card_before :: proc(a, b: Card_Sort) -> bool {
	if a.cwd != b.cwd do return a.cwd < b.cwd
	return a.seq > b.seq
}

// The grid, in the order it is drawn.
//
// One pass over the cards and one sort — it used to be a loop over every
// visible thread with a loop over every card inside it, which on a machine
// with a few hundred of each is a few hundred thousand string joins several
// times a frame, and is why the window went slow enough that a key press took
// minutes to land.
//
// Which threads have cards at all is decided once, when a thread is first
// seen (see app_sync_todos). Nothing here can take a card away again: a grid
// that quietly drops what it was showing a minute ago is not a map of
// anything. A card leaves when it is dismissed, and that is the only way.
app_build_cards :: proc(app: ^App) {
	clear(&app.todo_view)
	query := strings.to_lower(strings.trim_space(editor_text(&app.search)), context.temp_allocator)

	rows := make([dynamic]Card_Sort, 0, len(app.todos.list), context.temp_allocator)
	for td, i in app.todos.list {
		if query != "" {
			if !todo_matches(td, query) do continue
		} else if app.canvas.project != "" && td.cwd != app.canvas.project {
			continue
		}
		append(&rows, Card_Sort{cwd = td.cwd, seq = todo_seq(td), todo = i})
	}
	slice.sort_by(rows[:], card_before)

	// The same piece of work is one card however many threads it took. Sorted
	// newest first, so the first to claim a wording is the newest one that
	// says it and the rest count towards it. A search is asking to be shown
	// everything by that name, folded or not, and a card nothing has started
	// is never folded into another — it is waiting on a person, which is not
	// something to hide behind a count.
	seen := make(map[string]int, context.temp_allocator)
	for row in rows {
		td := app.todos.list[row.todo]
		if query != "" || td.session == "" {
			append(&app.todo_view, Card_Ref{todo = row.todo, threads = 1})
			continue
		}
		key := strings.concatenate({td.cwd, todo_fold_key(td.text)}, context.temp_allocator)
		if k, has := seen[key]; has {
			app.todo_view[k].threads += 1
			continue
		}
		seen[key] = len(app.todo_view)
		append(&app.todo_view, Card_Ref{todo = row.todo, threads = 1})
	}
}

// Called when a scan lands, and all it does now is forget cards whose thread
// has gone.
//
// Nothing here puts a card on the grid. The grid is what you put on it: a
// card comes from the box under it and from nowhere else. This used to give
// every thread on the machine a card of its own and set an agent reading each
// one, which on a few hundred threads is a few hundred cards nobody asked
// for, arriving over the following minutes — and is what "random things
// popping up" was. See agent.odin for the two lines that turn it back on.
app_sync_todos :: proc(app: ^App) {
	// A thread that is no longer on disk takes its items with it. Anything
	// typed and never started stays: it is not about a thread yet.
	alive := make(map[string]bool, context.temp_allocator)
	for s in app.sessions do alive[s.id] = true
	for i := len(app.todos.list) - 1; i >= 0; i -= 1 {
		id := app.todos.list[i].session
		if id == "" || id in alive do continue
		// A turn is writing that thread right now, so of course the list does
		// not have it: it did not exist when the scan started.
		if turn_for_session(app, id) >= 0 do continue
		// And the same the other way round, for a turn that has since
		// finished: a scan already in flight when a card was given its thread
		// knows nothing about that thread, and dropping the card on the
		// strength of it is how one could vanish seconds after starting.
		if time.diff(app.todos.list[i].at, app.scan_at) < 0 do continue
		todos_remove(&app.todos, app.todos.list[i].id)
	}
}

// --- items -------------------------------------------------------------------

// Enter on a card, and a click on one. A card with a thread behind it opens
// that thread at the part it is about; a card nothing has started yet joins
// the run queue. One path either way, whether or not a turn is in flight:
// Enter always does the same thing and never has to be pressed twice.
app_open_todo :: proc(app: ^App, id: string) {
	at := todos_find(&app.todos, id)
	if at < 0 do return
	td := app.todos.list[at]
	if td.session == "" {
		app_queue_batch(app, td.batch)
		return
	}
	// A card with a turn of its own still running is already showing what that
	// turn is doing, right there on the card. Zooming the thread open over the
	// grid takes that away and puts a transcript in its place, which is not
	// what pressing Enter on a card that is plainly busy is asking for. The
	// launcher still opens any thread by name for anyone who does want to
	// read along.
	if turn_for_batch(app, td.batch) >= 0 {
		canvas_set_sel(app, id)
		return
	}
	canvas_set_sel(app, id) // the card, so the cursor is on it when you come back
	app.open_single = true
	canvas_open(app, td.session)
}

// --- the run queue -------------------------------------------------------------

// Lines a batch up to be run: one turn, one thread, and every card cut out of
// what was typed riding on it. Already running or already queued is not an
// error and not a second turn — it is simply already on its way.
app_queue_batch :: proc(app: ^App, batch: string) {
	if batch == "" do return
	if turn_for_batch(app, batch) >= 0 do return
	for q in app.run_queue do if q == batch do return
	if len(app.run_queue) == cap(app.run_queue) {
		app_status(app, "the queue is full")
		return
	}
	append(&app.run_queue, strings.clone(batch))
	app_note_clear(app, batch) // whatever went wrong last time is last time
	todos_batch_state(&app.todos, batch, .Queued)
	todos_save(&app.todos)
	app_filter(app)
}

// Takes a batch out of the queue, wherever it is in it. A batch whose last
// card was dismissed must not leave the queue holding a name with nothing
// behind it.
app_unqueue_batch :: proc(app: ^App, batch: string) {
	for q, i in app.run_queue {
		if q != batch do continue
		delete(q)
		ordered_remove(&app.run_queue, i)
		return
	}
}

// Where a batch is in the queue, counting from one, or 0 if it is not in it.
// Every card of a batch is in the same place, because they go out together.
todo_queue_pos :: proc(app: ^App, batch: string) -> int {
	for q, i in app.run_queue do if q == batch do return i + 1
	return 0
}

// Starts the next card, when there is a process free for it. Called once a
// frame: a turn ending — cleanly, in failure, or by dying without a word — is
// the only thing that makes room, and this is what notices.
//
// Cards that went away while they waited are stepped over rather than
// stopping the queue, which is why this loops.
app_pump_todos :: proc(app: ^App) -> bool {
	started := false
	for len(app.run_queue) > 0 && turn_slot(app) >= 0 {
		batch := strings.clone(app.run_queue[0], context.temp_allocator)
		was := len(app.run_queue)
		delete(app.run_queue[0])
		ordered_remove(&app.run_queue, 0)
		if app_start_batch(app, batch) {
			started = true
			continue
		}
		// It put itself back, so there is no room and nothing to gain by
		// going round again this frame.
		if len(app.run_queue) == was do break
	}
	return started
}

// One batch, run: a single new thread, in the batch's own project, with
// everything that was typed as the first thing said in it. The cards are what
// that text was cut into, not what it was cut up for — one list is one piece
// of work, and splitting it into four conversations would throw away
// everything each part knows about the others.
//
// Headless. Nothing here goes near the composer, the transcript or the panel:
// the draft in the composer belongs to whoever typed it, and several turns
// running would otherwise be several things fighting over one screen. The
// cards say `processing`, and clicking one opens the thread as soon as the
// harness has named it.
@(private = "file")
app_start_batch :: proc(app: ^App, batch: string) -> bool {
	// Rebuilt from the cards rather than remembered, so a card dismissed
	// while the batch waited for a slot is not asked for.
	parts := make([dynamic]string, context.temp_allocator)
	cwd := ""
	for at in todos_batch(&app.todos, batch) {
		td := app.todos.list[at]
		if td.session != "" do return false // it found a thread another way
		if td.text != "" do append(&parts, td.text)
		if cwd == "" do cwd = td.cwd
	}
	if len(parts) == 0 do return false // every card of it is gone
	if cwd == "" do cwd = app.cwd
	prompt := strings.join(parts[:], "\n", context.temp_allocator)

	if !turn_start(app, cwd, "", prompt, batch, false) {
		// Not a failure of the work: a slot or a pipe this window could not
		// get hold of just now, with three other turns holding theirs. Saying
		// `failed` on a card whose turn never ran — while the ones beside it
		// carry on — is a lie the grid used to tell. It goes back in the
		// queue and is tried again on the next frame.
		inject_at(&app.run_queue, 0, strings.clone(batch))
		app_status(app, "waiting for a free slot")
		return false
	}
	todos_batch_state(&app.todos, batch, .Running)
	todos_save(&app.todos)
	app_filter(app)
	return true
}

// Why a batch failed, kept until it is asked to run again. Not written down
// with the cards: it is about this attempt, not about the work.
app_note :: proc(app: ^App, batch, text: string) {
	if batch == "" do return
	line := strings.trim_space(one_line(text, 160))
	if line == "" do return
	if old, has := app.notes[batch]; has {
		delete(old)
		app.notes[batch] = strings.clone(line)
		return
	}
	app.notes[strings.clone(batch)] = strings.clone(line)
}

app_note_clear :: proc(app: ^App, batch: string) {
	if key, val := delete_key(&app.notes, batch); key != "" {
		delete(key)
		delete(val)
	}
}

app_notes_destroy :: proc(app: ^App) {
	for key, val in app.notes {
		delete(key)
		delete(val)
	}
	delete(app.notes)
}

// The turn a batch of cards was running has ended, one way or the other. One
// thread finishing is every card on it finishing: there was one turn.
app_batch_finished :: proc(app: ^App, batch: string, state: Todo_State) {
	if batch == "" do return
	todos_batch_state(&app.todos, batch, state)
	todos_save(&app.todos)
	app_filter(app)
}

// What a card says its work is doing. The store is the record and the process
// is the truth: the one card the runner is on is running, a card the queue is
// holding is queued, and a `running` left on disk by a quit or a crash is
// neither of those and reads as waiting again.
todo_display_state :: proc(app: ^App, td: Todo) -> Todo_State {
	if turn_for_batch(app, td.batch) >= 0 do return .Running
	if todo_queue_pos(app, td.batch) > 0 do return .Queued
	#partial switch td.state {
	case .Running:
		// A turn running in the card's own thread — one typed into the
		// composer, say — shows on the card as well.
		return app_session_busy(app, td.session) ? .Running : .Open
	case .Queued:
		// The queue is the only thing that queues, and it is not holding this.
		return .Open
	}
	return td.state
}

// --- dismissing ----------------------------------------------------------------

// The x on a card. Recorded now, acted on in app_apply_clicks once the frame
// drawing the grid is over: dropping an item mid-frame moves every index
// after it, which the canvas used to have to abandon a frame over.
app_dismiss_todo :: proc(app: ^App, id: string) {
	for q in app.pending_dismiss do if q == id do return
	append(&app.pending_dismiss, strings.clone(id))
}

// A card taken off the grid for good. Two things have to happen for it to
// stay off: the item is written down as dismissed, so that neither the stub
// nor the next agent read makes it again, and a thread that has just lost its
// last card is filed away, so the scan stops offering it one.
@(private = "file")
app_drop_todo :: proc(app: ^App, id: string) {
	at := todos_find(&app.todos, id)
	if at < 0 do return
	session := strings.clone(app.todos.list[at].session, context.temp_allocator)
	batch := strings.clone(app.todos.list[at].batch, context.temp_allocator)
	todos_dismiss(&app.todos, id)
	// Only when the last of them has gone: the others still want the turn.
	if len(todos_batch(&app.todos, batch)) == 0 {
		app_unqueue_batch(app, batch)
		// Taking the last card of a piece of work off the grid is saying you
		// are done with it, so the turn running it stops. This is the way to
		// stop one from the grid, and it is deliberate — which is the whole
		// difference between it and what Esc used to do.
		if at := turn_for_batch(app, batch); at >= 0 do turn_stop(app, at)
	}
	if session != "" && !todos_has(&app.todos, session) {
		archive_set(&app.archive, session, true)
	}
}

// --- typing a list ---------------------------------------------------------------

// Everything typed into the box under the grid: one thread, and a card for
// each of the things said in it.
//
// The split is what the grid is made of, not what the work is cut into. A
// list someone types in one go is one piece of work said in several
// sentences — the second line is usually about the first — so it goes out as
// one prompt to one thread, the way it would if it had been typed into a
// composer. The cards are how it reads back on the grid afterwards, and they
// all point at that one thread.
app_capture :: proc(app: ^App) {
	text := strings.trim_space(editor_text(&app.capture))
	if text == "" do return
	// The project the grid is narrowed to, else the one last worked in.
	cwd := app.canvas.project != "" ? app.canvas.project : app.cwd
	parts := todos_split(text)
	if len(parts) == 0 do return

	// The first card names the batch, and the rest join it.
	batch := todos_add(&app.todos, parts[0], "", cwd)
	for part in parts[1:] do todos_add(&app.todos, part, "", cwd, batch = batch)
	editor_clear(&app.capture)
	todos_save(&app.todos)
	canvas_set_sel(app, batch)
	app_queue_batch(app, batch)
	note := len(parts) == 1 ? "running it" : fmt.tprintf("%d cards — one thread", len(parts))
	app_status(app, note)
}

// Everything a thread can be found by: what it is called, what was asked of
// it, where it lives, and what it looks like it is about.
session_matches :: proc(s: Session, query: string) -> bool {
	title := strings.to_lower(s.title, context.temp_allocator)
	preview := strings.to_lower(s.preview, context.temp_allocator)
	project := strings.to_lower(s.project, context.temp_allocator)
	cwd := strings.to_lower(s.cwd, context.temp_allocator)
	return strings.contains(title, query) ||
		strings.contains(preview, query) ||
		strings.contains(project, query) ||
		strings.contains(cwd, query) ||
		(s.guess != "" && strings.contains(s.guess, query))
}

// Esc, wherever it is pressed. Backs out of exactly one thing, and the order
// is the order they were put in front of you: the launcher, the model picker,
// a turn running in the thread on screen, that thread, whatever is half-typed
// in the box. And then nothing: a press that finds nothing to back out of
// does nothing at all.
//
// Esc stops no work of any kind. It used to fall through to stopping every
// turn in flight, and a kill makes `claude` exit non-zero, which arrives as a
// failure — so four cards went red at once because Esc was pressed on a grid
// that had nothing else to give up, and nothing on screen said why. Stopping
// is ctrl c, which is only ever about one thing and is never pressed by
// somebody trying to close a panel.
//
// The project the grid is narrowed to is not in that list. Narrowing to one
// is a thing you said, not a thing that happened to you, and Esc undoing it
// meant every press that missed everything else dumped you back out of the
// project you were working in. The launcher offers a row that widens it
// again, which is where the choice was made in the first place.
//
// Returns whether the search text changed, which the grid is filtered by.
app_cancel :: proc(app: ^App) -> bool {
	switch {
	case app.canvas.launcher:
		app_launcher(app, false)
		return true

	case app.model_open:
		app.model_open = false

	case app.canvas.opened && app.focus != .Search:
		canvas_close(app)

	case app.focus == .Search:
		editor_clear(&app.search)
		app.focus = .Composer
		return true

	case app.focus == .Capture && editor_text(&app.capture) != "":
		editor_clear(&app.capture)

	}
	return false
}

// Only records what was clicked; app_apply_clicks acts on it once the frame
// that is walking the grid is over.
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
	turns_rebind(app)
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
	// Where new work goes from now on. Opening a thread is saying which
	// project you are in, and a card typed afterwards belongs to that project
	// — it used to go to whatever directory the window was launched from, so
	// work written down while reading one project landed in another.
	if s.cwd != "" && s.cwd != app.cwd {
		delete(app.cwd)
		app.cwd = strings.clone(s.cwd)
	}
	app.selected = index
	app.cur_msg = -1
	app.stick = true
	app.chat_ver += 1
	app.transcript.offset = 0
	app.transcript.target = 0
	turns_rebind(app)
	app_status(app, "loading...")

	// A card stands for a task, so opening it opens the task: every thread of
	// it, end to end, as one conversation. Only from the card, which is the
	// newest thread of its group — asking for an older thread by name, from
	// the search or from inside an opened group, opens that thread alone.
	members := make([dynamic]Session, context.temp_allocator)
	single := app.open_single
	app.open_single = false
	if !single {
		key := group_of(&app.groups, s^)
		newest := true
		for other, j in app.sessions {
			if j >= index do break // sessions are newest first
			if group_of(&app.groups, other) == key do newest = false
		}
		if newest {
			for j := len(app.sessions) - 1; j >= 0; j -= 1 {
				if group_of(&app.groups, app.sessions[j]) == key do append(&members, app.sessions[j])
			}
		}
	}
	load_start_group(&app.load, s^, members[:])
}

app_status :: proc(app: ^App, msg: string) {
	delete(app.status)
	app.status = strings.clone(msg)
}

// --- sending ----------------------------------------------------------------

// The composer: what was typed goes out, and the box empties.
app_send :: proc(app: ^App) {
	typed := strings.trim_space(editor_text(&app.editor))
	if typed == "" && len(app.attach) == 0 do return
	// Copied off the editor before it is cleared: what editor_text hands back
	// points into the buffer the clear is about to reset.
	text := strings.clone(typed, context.temp_allocator)
	prompt := attachments_prompt(text, app.attach[:], context.temp_allocator)
	editor_clear(&app.editor)
	_ = app_submit(app, text, prompt)
}

// The one way a message leaves this window, whether a person typed it or a
// card asked for it. `text` is what the transcript shows and `prompt` what
// the harness is given; they differ only when there are attachments.
//
// False means nothing went out: an empty prompt, or a harness that would not
// start. A message that only got as far as the queue behind a running turn
// counts as sent — it is in the transcript and it will go.
app_submit :: proc(app: ^App, text, prompt: string) -> bool {
	if strings.trim_space(prompt) == "" do return false

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
	route_clear(app)

	// A turn is already running in this thread, or every slot is taken: the
	// message is already in the transcript where it was typed, so all that is
	// left is to remember to send it. Dropping it here — which is what used to
	// happen — looked exactly like a broken Enter key.
	waiting := app_chat_busy(app) || app_session_busy(app, app.chat.session_id) || turn_slot(app) < 0
	if waiting {
		if len(app.queue) == cap(app.queue) {
			// Never fall through to starting one: a second `--resume` of a
			// thread that already has a turn in it is two processes writing
			// one session file.
			app_status(app, "too many messages waiting")
			return false
		}
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
		return true
	}

	// The composer's turn is the one that draws into the transcript.
	if !turn_start(app, cwd, app.chat.session_id, prompt, "", true) {
		app_status(app, "could not start claude")
		return false
	}
	app.cur_msg = -1
	app.stick = true
	app_status(app, "thinking...")
	return true
}

// Sends the next message that was typed over a running turn. Called when one
// finishes, which is the only time there is a process free to run it.
app_pump_queue :: proc(app: ^App) {
	if len(app.queue) == 0 || turn_slot(app) < 0 do return
	// Only the head, and only when its own thread is free: messages typed into
	// one thread have to reach it in the order they were typed.
	session := app.queue[0].session
	if session == "" {
		// Queued against a chat the harness had not named yet. It belongs to
		// whichever id came back for the turn it was typed over, so it waits
		// for that turn to be over and for the chat to have picked the id up.
		if turn_chat(app) >= 0 do return
		session = app.chat.session_id
	}
	if app_session_busy(app, session) do return

	p := app.queue[0]
	ordered_remove(&app.queue, 0)
	defer pending_destroy(&p)

	// It is going out now, so it stops being drawn as waiting — unless the
	// reader has moved to another session, in which case that transcript is
	// gone and there is nothing to unmark.
	if p.session == app.chat.session_id && p.msg >= 0 && p.msg < len(app.chat.msgs) {
		app.chat.msgs[p.msg].queued = false
		app.chat_ver += 1
	}
	// It draws into the transcript when the thread it is for is the one on
	// screen, which is the usual case and not the only one.
	if !turn_start(app, p.cwd, session, p.prompt, "", session == app.chat.session_id) {
		app_status(app, "could not start claude")
		return
	}
	app.cur_msg = -1
	app_status(app, "thinking...")
}

// Everything lined up behind a turn that is being stopped. Stopping one
// should not be followed by the next thing starting on its own, whichever of
// the two it would have been.
app_queue_clear :: proc(app: ^App) {
	app_queue_clear_messages(app)
	app_run_queue_clear(app)
}

// The follow-ups typed into the composer. They stop claiming they are about
// to go out, because they are not.
app_queue_clear_messages :: proc(app: ^App) {
	if len(app.queue) == 0 do return
	for &p in app.queue {
		if p.session == app.chat.session_id && p.msg >= 0 && p.msg < len(app.chat.msgs) {
			app.chat.msgs[p.msg].queued = false
		}
		pending_destroy(&p)
	}
	app.chat_ver += 1
	clear(&app.queue)
}

// The cards waiting for a slot, put back to waiting. Turns already in flight
// are not touched: stopping those is turns_stop_all.
app_run_queue_clear :: proc(app: ^App) {
	if len(app.run_queue) == 0 do return
	for batch in app.run_queue {
		todos_batch_state(&app.todos, batch, .Open)
		delete(batch)
	}
	clear(&app.run_queue)
	todos_save(&app.todos)
	app_filter(app)
}

// --- applying what the runner streams ---------------------------------------

@(private = "file")
open_key :: proc(parent: string, index: int) -> u64 {
	return ui_id(parent, index + 1)
}

app_apply_events :: proc(app: ^App) -> bool {
	changed := false
	for &t, at in app.turns {
		if !t.live do continue
		events := runner_drain(&t.runner, context.temp_allocator)
		if len(events) == 0 do continue
		for &e in events {
			app_apply(app, at, &e)
			event_destroy(&e)
		}
		changed = true
	}
	return changed
}

// The event path, reachable from a test: what a turn coming back looks like.
app_apply_event_for_test :: proc(app: ^App, at: int, e: ^Event) {
	app_apply(app, at, e)
}

// One event, from one turn. Every turn is tracked — the thread it was given,
// and whether it finished — but only the one drawing into the transcript on
// screen has anywhere to put its text, which is what a card's headless turn
// does not.
@(private = "file")
app_apply :: proc(app: ^App, at: int, e: ^Event) {
	c := &app.chat
	t := &app.turns[at]
	turn_note(t, e)

	// The harness names the thread in the first record it writes, and that is
	// what everything else about this turn hangs off.
	if e.kind == .Session && e.id != "" && t.session != e.id {
		delete(t.session)
		t.session = strings.clone(e.id)
		if t.batch != "" do todos_batch_session(&app.todos, t.batch, e.id, t.cwd)
		if t.chat && c.session_id != e.id {
			delete(c.session_id)
			c.session_id = strings.clone(e.id)
		}
	}

	if !t.chat || (t.session != "" && t.session != c.session_id) {
		#partial switch e.kind {
		case .Failed:
			if t.stopped {
				// Killed by hand a moment ago. The non-zero exit that follows
				// is us, not the work.
				app_note(app, t.batch, "stopped")
				app_turn_ended(app, t, .Open)
				break
			}
			// Headless, so there is no transcript for this to go in. It goes
			// on the card instead, which is the only thing anyone can see.
			app_note(app, t.batch, e.text)
			app_status(app, e.text != "" ? e.text : "a turn failed")
			app_turn_ended(app, t, .Failed)
		case .Done:
			app_turn_ended(app, t, .Done)
		}
		return
	}
	app.chat_ver += 1

	switch e.kind {
	case .Session:
		// Taken above: the id has to be picked up whether or not anyone is
		// looking at the thread it names.

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
		app_turn_ended(app, t, .Failed)
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
		app_turn_ended(app, t, .Done)
		app_status(app, "ready")
	}
}

// A turn is over. Its card is marked, the sidebar is re-read because the
// session file has just changed, and a turn that changed this window rebuilds
// it — the new binary takes the process over a few seconds later.
@(private = "file")
app_turn_ended :: proc(app: ^App, t: ^Turn, state: Todo_State) {
	if t.ended do return // Failed then Done is one ending, and the first wins
	t.ended = true
	app.cost = t.runner.cost
	app_batch_finished(app, t.batch, state)
	app.rescan = true
	reload_build(app, t.cwd)
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

base_name :: proc(path: string) -> string {
	if idx := strings.last_index_byte(path, '/'); idx >= 0 && idx + 1 < len(path) {
		return path[idx + 1:]
	}
	return path
}
