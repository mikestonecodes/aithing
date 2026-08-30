package aithing

import "core:testing"

// Typing a follow-up while a turn is still running used to do nothing at all:
// app_send returned early on a busy runner and the message was dropped without
// a trace, which is indistinguishable from a broken Enter key. These pin the
// behaviour that replaced it.

@(private = "file")
scratch_app :: proc() -> ^App {
	app := new(App)
	app.selected = -1
	app.status = ""
	return app
}

@(private = "file")
scratch_free :: proc(app: ^App) {
	editor_destroy(&app.editor)
	chat_destroy(&app.chat)
	for &p in app.queue {
		delete(p.prompt)
		delete(p.session)
		delete(p.cwd)
	}
	delete(app.queue)
	delete(app.status)
	delete(app.run_session)
	free(app)
}

@(test)
send_while_busy_queues :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	app.runner.running = true // a turn is in flight

	editor_set_text(&app.editor, "the follow-up")
	app_send(app)

	testing.expect_value(t, len(app.queue), 1)
	testing.expect_value(t, app.queue[0].prompt, "the follow-up")
	// The composer empties and the message appears in the transcript straight
	// away, so it never looks like the keystroke went nowhere.
	testing.expect_value(t, editor_text(&app.editor), "")
	testing.expect_value(t, len(app.chat.msgs), 1)
	// And it is marked, so the bubble can say it has not gone out yet.
	testing.expect_value(t, app.chat.msgs[0].queued, true)
}

@(test)
queue_keeps_the_order_typed :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	app.runner.running = true

	for text in ([?]string{"first", "second", "third"}) {
		editor_set_text(&app.editor, text)
		app_send(app)
	}

	testing.expect_value(t, len(app.queue), 3)
	testing.expect_value(t, app.queue[0].prompt, "first")
	testing.expect_value(t, app.queue[2].prompt, "third")
}

@(test)
interrupt_drops_the_queue :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	app.runner.running = true

	editor_set_text(&app.editor, "never sent")
	app_send(app)
	testing.expect_value(t, len(app.queue), 1)

	// Esc stops the turn; whatever was lined up behind it should not then go
	// out on its own, and should stop claiming it is about to.
	app_queue_clear(app)
	testing.expect_value(t, len(app.queue), 0)
	testing.expect_value(t, app.chat.msgs[0].queued, false)
}

@(test)
empty_composer_queues_nothing :: proc(t: ^testing.T) {
	app := scratch_app()
	defer scratch_free(app)
	app.runner.running = true

	editor_set_text(&app.editor, "   \n  ")
	app_send(app)
	testing.expect_value(t, len(app.queue), 0)
}
