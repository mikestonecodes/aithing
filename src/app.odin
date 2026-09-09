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
AMBER :: Color(0xff5ac0e0)

CONTENT_MAX :: f32(880)

// What is on screen. One variable says it, every frame reads it, and a click
// changes it — there is no second copy to fall out of step with the first.
// It used to be four booleans that had to agree (a thread open, the launcher
// up, the picker down, and where the caret was), kept in step by hand at six
// call sites, and every disagreement between them was a bug you could see.
Page :: enum {
	Grid, // the map of cards
	Thread, // one thread, zoomed open over it
}

// What is over the page. Orthogonal to it: the launcher and the picker are
// each shut by going back to the page underneath, whichever it is, so neither
// has to remember where it came from.
Overlay :: enum {
	None,
	Launcher, // the big menu
	Model, // the picker, over the composer
	Effort, // how hard it thinks, in the picker beside it
}

Focus :: enum {
	None, // a grid of every project: there is nothing on it to type into
	Composer,
	Search,
	Capture, // the box under the grid, where a todo list is typed
}

// Where the caret is: not a thing anyone sets, a thing the page already
// decides. The launcher's query while it is up, the composer inside a thread,
// the box under the grid while the grid is narrowed to one project — and
// nowhere at all when it is not.
//
// Nowhere is a real answer, and it is the one a grid of every project gets. A
// card typed there has no project to belong to, and both ways round that have
// now been tried and thrown out: taking the answer from the last thread
// worked in sent a task written while reading one project quietly into
// another, and printing the answer over the box asked the writer to read a
// line above the caret before every list they wrote. Narrowing the grid is
// how you say where work goes, and the box is there exactly when you have
// said it.
app_focus :: proc(app: ^App) -> Focus {
	if app.overlay == .Launcher do return .Search
	if app.page == .Thread do return .Composer
	if app_capture_open(app) do return .Capture
	return .None
}

// Whether the box under the grid is there at all. The layout asks it to keep
// room clear and the draw asks it before drawing anything, and app_focus is
// the same answer — one question, so the box and the caret cannot disagree
// about whether you can type. It does not ask about the launcher: the menu
// goes over the grid without changing what the grid is, and a box that
// vanished under it would move the cards while they are being read.
app_capture_open :: proc(app: ^App) -> bool {
	return app.page == .Grid && app.canvas.project != ""
}

App :: struct {
	win:       Window,
	gpu:       Gpu,
	ui:        UI,

	sessions:  []Session,
	visible:   [dynamic]int, // the sessions the launcher offers, after the search
	archive:   Archive,
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
	// Cards whose work would not go back into the project on its own, waiting
	// for an agent to be put in the tree to settle it. Recorded rather than
	// started where it is decided: that is inside the walk over app.turns, and
	// taking a slot can grow the list the walk is holding a pointer into.
	pending_resolve: [dynamic;32]string,

	chat:      Chat,
	// Every turn in flight, one slot each: see turns.odin. Grown as far as the
	// work asks for and never compacted, because each running turn's reader
	// thread holds a pointer into its own slot.
	turns:     [dynamic]^Turn,
	// Not a turn: the one `claude -p` this window starts for itself, to ask
	// what is left of the plan without waiting for somebody to run a card.
	// See usage.odin.
	probe:     Runner,
	editor:    Editor,
	search:    Editor,
	capture:   Editor, // the box under the grid: what is typed there becomes cards
	page:      Page,
	overlay:   Overlay,

	attach:    [dynamic;8]Attachment,
	transcript: Scroll,
	sidebar:   Scroll,
	stick:     bool, // keep the transcript pinned to the bottom

	status:    string,
	model:     Model,
	model_chip: Rect, // where it opens from
	effort:    Effort,
	effort_chip: Rect,
	cwd:       string, // where a new chat runs
	cur_msg:   int,
	// The transcript's tiles: scratch, not state. snake_gather rebuilds the
	// whole path from the chat every frame — placing a tile is one font
	// measurement of one short line, and the two expensive layouts (the
	// answer, and whichever tile is open) cache on the block itself. A list
	// kept between frames would be a second copy of a chat that grows a block
	// at a time mid-stream, and every index in it a bounds trap the moment it
	// did.
	snake:     [dynamic]Tile,
	open:      map[u64]Ref, // stream content-block index -> where it landed
	// What the harness has cost, by day: see usage.odin.
	usage:     Ledger,
	profile:   bool,

	// The home view.
	canvas:    Canvas,
	groups:    Groups,

	// Why a card failed, by card. A card's turn is headless, so the message
	// the harness gave has nowhere else to go and used to be dropped on the
	// floor — leaving a card that said `failed` and nothing more.
	notes:     map[string]string,
	// The grid is todo items, not threads: see todos.odin. `todo_view` is
	// what the grid draws, in the order it draws it.
	todos:     Todos,
	todo_view: [dynamic]int,
	// How far back through what has already been typed into the box under the
	// grid it is showing: 0 is whatever is being written now, 1 the last thing
	// written, and so on. There is no list beside it — the cards in the order
	// they were made are the history — so nothing can drift out of step with
	// what is actually on the grid.
	history_at: int,
	// What was half-written when the walk stepped off 0, so coming back down
	// to 0 gives it back. Up used to throw it away — you typed a line, went
	// looking for an older one to copy a word out of, and the line you were
	// writing was gone with no key that brought it back.
	history_draft: string,
	// An item names a message in its own thread, so opening one opens that
	// thread alone rather than every thread of its task end to end.
	open_single:  bool,
	// The last picture written to the state file, so a window sitting still
	// writes nothing: see state.odin.
	state_last: string,
	state_at:   time.Time,
}

