package aithing

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// A window used to run exactly one `claude -p` and make everything else wait
// behind it. Four cards typed into the box then went out one at a time, which
// is four times as long as it needs to be when the four are unrelated pieces
// of work in unrelated threads.
//
// So a turn is a slot, and there are as many as are asked for. Each holds its
// own process, its own reader thread and its own event list. There was a
// ceiling of four and a queue behind it; both are gone, because a card that
// says `queued` is a card whose work is not being done, and nothing about
// four unrelated threads makes a fifth one wrong.
//
// The slots are separately allocated and are never moved or compacted: the
// reader thread holds a pointer into its own slot, and a list that shuffled
// itself under one would be a use-after-free the moment a turn finished. A
// slot that has settled is reused where it stands, and a new one is made only
// when every existing one is busy.
//
// A turn started from the grid is headless. It runs in a thread of its own on
// disk, the cards say how it is going, and clicking one opens the thread once
// the harness has named it. Only the turn a person typed into the composer
// draws into the transcript, because there is only one transcript on screen.
//
// A turn carries the card it is running. One card, one thread: a list typed
// into the box makes a card a part and a turn a part, so a card can be opened,
// stopped or dismissed without the ones typed beside it coming along.

Turn :: struct {
	runner:  Runner,
	live:    bool, // holds a process, or events not yet read out of one
	session: string, // the thread it writes to, "" until the harness names one
	cwd:     string, // where the process runs: a card's own worktree, if it has one
	// The project the work belongs to, which is not always where it runs —
	// see worktree.odin. The card is filed under this; a card filed under the
	// tree it happened to be checked out into would leave the grid grouping
	// this project's work under a path in the cache.
	project: string,
	todo:    string, // the card it is running, "" when a person typed it
	chat:    bool, // its output belongs in the transcript on screen
	// What it is doing right now: the tool it is running and what it is
	// running it on. A headless turn has no transcript anyone can look at, so
	// the one line that says where it has got to has to be caught off the
	// stream as it goes past — and the cards are where it is read.
	tool:    string,
	arg:     string,
	// How much context the turn is carrying: what the harness said it handed
	// the model on the last message it started. Off the stream, not counted
	// here — the prompt this window sends is a few hundred words and the
	// twenty thousand tokens around it are the harness's own, so a figure
	// worked out from what we sent would be wrong by two orders of magnitude
	// and confidently so. It lives on the turn and nowhere else: a thread
	// with nothing running has not told anybody how big it is, and a number
	// kept past the process that read it would be a guess wearing a
	// measurement's clothes.
	tokens:  int,
	// The last thing the agent said about its own work, and the last thing it
	// said at all. A turn ending is not the work being finished — see
	// verdict.odin — and this is the only thing that knows the difference.
	verdict: Verdict,
	say:     string,
	// Stopped by hand, so the non-zero exit that follows is not a failure of
	// the work and must not be reported as one. Only a stop made in this
	// window: ask turn_stopped, which hears about the others too.
	stopped: bool,
	// Already accounted for. The harness can say Failed and then Done for one
	// turn, and the cards must take the first of those and not the second —
	// and the sweep that catches a turn dying silently must not undo either.
	ended:   bool,
	// What it has handed off and not had back: subagents and commands running
	// beside it. Off the stream, like `tool`, because the harness is the only
	// thing that knows — and while the agent sits waiting on three agents its
	// own tool is nothing at all, so a card that asked only that looked like
	// a card doing nothing.
	tasks:   [dynamic]Turn_Task,
	// The agent has written its last message. The process can outlive that:
	// the harness waits on subagents and wakes the agent when one comes back,
	// so the next message it starts puts this back.
	over:    bool,
	// What the harness stopped because the turn was over while it was still
	// running. An agent that starts the build in the background, writes `I'm
	// waiting for the build` and ends its turn has not asked anything — it
	// has left, and the build went with it. That read `needs you` over its
	// own sentence about waiting, which was true of nothing by then.
	left:    [dynamic]string,
	// This turn is already the one sent back to finish what an earlier one
	// left running. It is not sent back again: once is a nudge, twice is a
	// loop with a bill.
	again:   bool,
	// What the process was started on. The thread keeps this the first time
	// the harness names it, rather than whatever the chips say by then.
	setting: Setting,
}

Turn_Task :: struct {
	id:       string,
	what:     string, // what it was asked to do
	doing:    string, // the last thing it said it was at, "" until it says
	tool_use: string, // the call that started it, which is its block in the transcript
	agent:    bool,
}

