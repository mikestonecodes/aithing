package aithing

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
	// The last thing the agent said about its own work, and the last thing it
	// said at all. A turn ending is not the work being finished — see
	// verdict.odin — and this is the only thing that knows the difference.
	verdict: Verdict,
	say:     string,
	// Stopped by hand, so the non-zero exit that follows is not a failure of
	// the work and must not be reported as one.
	stopped: bool,
	// Already accounted for. The harness can say Failed and then Done for one
	// turn, and the cards must take the first of those and not the second —
	// and the sweep that catches a turn dying silently must not undo either.
	ended:   bool,
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

// The turn drawing into the transcript on screen, or -1.
turn_chat :: proc(app: ^App) -> int {
	for t, i in app.turns do if t.live && t.chat do return i
	return -1
}

app_turns_live :: proc(app: ^App) -> int {
	n := 0
	for t in app.turns do if t.live do n += 1
	return n
}

// Anything at all in flight. This is the one the frame loop and the reload
// ask: a window with a turn running has to keep drawing, and must not exec
// over itself.
app_busy :: proc(app: ^App) -> bool {
	for t in app.turns do if t.live && runner_busy(&t.runner) do return true
	return false
}

// A turn running in one particular thread. Two turns in one thread would be
// two `--resume`s of the same session racing each other, so a follow-up to a
// busy thread waits even when there is a slot free.
app_session_busy :: proc(app: ^App, session: string) -> bool {
	at := turn_for_session(app, session)
	return at >= 0 && runner_busy(&app.turns[at].runner)
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
		// Back to writing: whatever it was running has come back.
		turn_set_tool(t, "", "")
		// And whatever it last claimed about the work is about the message
		// before this one. The verdict is the last message's verdict, so a
		// turn that says it is done and then carries on is not done.
		t.verdict = .None
	case .Verdict:
		t.verdict = e.verdict
		delete(t.say)
		t.say = strings.clone(e.text)
	case .Block_Start:
		// The tool is named as the model starts writing its arguments, which
		// is a second or two before anyone knows what they are.
		if e.block_kind == .Tool do turn_set_tool(t, e.name, "")
	case .Tool_Input:
		turn_set_tool(t, e.name, e.text)
	}
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
turn_start :: proc(app: ^App, cwd, project, session, prompt, todo: string, chat: bool) -> bool {
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
	}
	if !turn_spawn(&t.runner, cwd, session, prompt, model_flag[app.model], at) {
		turn_release(app, at)
		return false
	}
	return true
}

// Gives a slot back. Only ever called on a turn that has settled — no process
// and no events left — because the reader thread is holding a pointer to the
// runner inside it until then.
turn_release :: proc(app: ^App, at: int) {
	t := app.turns[at]
	// What it spent, on its way out of the slot it spent it in. This is the
	// one place a turn's numbers move: they are read off the live runner
	// until here and out of the day's total after it, so the corner of the
	// screen can never count a turn twice or lose one.
	// A turn that never reported anything — one that would not start, or one
	// killed before its first message — is not a turn that spent anything,
	// and does not become one in the count.
	spent: Usage
	if u := runner_usage(&t.runner); u != spent {
		u.turns = 1
		usage_bank(&app.usage, u)
	}
	runner_destroy(&t.runner)
	delete(t.session)
	delete(t.cwd)
	delete(t.project)
	delete(t.todo)
	delete(t.tool)
	delete(t.arg)
	delete(t.say)
	t^ = {}
}

// Called once a frame, after the events have been read out: a slot whose
// process has gone and whose last event has been applied is free again.
turns_reap :: proc(app: ^App) -> bool {
	freed := false
	for t, i in app.turns {
		if !t.live || !runner_settled(&t.runner) do continue
		// Cards whose turn died without ever saying Done or Failed would
		// otherwise read `processing` for good.
		if t.todo != "" && !t.ended do app_todo_finished(app, t.todo, .Open)
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

// Stops one turn, on purpose. The kill makes the process exit non-zero, which
// is indistinguishable from a crash unless we remember that we did it.
turn_stop :: proc(app: ^App, at: int) {
	t := app.turns[at]
	if !t.live do return
	t.stopped = true
	runner_stop(&t.runner)
}

// Stops every turn. Only quitting does this now: a key press must never be
// able to kill every process at once by falling through to it.
turns_stop_all :: proc(app: ^App) {
	for t, i in app.turns do if t.live do turn_stop(app, i)
}

turns_destroy :: proc(app: ^App) {
	// Every process first, then the waiting. Releasing a slot joins its
	// reader thread, which does not finish until its process has let go of
	// the pipe — so stopping them one at a time on the way out is one wait
	// after another instead of all of them at once.
	turns_stop_all(app)
	for t, i in app.turns do if t.live do turn_release(app, i)
	for t in app.turns do free(t)
	delete(app.turns)
}