app_init :: proc(app: ^App) {
	app.stick = true
	cwd, _ := os.get_working_directory(context.allocator)
	app.cwd = cwd
	app.status = strings.clone("ready")
	archive_load(&app.archive)
	todos_load(&app.todos)
	// Every tree left behind by a card that is finished or gone, before
	// anything can start running in one.
	worktree_sweep(&app.todos)
	groups_load(&app.groups)
	usage_load(&app.usage)
	// The saved reading is last week's until something says otherwise, so the
	// window asks on the way up rather than standing there empty.
	probe_start(app)
	app.model = model_load()
	app.effort = effort_load()
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
	runner_destroy(&app.probe)
	// Nothing to save on the way out: a reading is written the moment it
	// lands, which is the only moment there is anything new to write.
	usage_destroy(&app.usage)
	sessions_free(app.sessions)
	delete(app.visible)
	for &a in app.attach do attachment_destroy(&a)
	delete(app.open)
	delete(app.snake)
	delete(app.status)
	delete(app.route_text)
	delete(app.cwd)
	delete(app.pending_open)
	editor_destroy(&app.capture)
	todos_save(&app.todos)
	todos_destroy(&app.todos)
	delete(app.todo_view)
	app_notes_destroy(app)
	for id in app.pending_dismiss do delete(id)
	for id in app.pending_resolve do delete(id)
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
	acted := app.pending_open != "" || len(app.pending_dismiss) > 0 || len(app.pending_resolve) > 0
	for id in app.pending_resolve {
		app_start_resolve(app, id)
		delete(id)
	}
	clear(&app.pending_resolve)
	if len(app.pending_dismiss) > 0 {
		for id in app.pending_dismiss {
			app_drop_todo(app, id)
			delete(id)
		}
		clear(&app.pending_dismiss)
		todos_save(&app.todos)
		archive_save(&app.archive)
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
	// in the pool. Before the rest of this: a turn that dies without ever
	// saying Done or Failed would otherwise leave its card reading
	// `processing` for good.
	if turns_reap(app) do changed = true

	if list, ok := scan_take(&app.scan); ok {
		// The thread on screen is the one app.chat names, and nothing else
		// records it. There used to be an index into this list beside it,
		// carried across every rescan by hand — a list that had just been
		// swapped out under it, which is the whole reason the index kept
		// having to be found again.
		sessions_free(app.sessions)
		app.sessions = list
		app.scanned = true
		// The threads that arrived since the last scan are the only ones
		// without a task; the rest keep the one they were given.
		groups_assign(&app.groups, app.sessions)
		groups_save(&app.groups)
		// Every thread on the map has a card, and the ones that have moved
		// since the agent last read them are queued to be read again.
		app_sync_todos(app)
		todos_save(&app.todos)
		changed = true
	}

	if chat, ok := load_take(&app.load); ok {
		chat := chat
		chat_destroy(&app.chat)
		clear(&app.open)
		app.chat = chat
		app.cur_msg = -1
		app.stick = true
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
	app.overlay = open ? .Launcher : .None
	app.canvas.menu_at = 0
	if !open do editor_clear(&app.search)
}

// Which project you are in, and so where work typed now belongs: the thread
// you have open, the project the grid is narrowed to, or the one last worked
// in. Four call sites used to answer this themselves, in four slightly
// different orders, and the card that went into the wrong project was the
// only thing that ever said they disagreed.
// A card's thread runs in the card's own worktree, so the answer has to be
// read back through it: the project is what the tree was cut from, and work
// written down while reading a card used to be filed under a path in the
// cache that nothing else on the grid shared.
app_project :: proc(app: ^App) -> string {
	if app.page == .Thread && app.chat.cwd != "" do return worktree_project(app, app.chat.cwd)
	if app.canvas.project != "" do return app.canvas.project
	return app.cwd
}

// Where the thread on screen runs. A thread that has not been given one yet
// runs where the window is.
app_chat_cwd :: proc(app: ^App) -> string {
	return app.chat.cwd != "" ? app.chat.cwd : app.cwd
}

// What the thread on screen is called. The scan is what learns this — the
// harness writes a title a moment after the first turn — so it is read off
// the session list rather than copied onto the chat every time one lands.
app_chat_title :: proc(app: ^App) -> string {
	if at := session_index(app, app.chat.session_id); at >= 0 && app.sessions[at].title != "" {
		return app.sessions[at].title
	}
	// A thread this window has just made is not in the scan yet — the harness
	// writes a title only once there is something to write one from — and the
	// card that asked for it says what the work is meanwhile.
	if app.chat.session_id != "" {
		for td in app.todos.list do if td.session == app.chat.session_id do return td.text
	}
	return app.chat.title
}

// The session list the launcher works from, and nothing else. The grid is not
// built out of this: it is built out of the cards, which are the state. That
// separation is the whole point — the rules that used to live here decided,
// every ten seconds and against the clock, which threads deserved a place,
// and the grid rearranged itself around the answer while you were looking at
// it.
// The sessions the launcher offers, as they are now. Every reader goes
// through here, so there is no moment where the list on screen is older than
// the cards it was built from.
app_visible :: proc(app: ^App) -> []int {
	app_filter(app)
	return app.visible[:]
}

// Rebuilds the two lists the screen is made of, from the cards and the
// sessions, as they are right now. Nothing invalidates it and nothing has to
// remember to call it: it runs from canvas_layout, which every reader of
// either list goes through first. It used to be called by hand from a dozen
// places, guarded by two version counters, and the places that forgot are
// where the grid drew a card that was no longer there.
app_filter :: proc(app: ^App) {
	clear(&app.visible)
	query := strings.trim_space(editor_text(&app.search))
	// Worked out once for the whole sweep, not once per session: see
	// worktree_root.
	root := worktree_root()
	for s, i in app.sessions {
		// A card's own tree is not a place you browse to. Threads that ran in
		// one filled the launcher with a project per card ever run —
		// `aithing-n-12`, `aithing-n-13` — every one of them the same project
		// wearing a card's id, and half of them directories that have since
		// been given back. The card on the grid is the door to that thread,
		// and it is the only one that stays true.
		if worktree_card_under(root, s.cwd) != "" do continue
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
	query := strings.trim_space(editor_text(&app.search))

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

	for row in rows do append(&app.todo_view, row.todo)
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
// that thread at the part it is about; a card nothing has started yet is
// started, now. One path either way, whether or not anything else is in
// flight: Enter always does the same thing and never has to be pressed twice.
app_open_todo :: proc(app: ^App, id: string) {
	at := todos_find(&app.todos, id)
	if at < 0 do return
	td := app.todos.list[at]
	if td.session == "" {
		app_start_todo(app, td.id)
		return
	}
	// A running turn is no reason to refuse. A card that is busy is exactly
	// the card you want to read along with, and the click used to be swallowed
	// by a special case that only selected it — one press, one meaning, in
	// every state the card can be in.
	canvas_set_sel(app, id) // the card, so the cursor is on it when you come back
	app.open_single = true
	canvas_open(app, td.session)
}

// --- starting one ---------------------------------------------------------------

// One card, run: a new thread of its own, in the card's project, with the
// card's own wording as the first thing said in it. A card is a conversation,
// so there is nothing else in the prompt — a list typed in one go used to be
// glued back together into one prompt on one thread, and then nothing about
// that thread could be read, stopped or dismissed a card at a time.
//
// Every card asked for goes out the moment it is asked for. There was a queue
// here, four slots wide, and cards sat in it saying `queued` — which is a
// card telling you its work is not being done while the machine is idle. The
// four unrelated threads it was rationing were never the scarce thing.
//
// Headless. Nothing here goes near the composer, the transcript or the panel:
// the draft in the composer belongs to whoever typed it, and several turns
// running would otherwise be several things fighting over one screen. The
// card says `processing`, and clicking it opens the thread as soon as the
// harness has named it.
//
// Asking twice is not two turns: a card already running is already on its way.
app_start_todo :: proc(app: ^App, id: string) {
	if id == "" do return
	if turn_for_todo(app, id) >= 0 do return
	// Read out of the store rather than taken on trust, so a card that has
	// since been dismissed is not asked for.
	at := todos_find(&app.todos, id)
	if at < 0 do return
	td := app.todos.list[at]
	if td.session != "" do return // it found a thread another way
	if td.text == "" do return
	project := td.cwd != "" ? td.cwd : app.cwd

	app_note_clear(app, id) // whatever went wrong last time is last time
	// Its own checkout, so that four cards running at once are four working
	// trees and not four agents editing one. A project git knows nothing
	// about runs where it always ran.
	cwd, why := worktree_for(project, id, context.temp_allocator)
	if why != "" do app_note(app, id, why)
	// With the preamble on the front: a headless turn is the one nobody is
	// reading, so it is the one that has to say whether it finished.
	if !turn_start(app, cwd, project, "", verdict_preamble(td.text), id, false) {
		// Not a failure of the work — a pipe or a process this window could
		// not get hold of just now — but it is a failure of the asking, and
		// the card has to say so. It used to be left exactly as it was, which
		// on a card nobody had run before is `waiting`: you asked for it, the
		// status line said something for a second, and the grid went on
		// showing a card that looked like one you had never touched. Failed
		// with the reason on it, and Enter asks again.
		app_note(app, id, "could not start claude")
		app_todo_finished(app, id, .Failed)
		app_status(app, "could not start claude")
		return
	}
	// Nothing to write down: the turn now in flight is what says this card is
	// running, and it says so until it ends.
}

// Why a card failed, kept until it is asked to run again. Not written down
// with the card: it is about this attempt, not about the work.
app_note :: proc(app: ^App, id, text: string) {
	if id == "" do return
	line := strings.trim_space(one_line(text, 160))
	if line == "" do return
	if old, has := app.notes[id]; has {
		delete(old)
		app.notes[id] = strings.clone(line)
		return
	}
	app.notes[strings.clone(id)] = strings.clone(line)
}

app_note_clear :: proc(app: ^App, id: string) {
	if key, val := delete_key(&app.notes, id); key != "" {
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

// The turn a card was running has ended, one way or the other.
app_todo_finished :: proc(app: ^App, id: string, state: Todo_State) {
	if id == "" do return
	todo_set_state(&app.todos, id, state)
	todos_save(&app.todos)
}

// What a card says its work is doing. The store is the record and the process
// is the truth: a card a turn is on is running, and a `running` left on disk
// by a quit or a crash is not that and reads as waiting again.
todo_display_state :: proc(app: ^App, td: Todo) -> Todo_State {
	// A turn on this card, or a turn in the card's own thread — one typed
	// into the composer, say — both show on the card as running.
	if turn_for_todo(app, td.id) >= 0 do return .Running
	if td.session != "" && app_session_busy(app, td.session) do return .Running
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
	todos_dismiss(&app.todos, id)
	// Taking a card off the grid is saying you are done with it, so the turn
	// running it stops. This is the way to stop one from the grid, and it is
	// deliberate — which is the whole difference between it and what Esc used
	// to do.
	if at := turn_for_todo(app, id); at >= 0 do turn_stop(app, at)
	if session != "" && !todos_has(&app.todos, session) {
		archive_set(&app.archive, session, true)
	}
}

// --- typing a list ---------------------------------------------------------------

// Everything typed into the box under the grid: a card for each of the things
// said in it, and a thread each.
//
// Where one item stops and the next begins is a `*` and nothing else, so a
// job written out at length is one card. Each part is its own conversation,
// so a card can be opened, stopped and dismissed without dragging the ones
// typed beside it along: they used to share one thread, and sharing it was
// what made every one of those a special case.
app_capture :: proc(app: ^App) {
	text := strings.trim_space(editor_text(&app.capture))
	if text == "" do return
	cwd := app_project(app)
	parts := todos_split(text)
	if len(parts) == 0 do return

	first := ""
	for part in parts {
		id := todos_add(&app.todos, part, "", cwd)
		if first == "" do first = id
		app_start_todo(app, id)
	}
	editor_clear(&app.capture)
	app_history_done(app)
	todos_save(&app.todos)
	canvas_set_sel(app, first)
}

// --- what was typed before ----------------------------------------------------

// Up and down in the box under the grid walk back through what has already
// been written there, the way a shell does it. What was typed is what became a
// card, so the cards are the history and there is no second list to keep — the
// only thing written down is how far back through them the box is showing.
//
// The arrows used to move the keyboard cursor between cards instead, so the
// commonest thing anyone wants from a box — the line typed a minute ago, again
// — could not be had at all. The cards keep left and right.
app_history :: proc(app: ^App, back: int) -> bool {
	// Asked from the grid's arrow keys, which are there whether or not the
	// box is: on a grid of every project there is nothing to type into, and
	// walking a history into a box nobody can see is the second copy this
	// whole arrangement exists to avoid.
	if !app_capture_open(app) do return false
	n := len(app.todos.list)
	if n == 0 do return false
	at := clamp(app.history_at + back, 0, n)
	if at == app.history_at do return false
	// Stepping off what is being written now puts it aside; 0 is where it
	// lives, so walking back down to 0 hands it back rather than clearing the
	// box. Anything typed once the walk is under way is a new draft and takes
	// its place: see app_history_done.
	if app.history_at == 0 {
		delete(app.history_draft)
		app.history_draft = strings.clone(editor_text(&app.capture))
	}
	app.history_at = at
	if at == 0 {
		editor_set_text(&app.capture, app.history_draft)
		return true
	}
	// The list is oldest first, so one step back is one off the end.
	editor_set_text(&app.capture, app.todos.list[n - at].text)
	return true
}

// The walk is over: the box is somebody's own writing again, so the next Up
// starts from the newest card and there is no draft left to come back to.
// Said in one place because the four callers that used to set `history_at` by
// hand are exactly the kind of second copy that leaves a stale draft waiting
// to overwrite a box.
app_history_done :: proc(app: ^App) {
	app.history_at = 0
	delete(app.history_draft)
	app.history_draft = ""
}

// Everything a thread can be found by: what it is called, what was asked of
// it, where it lives, and what it looks like it is about.
session_matches :: proc(s: Session, query: string) -> bool {
	return contains_fold(s.title, query) ||
		contains_fold(s.preview, query) ||
		contains_fold(s.project, query) ||
		contains_fold(s.cwd, query) ||
		contains_fold(s.guess, query)
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
// The project the grid is narrowed to is last in that list, and only there:
// Esc gives up the launcher, the picker, the open thread and what is
// half-typed before it will widen the grid. A press that has nothing else
// left to back out of is somebody asking to see everything again, and having
// no key for it at all meant the only way out of a project was to know that
// the launcher had a row for it.
//
// Returns whether the search text changed, which the grid is filtered by.
app_cancel :: proc(app: ^App) -> bool {
	switch {
	case app.overlay == .Launcher:
		app_launcher(app, false)
		return true

	case app.overlay == .Model || app.overlay == .Effort:
		app.overlay = .None

	case app.page == .Thread:
		canvas_close(app)

	// Only what is on screen counts as something to back out of. A state
	// file written by an older build can restore text into the box while the
	// grid is showing every project, and a press that quietly cleared a box
	// nobody can see is a press that looked like it did nothing.
	case app_capture_open(app) && editor_text(&app.capture) != "":
		editor_clear(&app.capture)
		app_history_done(app)

	case app.canvas.project != "":
		canvas_filter_project(app, "")

	}
	return false
}

// Walking whichever picker is open, from the keyboard. There is no pending
// selection kept beside the value while you walk: the row the caret is on is
// the choice, made and saved as you land on it, because a "highlighted row"
// remembered next to the model itself is a second copy of the same question —
// and it would be the copy left behind when the picker is shut by a click
// somewhere else entirely.
//
// It does not wrap. Ctrl m and ctrl e cycle, which is what wrapping is for;
// running off the end of a list you are looking at is how you lose the top of
// it without seeing where it went.
app_picker_step :: proc(app: ^App, d: int) {
	#partial switch app.overlay {
	case .Model:
		app.model = Model(clamp(int(app.model) + d, 0, len(Model) - 1))
		model_save(app.model)
	case .Effort:
		app.effort = Effort(clamp(int(app.effort) + d, 0, len(Effort) - 1))
		effort_save(app.effort)
	}
}

// Asking for a thread. The page moves to it in the same breath, so the chat
// under it has to move now as well — the reading of the file is what waits.
//
// It used to be only the request that was recorded, and the transcript stayed
// on whatever was last open until the scan came round and named the new one.
// A card's thread is not in the scan the moment it is made: the scan skips a
// file with nothing in it worth a title, which is exactly what a turn that has
// just started has written. So clicking a running card sat you in the last
// conversation you had open, wearing its title, for as long as that took — and
// anything typed there went to that thread.
app_select :: proc(app: ^App, id: string) {
	delete(app.pending_open)
	app.pending_open = strings.clone(id)
	if id == "" || app.chat.session_id == id do return

	// The thread, named and empty. Everything here is what app_open sets from
	// the session list; the list is the one thing missing, so the id and the
	// cwd are taken from whoever does know — the turn writing it, or the card
	// that asked for it — and the transcript arrives when it arrives.
	chat_destroy(&app.chat)
	clear(&app.open)
	app.chat.session_id = strings.clone(id)
	app.chat.cwd = strings.clone(app_session_cwd(app, id))
	app.cur_msg = -1
	app.stick = true
	app.transcript.offset = 0
	app.transcript.target = 0
	turns_rebind(app)
	app_status(app, "loading...")
}

// Where a thread runs, for a thread the scan has not listed yet: the turn
// writing it knows, and failing that the card that asked for it does.
app_session_cwd :: proc(app: ^App, id: string) -> string {
	if at := session_index(app, id); at >= 0 do return app.sessions[at].cwd
	if at := turn_for_session(app, id); at >= 0 do return app.turns[at].cwd
	for td in app.todos.list do if td.session == id do return td.cwd
	return ""
}

chat_new :: proc(app: ^App) {
	chat_destroy(&app.chat)
	clear(&app.open)
	app.chat.cwd = strings.clone(app.cwd)
	app.chat.title = strings.clone("New chat")
	app.cur_msg = -1
	app.stick = true
	app.transcript.target = 0
	app.transcript.offset = 0
	turns_rebind(app)
}

// Opens a session. The transcript is parsed on a worker thread, so the click
// lands instantly even on a session file that runs to tens of megabytes.
app_open :: proc(app: ^App, index: int) {
	if index < 0 || index >= len(app.sessions) do return
	// Already open and already read. The path is what says it was read: a
	// thread named by a click but never found on disk has none, and the guard
	// used to turn that into "you are looking at it" and never load a thing.
	if app.chat.session_id == app.sessions[index].id && app.chat.path != "" && !load_busy(&app.load) do return

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
	// Through the worktree to the project it was cut from: a thread running
	// in a card's own tree is still work in the project the card came from.
	if project := worktree_project(app, s.cwd); project != "" && project != app.cwd {
		delete(app.cwd)
		app.cwd = strings.clone(project)
	}
	app.cur_msg = -1
	app.stick = true
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
// start. Nothing else can stop it — every message goes out the moment it is
// typed, whatever else this window is running.
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

	// The thread's own directory, checked out again if it was a card's tree
	// and the card has since finished with it.
	cwd := worktree_restore(app, app_chat_cwd(app))
	route_clear(app)

	// A turn already running in this thread is no reason to hold this one:
	// it starts now, beside the one before it. There used to be a queue here
	// — a follow-up waited in it until the turn it was typed over finished,
	// because two `--resume`s of one session are two processes writing one
	// session file. The waiting is what broke: a turn that ended in a way
	// nothing noticed left its follow-ups sitting in the queue for good, and
	// a message that never goes out is worse than two harnesses arguing over
	// a session file — which the harness settles for itself, and which
	// nothing waiting in this process ever settled.
	//
	// The composer's turn is the one that draws into the transcript.
	if !turn_start(app, cwd, app_project(app), app.chat.session_id, prompt, "", true) {
		app_status(app, "could not start claude")
		return false
	}
	app.cur_msg = -1
	app.stick = true
	// The status line is not told. It used to say "thinking...", and only a
	// Done from this very thread took it off again — so going back to the
	// grid, or opening any other thread, left the project page saying
	// "thinking..." over a grid of cards, for the rest of the run. Whether a
	// turn is in flight is read off the turns (`app_chat_busy`, and on the
	// grid the card itself), never written down beside them.
	return true
}

// --- applying what the runner streams ---------------------------------------

@(private = "file")
open_key :: proc(parent: string, index: int) -> u64 {
	return ui_id(parent, index + 1)
}

app_apply_events :: proc(app: ^App) -> bool {
	changed := probe_pump(app)
	for t, at in app.turns {
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
	t := app.turns[at]
	turn_note(t, e)

	// The harness names the thread in the first record it writes, and that is
	// what everything else about this turn hangs off.
	if e.kind == .Session && e.id != "" && t.session != e.id {
		delete(t.session)
		t.session = strings.clone(e.id)
		// The project, not the tree it is checked out into: the card is filed
		// under the work it belongs to.
		if t.todo != "" do todo_set_session(&app.todos, t.todo, e.id, t.project)
		if t.chat && c.session_id != e.id {
			delete(c.session_id)
			c.session_id = strings.clone(e.id)
		}
	}

	// What is left of the plan's allowance. It is the account's answer and not
	// this turn's — every turn's stream carries the same reading — so it is
	// taken here, before the turn is asked whether it has a transcript to
	// draw into: nearly every turn in this window is headless, and a reading
	// only the one on screen could deliver would almost never arrive.
	if e.kind == .Limits do usage_take(&app.usage, e.limits)

	if !t.chat || (t.session != "" && t.session != c.session_id) {
		#partial switch e.kind {
		case .Failed:
			app_turn_failed(app, t, e.text)
		case .Done:
			app_turn_ended(app, t, .Done)
		}
		return
	}

	switch e.kind {
	case .Session:
		// Taken above: the id has to be picked up whether or not anyone is
		// looking at the thread it names.

	case .Verdict:
		// Taken above too: what a turn says about its own work is the card's
		// business whether or not anyone has the thread open.

	case .Limits:
		// Taken above as well, and for the same reason.

	case .Msg_Start:
		if e.parent == "" do app.cur_msg = chat_append(c, .Assistant)

	case .Block_Start:
		// Every block starts running, whatever it is. It stops when it stops
		// being written — Block_Stop for anything the model is typing, the
		// result coming back for a tool, which is what a tool is still doing
		// after its call is whole. Only tools used to be marked, so while the
		// model was thinking or writing its answer the path stood perfectly
		// still and nothing on screen said the turn was alive.
		block := Block {
			kind    = e.block_kind,
			running = true,
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
			if b := chat_block(c, ref); b != nil && b.kind != .Tool {
				b.running = false
				// The handshake goes here, not on screen. A thread read back
				// off disk has always had it taken off (sessions.odin), but a
				// card whose thread you had open while it finished watched
				// `<aithing>done</aithing>` type itself out at the bottom of
				// the transcript. Here rather than in the deltas because the
				// marker is one line and the deltas cut it wherever the bytes
				// happened to arrive; a block that has stopped is whole.
				text := strings.to_string(b.text)
				if bare := verdict_unmark(text); len(bare) != len(text) {
					kept := strings.clone(bare, context.temp_allocator)
					strings.builder_reset(&b.text)
					strings.write_string(&b.text, kept)
				}
			}
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
		// The transcript is the only part of this that is about having the
		// thread open. What became of the turn is not: the card is marked and
		// the reason written down the same way it would be if nobody were
		// looking, because opening a card used to be the difference between
		// `failed` with the reason beside it and `failed` on its own.
		m := chat_append(c, .System)
		ref := msg_append_block(c, m, Block{kind = .Error})
		strings.write_string(&chat_block(c, ref).text, e.text)
		app_turn_failed(app, t, e.text)

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
	}
}

// A turn came back a failure. One path, whether or not its thread is the one
// on screen: a turn stopped by hand is not a failure at all, and every other
// one leaves the reason on the card — a headless turn has nowhere else to put
// it, and a card that says `failed` and nothing else is one you cannot act on.
@(private = "file")
app_turn_failed :: proc(app: ^App, t: ^Turn, text: string) {
	if t.stopped {
		// Killed by hand a moment ago. The non-zero exit that follows is us,
		// not the work.
		app_note(app, t.todo, "stopped")
		app_turn_ended(app, t, .Open)
		return
	}
	app_note(app, t.todo, text)
	app_status(app, text != "" ? text : "a turn failed")
	app_turn_ended(app, t, .Failed)
}

// A turn that went away without a word: no Done, no Failed, no exit anything
// noticed. Nothing should reach this — the reader thread emits Done on its way
// out whatever happened — so a card that lands here is a card whose turn is
// unaccounted for, and saying that is worth more than the tidiest of the
// wrong answers.
app_turn_vanished :: proc(app: ^App, t: ^Turn) {
	app_note(app, t.todo, "the turn ended without a word")
	app_turn_ended(app, t, .Failed)
}

// A turn is over. Its card is marked, and the sidebar is re-read because the
// session file has just changed.
app_turn_ended :: proc(app: ^App, t: ^Turn, state: Todo_State) {
	if t.ended do return // Failed then Done is one ending, and the first wins
	t.ended = true
	// What the process did and what the work did are two questions, and the
	// exit code only answers the first.
	outcome := turn_outcome(t, state)
	if outcome == .Asked do app_note(app, t.todo, t.say)
	app_todo_finished(app, t.todo, outcome)
	app.rescan = true
	// And the work goes back into the project it came from, now, on the frame
	// the card said it was finished — see app_land_worktree.
	app_land_worktree(app, t)
}

// A finished card's work, put back into its project, and then its checkout
// given back. Both in the one place, and in that order: a tree removed before
// its commits were merged is a branch nobody would ever find again, and this
// used to remove without merging at all — a week of green cards was a week of
// `aithing/n-*` branches left for somebody to go through by hand.
//
// Only a card that is done, and only a tree nothing else is running in: a
// follow-up typed into the same thread starts beside the turn that is ending
// and runs in the same directory, and merging or deleting the floor out from
// under a working agent is the one way this could lose work.
//
// A card that would not land keeps its tree, its branch and everything in it,
// and stops being Done: it says `needs you` with git's own sentence beside
// it, because the only place a conflict can be settled is the tree the work
// is in, and a card that says `complete` over work that is not in the project
// is the lie this whole path exists to stop telling.
@(private = "file")
app_land_worktree :: proc(app: ^App, t: ^Turn) {
	if t.todo == "" || t.project == "" || t.cwd == t.project do return
	if !worktree_idle(&app.todos, t.todo) do return
	for other in app.turns do if other != t && other.live && other.cwd == t.cwd do return
	app_land_card(app, t.project, t.todo)
}

// Every card that is finished and whose work is still on a branch of its own.
//
// Landing used to happen in exactly one place — the end of a turn — which is
// one place too few. A card marked done by the last turn of a window that was
// then closed, a card whose landing was skipped because another turn was
// still running in its tree, a card finished by a window that crashed: all of
// them stayed green on the grid with their work on a branch, and the sweep
// then took the tree away, so the branch was the only thing left that knew.
// The window opened on a grid of finished cards and a project with none of
// their work in it, which is exactly what it looks like when a feature was
// never written.
//
// Asked of git rather than written down: a card is landed when its branch is
// gone or is already an ancestor of the project's, and worktree_land answers
// that itself. So this can run on every launch and do nothing on all but the
// cards that need it.
app_land_finished :: proc(app: ^App) {
	for todo in app.todos.list {
		if todo.cwd == "" do continue
		if todo.state == .Done {
			app_land_card(app, todo.cwd, todo.id)
			continue
		}
		// A card that says `needs you` about work that is already in the
		// project is a card asking about nothing, and it is the person who
		// ends up doing the tidying — which is the opposite of the point.
		// Three of them sat like that at once: their work was in, their
		// branches were gone, and the only thing left saying otherwise was a
		// state written down at the end of a turn that has long since stopped
		// being true.
		//
		// Never `Failed`, which is a verdict about the work and not about
		// where it went, and never a card that has not run: a card with no
		// thread behind it has no branch for the same reason a card that
		// landed has none, and only the thread tells them apart.
		if todo.state != .Asked && todo.state != .Open do continue
		if todo.session == "" do continue
		if !worktree_settled(todo.cwd, todo.id) do continue
		todo_set_state(&app.todos, todo.id, .Merged)
	}
}

@(private = "file")
app_land_card :: proc(app: ^App, project, id: string) {
	// A card that is no longer on the grid is not a card that finished. Its
	// tree still goes, on git's terms, but nothing of it goes into the
	// project: dismissing a card is saying you are done with what it was
	// doing, and merging the work of something you threw away is the one
	// thing here that could put code you never wanted into a branch you do.
	at := todos_find(&app.todos, id)
	if at < 0 {
		_ = worktree_release(project, id)
		return
	}
	why, conflicted := worktree_land(project, id, app.todos.list[at].text)
	if why != "" {
		app_note(app, id, why)
		app_todo_finished(app, id, .Asked)
		// A conflict is not the end of the asking. The tree is sitting there
		// with the markers in it, and the thing best placed to settle them is
		// the one that wrote one of the two sides — so it gets put back in
		// there to finish the job, and the card goes on saying `processing`
		// while it does. Handing a merge conflict to a person was the whole
		// of the answer before, and it made a card that had done its work
		// perfectly into a chore.
		//
		// Exactly one go: worktree_land refuses a tree that is already
		// mid-merge, so a resolve turn that ends without settling it lands
		// the card on `needs you` and stops there.
		if conflicted && !app_resolving(app, id) {
			append(&app.pending_resolve, strings.clone(id))
		}
		return
	}
	_ = worktree_release(project, id)
	// Said on the card, because it is the card's question: complete is what
	// the agent finished, merged is where the work went.
	todo_set_state(&app.todos, id, .Merged)
	// And if what just landed was this program, it is out of date the moment
	// it landed. The build is started here rather than when the turn ended
	// because a card works in a checkout of its own: until the branch goes in,
	// the source it changed is not the source this binary came from. Nothing
	// is taken over — see build.odin.
	build_start(app, project)
	// And out, so a card that is done is done everywhere and not just here.
	push_start(app, project)
}

// What a turn is given when the merge is the work. Its own thread, resumed:
// the agent that did the card is the one that wrote one side of the conflict,
// and starting a stranger in a tree full of markers throws that away.
RESOLVE_PROMPT :: "Your work is being merged back into the project and it conflicts. The merge is already started in this working directory — the conflicting files have markers in them and MERGE_HEAD is set. Resolve every conflict, keeping what your work was for and what the project has moved on to, check it still builds and its tests still pass, and commit the merge. Do not abort it and do not touch any other repository.\n\nThe work was:\n\n"

// Puts an agent back in a card's tree to settle the merge. Once the frame is
// over rather than where it is decided, and through the ordinary turn path —
// a resolve is a turn on the card like any other, so the card says
// `processing`, the thread it writes to is the card's own, and stopping or
// dismissing the card stops it.
@(private = "file")
app_start_resolve :: proc(app: ^App, id: string) {
	at := todos_find(&app.todos, id)
	if at < 0 do return
	td := app.todos.list[at]
	if turn_for_todo(app, id) >= 0 do return
	project := td.cwd != "" ? td.cwd : app.cwd
	tree := worktree_path(project, id, context.temp_allocator)
	if !worktree_merging(tree) do return
	prompt := verdict_preamble(strings.concatenate({RESOLVE_PROMPT, td.text}, context.temp_allocator))
	if !turn_start(app, tree, project, td.session, prompt, id, false) {
		app_note(app, id, "could not start claude to resolve the merge")
		app_todo_finished(app, id, .Failed)
		return
	}
	app_note_clear(app, id)
	app_status(app, "resolving the merge")
}

// Whether a card's tree is already stopped in a merge. Read off the tree, so
// there is nothing to keep in step: a card gets one go at resolving because
// the second attempt finds MERGE_HEAD still there.
@(private = "file")
app_resolving :: proc(app: ^App, id: string) -> bool {
	at := todos_find(&app.todos, id)
	if at < 0 do return false
	project := app.todos.list[at].cwd != "" ? app.todos.list[at].cwd : app.cwd
	return worktree_merging(worktree_path(project, id, context.temp_allocator))
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

// Case-insensitive `contains`, without making a lowercase copy of either
// side. Everything the search looks at goes through here — every session on
// the machine and every card, several times a frame while the query is being
// typed — and it used to be `strings.to_lower` on each field first: four temp
// copies per session per pass, a few thousand allocations a keystroke, which
// is what the box was waiting on before it caught up with what you typed.
//
// The fold is ASCII, which is the whole of what anyone types into it; a
// non-ASCII capital in a title is matched by the same capital and not by its
// lowercase, and that is the price of not copying a thousand strings a frame.
contains_fold :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 do return true
	if len(needle) > len(haystack) do return false
	fold :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
	first := fold(needle[0])
	for i in 0 ..= len(haystack) - len(needle) {
		if fold(haystack[i]) != first do continue
		hit := true
		for j in 1 ..< len(needle) {
			if fold(haystack[i + j]) != fold(needle[j]) {
				hit = false
				break
			}
		}
		if hit do return true
	}
	return false
}

base_name :: proc(path: string) -> string {
	if idx := strings.last_index_byte(path, '/'); idx >= 0 && idx + 1 < len(path) {
		return path[idx + 1:]
	}
	return path
}

// How many projects the grid is showing, and which one when it is showing
// exactly one. The heading over the grid and the names over the sections are
// two answers to the same question — what is on screen — and they used to
// disagree: the heading said "all projects" while the first section, the one
// the heading sat directly on top of, went unnamed on the grounds that the
// line above it had already said which project it was. Both now read this.
app_view_projects :: proc(app: ^App) -> (n: int, only: string) {
	cwd := ""
	for at in app.todo_view {
		if at >= len(app.todos.list) do continue
		td := app.todos.list[at]
		if td.cwd == cwd do continue
		cwd = td.cwd
		n += 1
		only = cwd
	}
	if n != 1 do only = ""
	return
}
