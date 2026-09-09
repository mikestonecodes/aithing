package aithing

import "core:os"
import "core:strings"
import "core:testing"

// What happens to a message typed into a thread that is already busy. It has
// been four things: dropped without a trace, which is indistinguishable from a
// broken Enter key; queued behind the running turn until that turn said it had
// ended, which left it there for good whenever one died without saying so;
// sent on the spot, which is two harnesses resuming one session, re-sending
// the whole conversation each and interleaving what they wrote; and now queued
// again — but behind the process rather than behind anything a turn has to
// remember to say, so a turn that vanishes frees its thread like any other.

@(private = "file")
stub_spawn :: proc(r: ^Runner, cwd, session_id, prompt, model, effort: string, slot: int) -> bool {
	r.running = true
	return true
}

// What thread the turns in flight are writing to, which is the only thing a
// test can read back: the tests run in parallel and `turn_spawn` is one
// global, so a stub that recorded what it was handed recorded whatever other
// test file's stub happened to be installed at the time.
@(private = "file")
live_in :: proc(app: ^App, session: string) -> int {
	n := 0
	for t in app.turns do if t.live && t.session == session do n += 1
	return n
}

// A turn that is over: the process has gone, which is all `session_running`
// asks, and all the queue waits for.
@(private = "file")
ended :: proc(t: ^Turn) {
	t.runner.running = false
}

@(private = "file")
scratch_app :: proc() -> ^App {
	app := new(App)
	app.status = ""
	turn_spawn = stub_spawn
	return app
}

// A turn already running in the thread on screen. Nothing is actually
// started — the flags are what app_submit reads.
@(private = "file")
busy_chat :: proc(app: ^App, session := "s-1") -> ^Turn {
	at := turn_slot(app)
	t := app.turns[at]
	t.live = true
	t.chat = true
	t.session = strings.clone(session)
	t.runner.running = true
	delete(app.chat.session_id)
	app.chat.session_id = strings.clone(session)
	return t
}

@(private = "file")
scratch_free :: proc(app: ^App) {
	editor_destroy(&app.editor)
	chat_destroy(&app.chat)
	delete(app.status)
	turns_destroy(app)
	free(app)
}

@(test)
send_while_busy_waits_for_the_turn_ahead :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	turn := busy_chat(app) // the thread on screen is already in flight

	editor_set_text(&app.editor, "the follow-up")
	app_send(app)

	// Nothing started: one turn, and the message waiting behind it.
	testing.expect_value(t, app_turns_live(app), 1)
	testing.expect_value(t, len(app.queued), 1)
	testing.expect_value(t, app.queued[0].session, "s-1")
	testing.expect_value(t, app.queued[0].prompt, "the follow-up")
	// The composer empties and the message appears in the transcript straight
	// away, so it never looks like the keystroke went nowhere.
	testing.expect_value(t, editor_text(&app.editor), "")
	testing.expect_value(t, len(app.chat.msgs), 1)
	// And the thread is still busy, because work is still coming — which is
	// what the card and the composer read.
	testing.expect(t, app_session_busy(app, "s-1"), "the thread stopped reading busy")

	// The turn ahead of it ends, and the pump sends it — resuming the same
	// thread, which is the whole reason it waited.
	ended(turn)
	_ = turns_reap(app)
	testing.expect(t, turns_pump(app))
	testing.expect_value(t, len(app.queued), 0)
	testing.expect_value(t, live_in(app, "s-1"), 1)
}

// Three in a row go out one at a time, in the order they were typed, all into
// the one thread.
@(test)
messages_go_out_one_at_a_time :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	turn := busy_chat(app)

	for text in ([?]string{"first", "second", "third"}) {
		editor_set_text(&app.editor, text)
		app_send(app)
	}
	testing.expect_value(t, len(app.queued), 3)
	testing.expect_value(t, len(app.chat.msgs), 3)

	ended(turn)
	_ = turns_reap(app)
	testing.expect(t, turns_pump(app))
	// One went out; the other two are still behind it, because the one that
	// went out is now the turn running in that thread.
	testing.expect_value(t, live_in(app, "s-1"), 1)
	testing.expect_value(t, len(app.queued), 2)
	testing.expect_value(t, app.queued[0].prompt, "second")

	ended(app.turns[turn_for_session(app, "s-1")])
	_ = turns_reap(app)
	testing.expect(t, turns_pump(app))
	testing.expect_value(t, len(app.queued), 1)
	testing.expect_value(t, app.queued[0].prompt, "third")
}