// --- finding one --------------------------------------------------------------

// A slot with nothing in it, making one if every existing slot is busy. There
// is no answer for "no room": a turn asked for is a turn started, and the
// caller has nowhere to put a card it was told to wait with.
turn_slot :: proc(app: ^App) -> int {
	for t, i in app.turns do if !t.live do return i
	append(&app.turns, new(Turn))
	return len(app.turns) - 1
}

turn_for_session :: proc(app: ^App, session: string) -> int {
	if session == "" do return -1
	for t, i in app.turns do if t.live && t.session == session do return i
	return -1
}

turn_for_todo :: proc(app: ^App, id: string) -> int {
	if id == "" do return -1
	for t, i in app.turns do if t.live && t.todo == id do return i
	return -1
}

// The turn behind what a card says it is doing, or -1. A card is running
// because a turn is on the card *or* because one is working in the card's own
// thread — a follow-up typed into the composer, a resolve — and until this
// existed only the first half of that was asked in most places. The word on
// the card asked both, so the card said `processing`; the mark beside the word
// asked only `turn_for_todo`, so there was nothing turning next to it, and Esc
// on that card stopped nothing.
//
// The thread's turn has to be a running one, not the first slot naming the
// thread: a turn that has settled and not yet been reaped still names it for a
// frame, and that slot would have answered for a card with nothing left in
// flight.
turn_for_card :: proc(app: ^App, td: Todo) -> int {
	if at := turn_for_todo(app, td.id); at >= 0 do return at
	if td.session == "" do return -1
	for t, i in app.turns do if t.live && t.session == td.session && runner_busy(&t.runner) do return i
	return -1
}

// The turn drawing into the transcript on screen, or -1.
turn_chat :: proc(app: ^App) -> int {
	for t, i in app.turns do if t.live && t.chat do return i
	return -1
}

// Whatever turn is working in the thread on screen, or -1. Not the same
// question as turn_chat: a card's turn is headless and never sets `chat`, and
// clicking the card opens its thread — so the thread you are reading has a
// process behind it that never asked for the transcript. The named thread
// answers first because a turn typed into the composer is still `chat` after
// the harness has named its session, and a card's turn is not.
turn_here :: proc(app: ^App) -> int {
	if at := turn_for_session(app, app.chat.session_id); at >= 0 do return at
	return turn_chat(app)
}

app_turns_live :: proc(app: ^App) -> int {
	n := 0
	for t in app.turns do if t.live do n += 1
	return n
}

// Anything at all in flight. This is the one the frame loop asks: a window
// with a turn running has to keep drawing.
app_busy :: proc(app: ^App) -> bool {
	for t in app.turns do if t.live && runner_busy(&t.runner) do return true
	return false
}

// A process running in one particular thread, which is not the same question
// as whether the thread has work coming: a message waiting for that process is
// work as much as the process is. One answer, so the card, the composer and
// the send all read the same thing off it.
app_session_busy :: proc(app: ^App, session: string) -> bool {
	if session == "" do return false
	if session_running(app, session) do return true
	for q in app.queued do if q.session == session do return true
	return false
}

// Just the process. The queue drains off this rather than off
// app_session_busy, which counts the queue itself.
//
// Every slot, not the first one `turn_for_session` finds: a thread whose last
// turn has settled and not yet been reaped has two slots naming it for a
// frame, and the finished one answered for the running one — which let a
// second message out into a thread that was still busy.
//
// And another window's process, which is the same two harnesses appending to
// one file when a message typed here goes out beside it. The message waits
// for that run's directory to go, which is that window having read it to the
// end — or, if that window closes first, this one taking it over.
session_running :: proc(app: ^App, session: string) -> bool {
	if session == "" do return false
	for t in app.turns do if t.live && t.session == session && runner_busy(&t.runner) do return true
	return elsewhere_session(app, session)
}

// A turn running in the thread on screen: what the composer draws itself
// around, and what Esc inside a thread stops.
app_chat_busy :: proc(app: ^App) -> bool {
	at := turn_chat(app)
	return at >= 0 && runner_busy(&app.turns[at].runner)
}

