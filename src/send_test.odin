package aithing

import "core:testing"

// What happens to a message typed into a thread that is already busy. It has
// been three things: dropped without a trace, which is indistinguishable from
// a broken Enter key; held in a queue until the turn ahead of it finished,
// which left it there for good whenever that turn ended in a way nothing
// noticed; and now sent, on the spot, like every other message.

@(private = "file")
stub_spawn :: proc(r: ^Runner, cwd, session_id, prompt, model, effort: string, slot: int) -> bool {
	r.running = true
	return true
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
busy_chat :: proc(app: ^App) {
	at := turn_slot(app)
	t := app.turns[at]
	t.live = true
	t.chat = true
	t.runner.running = true
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
send_while_busy_goes_out_anyway :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	busy_chat(app) // the thread on screen is already in flight

	editor_set_text(&app.editor, "the follow-up")
	app_send(app)

	// A second turn, started beside the first rather than lined up behind it.
	testing.expect_value(t, app_turns_live(app), 2)
	// The composer empties and the message appears in the transcript straight
	// away, so it never looks like the keystroke went nowhere.
	testing.expect_value(t, editor_text(&app.editor), "")
	testing.expect_value(t, len(app.chat.msgs), 1)
}

// Three in a row are three turns, not a queue two deep behind one.
@(test)
every_message_starts_its_own_turn :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	busy_chat(app)

	for text in ([?]string{"first", "second", "third"}) {
		editor_set_text(&app.editor, text)
		app_send(app)
	}
	testing.expect_value(t, app_turns_live(app), 4)
	testing.expect_value(t, len(app.chat.msgs), 3)
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
