package aithing

import "core:strings"

// A window used to run exactly one `claude -p` and make everything else wait
// behind it. Four cards typed into the box then went out one at a time, which
// is four times as long as it needs to be when the four are unrelated pieces
// of work in unrelated threads.
//
// So a turn is a slot, and there are several. Each holds its own process, its
// own reader thread and its own event list. The slots are a fixed array and
// are never moved or compacted: the reader thread holds a pointer into its
// own slot, and a list that shuffled itself under one would be a
// use-after-free the moment a turn finished. A slot that has settled is
// reused where it stands.
//
// A turn started from the grid is headless. It runs in a thread of its own on
// disk, the cards say how it is going, and clicking one opens the thread once
// the harness has named it. Only the turn a person typed into the composer
// draws into the transcript, because there is only one transcript on screen.
//
// A turn carries a batch rather than a card, because a list typed into the box
// is one piece of work said in several sentences: one thread, and a card for
// each of the things said in it.

// How many turns can be in flight at once. Four cards go out together; the
// fifth waits. They are separate processes in separate threads, but nothing
// stops two of them being pointed at the same working directory, so this is
// also the ceiling on how many things can be editing one checkout at once.
MAX_TURNS :: 4

Turn :: struct {
	runner:  Runner,
	live:    bool, // holds a process, or events not yet read out of one
	session: string, // the thread it writes to, "" until the harness names one
	cwd:     string,
	batch:   string, // the cards it is running, "" when a person typed it
	chat:    bool, // its output belongs in the transcript on screen
	// What it is doing right now: the tool it is running and what it is
	// running it on. A headless turn has no transcript anyone can look at, so
	// the one line that says where it has got to has to be caught off the
	// stream as it goes past — and the cards are where it is read.
	tool:    string,
	arg:     string,
	// Stopped by hand, so the non-zero exit that follows is not a failure of
	// the work and must not be reported as one.
	stopped: bool,
	// Already accounted for. The harness can say Failed and then Done for one
	// turn, and the cards must take the first of those and not the second —
	// and the sweep that catches a turn dying silently must not undo either.
	ended:   bool,
}

// --- finding one --------------------------------------------------------------

// A slot with nothing in it, or -1 when every turn is busy.
turn_slot :: proc(app: ^App) -> int {
	for &t, i in app.turns do if !t.live do return i
	return -1
}

turn_for_session :: proc(app: ^App, session: string) -> int {
	if session == "" do return -1
	for &t, i in app.turns do if t.live && t.session == session do return i
	return -1
}

turn_for_batch :: proc(app: ^App, batch: string) -> int {
	if batch == "" do return -1
	for &t, i in app.turns do if t.live && t.batch == batch do return i
	return -1
}

// The turn drawing into the transcript on screen, or -1.
turn_chat :: proc(app: ^App) -> int {
	for &t, i in app.turns do if t.live && t.chat do return i
	return -1
}

app_turns_live :: proc(app: ^App) -> int {
	n := 0
	for &t in app.turns do if t.live do n += 1
	return n
}

// Anything at all in flight. This is the one the frame loop and the reload
// ask: a window with a turn running has to keep drawing, and must not exec
// over itself.
app_busy :: proc(app: ^App) -> bool {
	for &t in app.turns do if t.live && runner_busy(&t.runner) do return true
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

// The line a card shows while its turn runs.
turn_doing :: proc(t: ^Turn, allocator := context.temp_allocator) -> string {
	if t.tool == "" do return "working"
	if t.arg == "" do return t.tool
	return strings.concatenate({t.tool, "  ", t.arg}, allocator)
}

// --- running one ----------------------------------------------------------------

// Takes a slot and starts a turn in it. `session` empty is a new thread,
// `batch` names the cards it is running, and `chat` says its output is wanted
// in the transcript on screen. False means no slot, or a harness that would
// not start.
turn_start :: proc(app: ^App, cwd, session, prompt, batch: string, chat: bool) -> bool {
	at := turn_slot(app)
	if at < 0 do return false
	// One transcript, so at most one turn drawing into it.
	if chat do for &other in app.turns do other.chat = false
	t := &app.turns[at]
	t^ = Turn {
		live    = true,
		session = strings.clone(session),
		cwd     = strings.clone(cwd),
		batch   = strings.clone(batch),
		chat    = chat,
	}
	if !runner_start(&t.runner, cwd, session, prompt, model_flag[app.model], at) {
		turn_release(app, at)
		return false
	}
	return true
}

// Gives a slot back. Only ever called on a turn that has settled — no process
// and no events left — because the reader thread is holding a pointer to the
// runner inside it until then.
turn_release :: proc(app: ^App, at: int) {
	t := &app.turns[at]
	runner_destroy(&t.runner)
	delete(t.session)
	delete(t.cwd)
	delete(t.batch)
	delete(t.tool)
	delete(t.arg)
	t^ = {}
}

// Called once a frame, after the events have been read out: a slot whose
// process has gone and whose last event has been applied is free again.
turns_reap :: proc(app: ^App) -> bool {
	freed := false
	for &t, i in app.turns {
		if !t.live || !runner_settled(&t.runner) do continue
		// Cards whose turn died without ever saying Done or Failed would
		// otherwise read `processing` for good.
		if t.batch != "" && !t.ended do app_batch_finished(app, t.batch, .Open)
		turn_release(app, i)
		freed = true
	}
	return freed
}

// The thread on screen changed, so which turn is allowed to draw into it did
// too. A turn whose thread is no longer open keeps running and keeps writing
// to its own session file; it just stops being drawn.
turns_rebind :: proc(app: ^App) {
	for &t in app.turns {
		t.chat = t.live && t.session != "" && t.session == app.chat.session_id
	}
}

// Stops one turn, on purpose. The kill makes the process exit non-zero, which
// is indistinguishable from a crash unless we remember that we did it.
turn_stop :: proc(app: ^App, at: int) {
	t := &app.turns[at]
	if !t.live do return
	t.stopped = true
	runner_stop(&t.runner)
}

// Stops every turn. Only quitting does this now: a key press must never be
// able to kill four processes at once by falling through to it.
turns_stop_all :: proc(app: ^App) {
	for &t, i in app.turns do if t.live do turn_stop(app, i)
}

turns_destroy :: proc(app: ^App) {
	// Every process first, then the waiting. Releasing a slot joins its
	// reader thread, which does not finish until its process has let go of
	// the pipe — so stopping them one at a time on the way out is four waits
	// end to end instead of four at once.
	turns_stop_all(app)
	for &t, i in app.turns do if t.live do turn_release(app, i)
}