// Keeps `tool` and `arg` current from one event, which is all the state a
// progress line needs. Run for every turn, the one drawing into the
// transcript included, so a card says the same thing whether or not anyone
// happens to be watching its thread.
turn_note :: proc(t: ^Turn, e: ^Event) {
	#partial switch e.kind {
	case .Msg_Start:
		// How big the request was. Only the agent's own messages: a subagent
		// runs on a context of its own, and a Task reading half the repo
		// would otherwise be reported as the thread's size.
		if e.parent == "" && e.tokens > 0 do t.tokens = e.tokens
		// Back to writing: whatever it was running has come back.
		turn_set_tool(t, "", "")
		// And whatever it last claimed about the work is about the message
		// before this one. The verdict is the last message's verdict, so a
		// turn that says it is done and then carries on is not done.
		if e.parent == "" {
			t.verdict = .None
			t.over = false
		}
	case .Turn_Over:
		t.over = true
	case .Task:
		turn_task(t, e)
	case .Verdict:
		t.verdict = e.verdict
		delete(t.say)
		t.say = strings.clone(e.text)
	case .Block_Start:
		// The tool is named as the model starts writing its arguments, which
		// is a second or two before anyone knows what they are.
		if e.block_kind == .Tool do turn_set_tool(t, e.name, "")
	case .Tool_Input:
		// The event carries the whole input now; a line under a card's title
		// has room for one argument of it.
		turn_set_tool(t, e.name, tool_arg(e.text, e.name))
	}
}

@(private = "file")
turn_task :: proc(t: ^Turn, e: ^Event) {
	at := -1
	for task, i in t.tasks do if task.id == e.id do at = i
	if e.status != .Running {
		if at < 0 do return
		if e.status == .Dropped && t.over do append(&t.left, strings.clone(t.tasks[at].what))
		turn_task_destroy(&t.tasks[at])
		ordered_remove(&t.tasks, at)
		return
	}
	if at < 0 {
		append(&t.tasks, Turn_Task{id = strings.clone(e.id), what = strings.clone(e.name), tool_use = strings.clone(e.tool_use), agent = e.agent})
		at = len(t.tasks) - 1
	}
	if e.text != "" {
		delete(t.tasks[at].doing)
		t.tasks[at].doing = strings.clone(e.text)
	}
}

@(private = "file")
turn_task_destroy :: proc(task: ^Turn_Task) {
	delete(task.id)
	delete(task.what)
	delete(task.doing)
	delete(task.tool_use)
}

// Whether the call that started a task is still out: the transcript keeps its
// block running until the task comes back, because the harness answers a
// background call at once and the block would otherwise stop the moment the
// work it stands for started.
turn_task_out :: proc(t: ^Turn, tool_use: string) -> bool {
	for task in t.tasks do if task.tool_use == tool_use do return true
	return false
}

// Which call started the task an event is about.
turn_task_call :: proc(t: ^Turn, e: ^Event, allocator := context.temp_allocator) -> string {
	if e.tool_use != "" do return strings.clone(e.tool_use, allocator)
	for task in t.tasks do if task.id == e.id do return strings.clone(task.tool_use, allocator)
	return ""
}

// A task as a line to read under the pointer.
task_line :: proc(task: Turn_Task, allocator := context.temp_allocator) -> string {
	if task.doing == "" do return task.what
	return strings.concatenate({task.what, "  ", task.doing}, allocator)
}

@(private = "file")
turn_set_tool :: proc(t: ^Turn, tool, arg: string) {
	if t.tool == tool && t.arg == arg do return
	delete(t.tool)
	delete(t.arg)
	t.tool = strings.clone(tool)
	t.arg = strings.clone(arg)
}

// What actually became of a card whose turn came back clean. The process
// exiting zero says the turn is over and nothing else: an agent that stopped
// to ask a question exits exactly as cleanly as one that did the work, and
// the card used to read `complete` for both.
turn_outcome :: proc(t: ^Turn, state: Todo_State) -> Todo_State {
	if state != .Done do return state
	return t.verdict == .Done ? .Done : .Asked
}

// The line a card shows while its turn runs.
turn_doing :: proc(t: ^Turn, allocator := context.temp_allocator) -> string {
	if t.tool == "" && len(t.tasks) > 0 do return fmt.aprintf("waiting on %d in the background", len(t.tasks), allocator = allocator)
	if t.tool == "" do return "working"
	if t.arg == "" do return t.tool
	return strings.concatenate({t.tool, "  ", t.arg}, allocator)
}

// --- running one ----------------------------------------------------------------