// A turn that dies without ever saying it ended still frees its thread. This
// is the failure that took the first queue out: the follow-up sat in it for
// good, because the only thing that would have released it was the turn
// saying something it never said.
@(test)
a_vanished_turn_still_lets_the_next_message_out :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	busy_chat(app)

	editor_set_text(&app.editor, "the follow-up")
	app_send(app)
	testing.expect_value(t, len(app.queued), 1)

	// No Done, no Failed: the process is simply gone, which is what the reap
	// looks for.
	app.turns[0].runner.running = false
	_ = turns_reap(app)
	testing.expect(t, turns_pump(app))
	testing.expect_value(t, len(app.queued), 0)
	testing.expect_value(t, live_in(app, "s-1"), 1)
}

// A message typed before the harness has named the thread. There is no session
// to wait for yet, so it waits for the turn and takes the name when the turn
// gives it up — it used to go out as it stood, which is a follow-up in a
// second thread of its own.
@(test)
a_message_typed_before_the_thread_is_named_still_lands_in_it :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	turn := busy_chat(app, "") // running, not named yet

	editor_set_text(&app.editor, "the follow-up")
	app_send(app)
	testing.expect_value(t, app_turns_live(app), 1)
	testing.expect_value(t, len(app.queued), 1)

	// Nothing to send while it has no name.
	testing.expect(t, !turns_pump(app))

	// The harness names it, the turn ends, and the message goes to that
	// thread.
	delete(turn.session)
	turn.session = strings.clone("s-named")
	ended(turn)
	_ = turns_reap(app)
	testing.expect(t, turns_pump(app))
	testing.expect_value(t, live_in(app, "s-named"), 1)
}

@(test)
empty_composer_sends_nothing :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	busy_chat(app)

	editor_set_text(&app.editor, "   \n  ")
	app_send(app)
	testing.expect_value(t, app_turns_live(app), 1)
	testing.expect_value(t, len(app.chat.msgs), 0)
}

// Sending says nothing on the status line. It used to write "thinking..."
// there, which only a Done from that same thread took off — so leaving the
// thread left the project page saying it over a grid of cards for good.
@(test)
sending_leaves_nothing_on_the_status_line :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)

	editor_set_text(&app.editor, "off it goes")
	app_send(app)

	testing.expect_value(t, app_turns_live(app), 1)
	testing.expect_value(t, app.status, "")
}

// Starting again on something you had put down. Dismissing a card takes it off
// the grid and files its thread; the search still finds that thread, so the
// way back to the work is to open it and say the next thing. That used to run
// the turn and leave the grid as empty as it was.
@(test)
send_into_a_cardless_thread_makes_a_card :: proc(t: ^testing.T) {
	_ = os.set_env("AITHING_CONFIG", "/tmp/aithing-test-config")
	app := scratch_app()
	defer scratch_free(app)
	defer todos_destroy(&app.todos)
	defer archive_destroy(&app.archive)
	app.chat.session_id = strings.clone("s-1")
	archive_set(&app.archive, "s-1", true) // the last card of it was dismissed

	editor_set_text(&app.editor, "pick this back up")
	app_send(app)

	testing.expect_value(t, len(app.todos.list), 1)
	testing.expect_value(t, app.todos.list[0].session, "s-1")
	testing.expect_value(t, app.todos.list[0].text, "pick this back up")
	// Not `waiting`: a turn went out for it.
	testing.expect_value(t, app.todos.list[0].state, Todo_State.Asked)
	// And the thread comes back out of the archive with it.
	testing.expect(t, !archive_is(&app.archive, "s-1"), "the thread is still filed away")

	// A second message is the same card's work, not another card.
	editor_set_text(&app.editor, "and this too")
	app_send(app)
	testing.expect_value(t, len(app.todos.list), 1)
}