// How a turn gets its process. Only the tests point this anywhere else: they
// stand turns up to check the bookkeeping that decides which card is running,
// and a test suite that starts a `claude` per card would be running the
// harness for real.
turn_spawn := runner_start

// Takes a slot and starts a turn in it. `session` empty is a new thread,
// `todo` names the card it is running, and `chat` says its output is wanted
// in the transcript on screen. False means a harness that would not start —
// there is no such thing as no room any more.
turn_start :: proc(app: ^App, cwd, project, session, prompt, todo: string, chat: bool, again := false) -> bool {
	at := turn_slot(app)
	// One transcript, so at most one turn drawing into it.
	if chat do for other in app.turns do other.chat = false
	t := app.turns[at]
	t^ = Turn {
		live    = true,
		session = strings.clone(session),
		cwd     = strings.clone(cwd),
		project = strings.clone(project),
		todo    = strings.clone(todo),
		chat    = chat,
		again   = again,
		setting = turn_setting(app, cwd, session),
	}
	if !turn_spawn(&t.runner, cwd, session, prompt, model_flag[t.setting.model], effort_flag[t.setting.effort], at) {
		turn_release(app, at)
		return false
	}
	turn_write_note(t)
	return true
}

// What a window picking this turn up needs to know that the stream will not
// tell it: where it runs, the project and the card it is for, and the thread
// it writes to once there is one — a follow-up knows it from the start, and a
// new thread has it written in when the harness names it.
Turn_Note :: struct {
	session: string,
	cwd:     string,
	project: string,
	todo:    string,
	again:   bool,
	model:   string,
	effort:  string,
}

// Written when the turn starts and again once the harness has named the
// thread, because a window beside this one reads the note to know which
// thread the run is writing, and a note that still says "" has it sending a
// message into a thread it thinks is free. Through a rename, because that
// window reads it every frame.
turn_write_note :: proc(t: ^Turn) {
	if t.runner.dir == "" do return
	note := Turn_Note{t.session, t.cwd, t.project, t.todo, t.again, model_short[t.setting.model], effort_flag[t.setting.effort]}
	data, err := json.marshal(note, allocator = context.temp_allocator)
	if err != nil do return
	_, _ = file_replace(run_file(t.runner.dir, "turn.json"), data)
}

// A turn another window is holding: what its note says it is for. This
// window cannot read its stream — the other window holds that — but it can
// see that it is there, and every question about a card or a thread that
// asks whether something is working on it has to hear about it. Without this
// a card one window was running read `waiting` in the other, and a click
// there started a second agent on it in the same tree.
Elsewhere :: struct {
	todo:    string,
	session: string,
	cwd:     string,
	dir:     string, // the run, which is how this window stops it
}

// Every run in the cache, sorted into three: this window's own, which are in
// app.turns already; one nobody holds, which a window since closed left
// behind and which is taken back here as if this window had started it; and
// one another window holds, which goes into app.elsewhere. Once a frame and
// on the way up, so a window closed while this one stays open hands its turns
// over, and a turn started in the other window shows here a frame later.
//
// Taken back headless: it draws into the transcript only once its thread is
// open, the same as a card's turn does. A directory with no note in it — a
// window that died in the instant between starting a turn and writing down
// what it was for — is still read, for the thread it names.
//
// What it costs is a lock tried and a note read per run some other window is
// holding, which is a handful: see the_runs_are_cheap_to_survey.
// `root` is for the tests, which keep their runs out of the cache the rest of
// the suite clears.
turns_survey :: proc(app: ^App, root := "") -> bool {
	seen := make([dynamic]Elsewhere, context.temp_allocator)
	took := false
	if entries, ok := run_dirs(root != "" ? root : cache_path("runs")); ok {
		for e in entries {
			if turn_holding(app, e.fullpath) do continue
			note := run_note(e.fullpath)
			if turn_take(app, e.fullpath, note) {
				took = true
				continue
			}
			append(&seen, Elsewhere{note.todo, note.session, note.cwd, e.fullpath})
		}
	}
	if took do turns_rebind(app)
	if !took && elsewhere_same(app.elsewhere[:], seen[:]) do return false
	// The thread on screen was being written over there and is not any more.
	// What this window has of it is the file as it stood when it was opened —
	// nothing streams here from a run another window holds — so it is read
	// again now that it is whole, or it sits half written until it is opened
	// again.
	open := app.chat.session_id
	if elsewhere_session(app, open) && turn_for_session(app, open) < 0 {
		over := true
		for e in seen do if e.session == open do over = false
		if over && load_again(&app.load, open) do app_status(app, "loading...")
	}
	elsewhere_clear(app)
	for e in seen do append(&app.elsewhere, Elsewhere{strings.clone(e.todo), strings.clone(e.session), strings.clone(e.cwd), strings.clone(e.dir)})
	return true
}

// The run directories, without the ones on their way in or out: a run is
// made under a hidden name and renamed into place once it is locked, and
// renamed out of the way again before it is removed (see runner.odin), so a
// directory under its own name is always a whole one.
@(private = "file")
run_dirs :: proc(root: string) -> (out: []os.File_Info, ok: bool) {
	dir, err := os.open(root)
	if err != nil do return
	defer os.close(dir)
	entries, read_err := os.read_directory(dir, -1, context.temp_allocator)
	if read_err != nil do return
	list := make([dynamic]os.File_Info, context.temp_allocator)
	for e in entries do if e.type == .Directory && !strings.has_prefix(e.name, ".") do append(&list, e)
	return list[:], true
}

@(private = "file")
run_note :: proc(dir: string) -> (note: Turn_Note) {
	if data, err := os.read_entire_file_from_path(run_file(dir, "turn.json"), context.temp_allocator); err == nil {
		_ = json.unmarshal(data, &note, allocator = context.temp_allocator)
	}
	return
}

// Whether this window is already reading a run.
@(private = "file")
turn_holding :: proc(app: ^App, dir: string) -> bool {
	for t in app.turns do if t.live && t.runner.dir == dir do return true
	return false
}

// A run nobody holds, taken into a slot. False when another window holds it,
// and then nothing is taken: the slot stays empty for the next turn.
@(private = "file")
turn_take :: proc(app: ^App, dir: string, note: Turn_Note) -> bool {
	// The slot first and the index after: `app.turns[turn_slot(app)]` reads
	// the array before the call grows it, so the first turn adopted into an
	// empty window indexed past the end and nothing started.
	at := turn_slot(app)
	t := app.turns[at]
	if !runner_adopt(&t.runner, dir) do return false
	t.live = true
	t.session = strings.clone(note.session)
	t.cwd = strings.clone(note.cwd)
	t.project = strings.clone(note.project)
	t.todo = strings.clone(note.todo)
	t.again = note.again
	// A note from before it said is a turn started on the window's.
	t.setting = Setting{app.model, app.effort}
	if m, ok := model_parse(note.model); ok do t.setting.model = m
	if e, ok := effort_parse(note.effort); ok do t.setting.effort = e
	return true
}

@(private = "file")
elsewhere_same :: proc(a, b: []Elsewhere) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

elsewhere_clear :: proc(app: ^App) {
	for e in app.elsewhere {
		delete(e.todo)
		delete(e.session)
		delete(e.cwd)
		delete(e.dir)
	}
	clear(&app.elsewhere)
}

// Another window is working on this card: its own turn, or one in its thread.
elsewhere_card :: proc(app: ^App, td: Todo) -> bool {
	for e in app.elsewhere {
		if e.todo == td.id do return true
		if td.session != "" && e.session == td.session do return true
	}
	return false
}

// Stops whatever another window is running on a card or in a thread. A card
// says `processing` in every window, so Esc and the x mean the same in every
// window: they used to stop only what the window they were pressed in was
// holding, and a card running beside it went on running under a press that
// had plainly been meant for it.
elsewhere_stop :: proc(app: ^App, todo, session: string) -> bool {
	stopped := false
	for e in app.elsewhere {
		if (todo != "" && e.todo == todo) || (session != "" && e.session == session) {
			run_stop(e.dir)
			stopped = true
		}
	}
	return stopped
}

// Another window has a process writing this thread.
elsewhere_session :: proc(app: ^App, session: string) -> bool {
	if session == "" do return false
	for e in app.elsewhere do if e.session == session do return true
	return false
}

// Something is working in this directory, in this window or another: the
// question every landing has to ask before it takes a tree away from under
// whatever is in it.
tree_busy :: proc(app: ^App, cwd: string, except: ^Turn = nil) -> bool {
	if cwd == "" do return false
	for t in app.turns do if t != except && t.live && t.cwd == cwd do return true
	for e in app.elsewhere do if e.cwd == cwd do return true
	return false
}

// Where every turn is working, this window's and the other windows', which
// the startup sweep of finished cards' trees must leave alone: a follow-up to
// a card that is done runs in that card's tree.
turns_cwds :: proc(app: ^App, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for t in app.turns do if t.live && t.cwd != "" do append(&out, t.cwd)
	for e in app.elsewhere do if e.cwd != "" do append(&out, e.cwd)
	return out[:]
}

// Gives a slot back. Only ever called on a turn that has settled — no process
// and no events left — because the reader thread is holding a pointer to the
// runner inside it until then.
turn_release :: proc(app: ^App, at: int) {
	t := app.turns[at]
	// Before the slot is zeroed: a message waiting to be told what this turn's
	// thread is called has to be told now or never.
	queue_resolve(app, t)
	runner_destroy(&t.runner)
	delete(t.session)
	delete(t.cwd)
	delete(t.project)
	delete(t.todo)
	delete(t.tool)
	delete(t.arg)
	delete(t.say)
	for &task in t.tasks do turn_task_destroy(&task)
	delete(t.tasks)
	for s in t.left do delete(s)
	delete(t.left)
	t^ = {}
}

// Called once a frame, after the events have been read out: a slot whose
// process has gone and whose last event has been applied is free again.
turns_reap :: proc(app: ^App) -> bool {
	freed := false
	for t, i in app.turns {
		if !t.live || !runner_settled(&t.runner) do continue
		// Cards whose turn died without ever saying Done or Failed would
		// otherwise read `processing` for good. Failed, not Open: something
		// did start it, and a card put back to `waiting` is a card that reads
		// exactly like one nobody has ever asked for — you cannot tell from
		// the grid that a turn went out at all, let alone that it vanished.
		if t.todo != "" && !t.ended do app_turn_vanished(app, t)
		turn_release(app, i)
		freed = true
	}
	return freed
}

// The thread on screen changed, so which turn is allowed to draw into it did
// too. A turn whose thread is no longer open keeps running and keeps writing
// to its own session file; it just stops being drawn.
turns_rebind :: proc(app: ^App) {
	for t in app.turns {
		t.chat = t.live && t.session != "" && t.session == app.chat.session_id
	}
}

// Stopped by hand, here or in any other window.
turn_stopped :: proc(t: ^Turn) -> bool {
	return t.stopped || run_stopped(t.runner.dir)
}

// Stops one turn, on purpose. The kill makes the process exit non-zero, which
// is indistinguishable from a crash unless we remember that we did it.
turn_stop :: proc(app: ^App, at: int) {
	t := app.turns[at]
	if !t.live do return
	t.stopped = true
	runner_stop(&t.runner)
}

// --- messages waiting for the thread they were typed into -----------------------

// A follow-up typed into a thread that already has a turn in it. It waits for
// that turn rather than going out beside it.
//
// Both ways round have been wrong. There was a queue four slots wide that
// waited on a turn *saying* it had ended, and a turn that died without saying
// anything left its follow-ups sitting in it for good — a message that never
// goes out at all. So the waiting was taken out and every message went the
// moment it was typed, which is two `claude --resume`s of one session: two
// harnesses that each read the thread as it stood, each re-send the whole of
// it, and both append to the one file. What that costs is the conversation
// paid for twice; what it does is worse — the records interleave, and the
// second turn comes back on a thread whose messages are out of order.
//
// This queue cannot wedge the way the first one did, because nothing tells it
// anything. It drains off `session_running`, which is a process this window is
// holding; `turns_reap` lets go of a slot whose process is gone whether or not
// it ever said so, so a turn that dies silently frees its thread exactly like
// one that ends properly, and the message behind it goes out on the next
// frame.
Queued :: struct {
	// The thread it goes to. Empty means the turn ahead of it has not been
	// named yet — the harness names a thread in the first record it writes,
	// and a message typed inside that second has nothing else to hold on to,
	// so it holds the turn until the name arrives. Sending it as it stood was
	// a follow-up that started a second thread of its own.
	session: string,
	wait:    ^Turn, // only while session is ""
	cwd:     string,
	project: string,
	prompt:  string,
	// The card it is for, when it is a turn sent back to finish a card's
	// work rather than something a person typed: see turn_send_back.
	todo:    string,
	again:   bool,
}

turn_queue :: proc(app: ^App, session: string, wait: ^Turn, cwd, project, prompt: string, todo := "", again := false) {
	append(
		&app.queued,
		Queued {
			session = strings.clone(session),
			wait    = wait,
			cwd     = strings.clone(cwd),
			project = strings.clone(project),
			prompt  = strings.clone(prompt),
			todo    = strings.clone(todo),
			again   = again,
		},
	)
}

@(private = "file")
queued_destroy :: proc(q: ^Queued) {
	delete(q.session)
	delete(q.cwd)
	delete(q.project)
	delete(q.prompt)
	delete(q.todo)
	q^ = {}
}

// A turn is giving its slot back, so anything still waiting on it to be named
// takes the name now. The slot is about to be zeroed and handed to the next
// turn, and a message left pointing into it would wake up in somebody else's
// thread.
queue_resolve :: proc(app: ^App, t: ^Turn) {
	for &q in app.queued {
		if q.wait != t do continue
		delete(q.session)
		q.session = strings.clone(t.session)
		q.wait = nil
	}
}

// Drops whatever is waiting for a thread. Stopping a turn is stopping the
// work, and a follow-up that went out the moment the stop landed would be the
// window carrying on with what you just said to stop.
turn_unqueue :: proc(app: ^App, session: string, wait: ^Turn = nil) -> bool {
	dropped := false
	for i := len(app.queued) - 1; i >= 0; i -= 1 {
		q := &app.queued[i]
		if !((session != "" && q.session == session) || (wait != nil && q.wait == wait)) do continue
		queued_destroy(q)
		ordered_remove(&app.queued, i)
		dropped = true
	}
	return dropped
}

// Called once a frame, after the reap: every message whose thread is free now
// goes out, in the order it was typed. One per thread — starting a turn makes
// its thread running again, so the second message typed into a thread waits
// for the first, which is the whole of why it waited.
turns_pump :: proc(app: ^App) -> bool {
	sent := false
	for i := 0; i < len(app.queued); {
		q := &app.queued[i]
		// Still nameless: the turn ahead of it has not written its first
		// record yet. turn_release resolves this if that turn dies first.
		if q.session == "" && q.wait != nil {
			i += 1
			continue
		}
		if session_running(app, q.session) {
			i += 1
			continue
		}
		// Into the transcript if this is the thread on screen, the same as
		// the message would have been had it gone out when it was typed.
		if !turn_start(app, q.cwd, q.project, q.session, q.prompt, q.todo, q.session == app.chat.session_id, q.again) {
			app_status(app, "could not start claude", .Fail)
		}
		queued_destroy(q)
		ordered_remove(&app.queued, i)
		sent = true
	}
	return sent
}

// What a turn is given when the one before it walked away from its own work.
AGAIN_PROMPT :: "Your last turn ended while work you had started in the background was still running, and nothing waits once a turn is over: when you wrote your last message the harness stopped it. Carry on from where you were and finish. Anything you need to wait for — a build, the tests, a command that takes a while — run in the foreground, or wait on it until it has finished, before you write your last message. If you were really stopping to ask something, ask it again.\n\nWhat was stopped: "

// Puts the agent back in a thread it left with work still running — once,
// and only when the turn ended without saying the work was finished. The
// message goes through the queue, so it waits on this turn's process being
// gone like anything else typed into a busy thread, and the card reads
// `processing` from the moment it is decided: the work is not done, and the
// card says so.
turn_send_back :: proc(app: ^App, t: ^Turn) -> bool {
	if len(t.left) == 0 || t.again || turn_stopped(t) || t.session == "" do return false
	prompt := strings.concatenate({AGAIN_PROMPT, strings.join(t.left[:], "; ", context.temp_allocator)}, context.temp_allocator)
	// A card's turn is headless and is asked for a verdict like the one it
	// is finishing; a thread a person typed into is read by that person.
	if t.todo != "" do prompt = verdict_preamble(prompt)
	turn_queue(app, t.session, nil, t.cwd, t.project, prompt, t.todo, true)
	return true
}

queue_destroy :: proc(app: ^App) {
	for &q in app.queued do queued_destroy(&q)
	delete(app.queued)
}

// Nothing is stopped. Closing the window is not asking for the work to stop,
// and every turn still running is picked up again by the next window to open
// — see runner.odin. What is lost is the messages waiting for a busy thread,
// which live only here.
turns_destroy :: proc(app: ^App) {
	for t, i in app.turns do if t.live do turn_release(app, i)
	for t in app.turns do free(t)
	delete(app.turns)
	queue_destroy(app)
}
