package aithing

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// The card flow, pinned. Every one of these is here because the behaviour it
// describes was once wrong in a way that showed: cards that came back after
// being dismissed, a list that ran one of its parts and abandoned the rest, a
// grid that rearranged itself while nobody touched it.

@(private = "file")
scratch_dir :: proc(t: ^testing.T) {
	dir := "/tmp/aithing-test-config"
	os.make_directory_all(dir)
	_ = os.set_env("AITHING_CONFIG", dir)
}

@(private = "file")
fake_session :: proc(id, title: string) -> Session {
	return Session{id = id, title = title, cwd = "/tmp/proj", mtime = time.now(), size = 100}
}

// Every slot taken, so nothing starts underneath a test. Nothing is really
// started: these flags are what the bookkeeping reads.
@(private = "file")
fill_slots :: proc(app: ^App) {
	for &t in app.turns {
		t.live = true
		t.runner.running = true
	}
}

// A slot stood up without a process behind it: enough to test the bookkeeping
// that decides which card is running and which is waiting.
@(private = "file")
turn_start_stub :: proc(app: ^App, batch: string) -> bool {
	at := turn_slot(app)
	if at < 0 do return false
	app.turns[at] = Turn {
		live    = true,
		session = strings.clone("s"),
		cwd     = strings.clone("/tmp"),
		batch   = strings.clone(batch),
	}
	app.turns[at].runner.running = true
	return true
}

@(private = "file")
scratch_free :: proc(app: ^App) {
	editor_destroy(&app.capture)
	editor_destroy(&app.search)
	for id in app.run_queue do delete(id)
	for id in app.pending_dismiss do delete(id)
	delete(app.todo_view)
	delete(app.visible)
	delete(app.pending_open)
	delete(app.status)
	turns_destroy(app)
	load_destroy(&app.load)
	chat_destroy(&app.chat)
	delete(app.cwd)
	app_notes_destroy(app)
	archive_destroy(&app.archive)
	groups_destroy(&app.groups)
	canvas_destroy(&app.canvas)
	todos_destroy(&app.todos)
	delete(app.sessions)
	free(app)
}

@(private = "file")
scratch_app :: proc() -> ^App {
	app := new(App)
	app.selected = -1
	app.cwd = strings.clone("")
	return app
}

// --- dismissing ------------------------------------------------------------

// Dismissing a card writes down what it was, so nothing can put it back.
@(test)
a_dismissed_card_stays_gone :: proc(t: ^testing.T) {
	td: Todos
	defer todos_destroy(&td)

	id := todos_add(&td, "rebake the atlas", "sess-1", "/tmp/proj")
	testing.expect_value(t, len(td.list), 1)
	testing.expect(t, todos_has(&td, "sess-1"))

	todos_dismiss(&td, id)
	testing.expect_value(t, len(td.list), 0)
	testing.expect(t, !todos_has(&td, "sess-1"))
	// By its thread and its wording, folded — so the same item worded another
	// way is still the item that was dismissed, and the same words in another
	// thread are not.
	testing.expect(t, todos_dismissed(&td, item_key("sess-1", "Rebake the atlas.")))
	testing.expect(t, !todos_dismissed(&td, item_key("sess-2", "rebake the atlas")))
}

// The record has to outlast the process: a card that came back on the next
// launch would be no better than one that came back on the next scan.
@(test)
dismissals_persist :: proc(t: ^testing.T) {
	// Its own file, named here: these tests run alongside each other and a
	// shared one would be read back with somebody else's list in it.
	path := "/tmp/aithing-test-dismissals"
	{
		td: Todos
		defer todos_destroy(&td)
		id := todos_add(&td, "rebake the atlas", "sess-3", "/tmp/proj")
		todos_dismiss(&td, id)
		td.dirty = true
		todos_save(&td, path)
	}
	back: Todos
	defer todos_destroy(&back)
	todos_load(&back, path)
	testing.expect_value(t, len(back.list), 0)
	testing.expect(t, todos_dismissed(&back, item_key("sess-3", "rebake the atlas")))
}

// The x, all the way through: the press is recorded during the frame, acted
// on once the frame is over, the item is written down as dismissed, and the
// thread it was the last card of is filed away.
@(test)
x_on_a_card_survives_the_next_scan :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 1)
	sessions[0] = fake_session("sess-x", "the caret sits low")
	app.sessions = sessions

	todos_add(&app.todos, "the caret sits low", "sess-x", "/tmp/proj")
	app_filter(app)
	testing.expect_value(t, len(app.todos.list), 1)

	app_dismiss_todo(app, app.todos.list[0].id)
	testing.expect_value(t, len(app.pending_dismiss), 1)
	_ = app_apply_clicks(app)
	testing.expect_value(t, len(app.todos.list), 0)

	// The scans that follow put nothing back — nothing makes cards out of
	// threads, and it is written down besides.
	for _ in 0 ..< 3 {
		app_sync_todos(app)
		app_filter(app)
	}
	testing.expect_value(t, len(app.todos.list), 0)
	testing.expect(t, todos_dismissed(&app.todos, item_key("sess-x", "the caret sits low")))
	// It also goes off the map, rather than only off the grid.
	testing.expect(t, archive_is(&app.archive, "sess-x"))
}

// --- the store -------------------------------------------------------------

// A card and everything about it survives the round trip through the file.
@(test)
cards_round_trip :: proc(t: ^testing.T) {
	path := "/tmp/aithing-test-roundtrip"
	{
		td: Todos
		defer todos_destroy(&td)
		first := todos_add(&td, "one", "", "/tmp/proj")
		todos_add(&td, "two\twith a tab", "", "/tmp/proj", batch = first)
		todos_batch_session(&td, first, "sess-r", "/tmp/proj")
		todos_batch_state(&td, first, .Done)
		td.dirty = true
		todos_save(&td, path)
	}
	back: Todos
	defer todos_destroy(&back)
	todos_load(&back, path)
	testing.expect_value(t, len(back.list), 2)
	testing.expect_value(t, back.list[0].session, "sess-r")
	testing.expect_value(t, back.list[1].batch, back.list[0].id)
	// A tab is what the file splits on, so an item never carries one.
	testing.expect_value(t, back.list[1].text, "two with a tab")
	testing.expect_value(t, back.list[0].state, Todo_State.Done)
	testing.expect(t, todos_has(&back, "sess-r"))
}

// Every card of a batch takes the thread the harness hands back, and the
// count of what each thread carries keeps up with it.
@(test)
a_batch_takes_one_thread :: proc(t: ^testing.T) {
	td: Todos
	defer todos_destroy(&td)
	first := todos_add(&td, "bake the atlas", "", "/tmp/proj")
	todos_add(&td, "and ship it", "", "/tmp/proj", batch = first)
	testing.expect(t, !todos_has(&td, "sess-new"))

	todos_batch_session(&td, first, "sess-new", "/tmp/proj")
	testing.expect_value(t, len(td.list), 2)
	for item in td.list do testing.expect_value(t, item.session, "sess-new")
	testing.expect(t, todos_has(&td, "sess-new"))

	todos_remove(&td, td.list[0].id)
	testing.expect(t, todos_has(&td, "sess-new")) // one of them is still on it
	todos_remove(&td, td.list[0].id)
	testing.expect(t, !todos_has(&td, "sess-new"))
}

// --- typing a list ----------------------------------------------------------

// Enter over a written list: every part becomes a card, and all of them ride
// on one thread. The split is what the grid is made of — a list typed in one
// go is one piece of work said in several sentences, and cutting it into
// several conversations would throw away what each part knows about the rest.
@(test)
capture_makes_one_thread_and_a_card_a_part :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	fill_slots(app) // nothing starts underneath the test

	editor_set_text(&app.capture, "fix the caret\nrebake the atlas\nship it")
	app_capture(app)

	testing.expect_value(t, len(app.todos.list), 3)
	// One turn, not three: one name in the queue, and every card wearing it.
	testing.expect_value(t, len(app.run_queue), 1)
	batch := app.todos.list[0].batch
	testing.expect_value(t, batch, app.todos.list[0].id)
	for item in app.todos.list do testing.expect_value(t, item.batch, batch)
	testing.expect_value(t, len(todos_batch(&app.todos, batch)), 3)

	// Every card of it says the same thing, because there is one turn.
	for item in app.todos.list {
		testing.expect_value(t, todo_display_state(app, item), Todo_State.Queued)
		testing.expect_value(t, todo_queue_pos(app, item.batch), 1)
	}

	// The thread the harness hands back is every card's thread, and it
	// finishes as one.
	todos_batch_session(&app.todos, batch, "sess-batch", "/tmp/proj")
	for item in app.todos.list do testing.expect_value(t, item.session, "sess-batch")
	app_batch_finished(app, batch, .Done)
	for item in app.todos.list do testing.expect_value(t, item.state, Todo_State.Done)
}

// Dismissing one card of a batch leaves the rest of it on its way; dismissing
// the last of them takes the turn out of the queue with it.
@(test)
dismissing_a_batch_card_leaves_the_rest :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	fill_slots(app)

	editor_set_text(&app.capture, "one\ntwo")
	app_capture(app)
	testing.expect_value(t, len(app.run_queue), 1)

	app_dismiss_todo(app, app.todos.list[1].id)
	_ = app_apply_clicks(app)
	testing.expect_value(t, len(app.todos.list), 1)
	testing.expect_value(t, len(app.run_queue), 1) // the other card still wants it

	app_dismiss_todo(app, app.todos.list[0].id)
	_ = app_apply_clicks(app)
	testing.expect_value(t, len(app.todos.list), 0)
	testing.expect_value(t, len(app.run_queue), 0)
}

// --- turns ------------------------------------------------------------------

// Two lists typed one after the other are two threads, and they go out at the
// same time rather than one behind the other. This is what turn slots are for.
@(test)
separate_lists_run_in_parallel :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	for text in ([?]string{"one", "two", "three", "four", "five"}) {
		editor_set_text(&app.capture, text)
		app_capture(app)
	}
	testing.expect_value(t, len(app.run_queue), 5) // five lists, five threads

	for len(app.run_queue) > 0 && turn_slot(app) >= 0 {
		batch := app.run_queue[0]
		ordered_remove(&app.run_queue, 0)
		testing.expect(t, turn_start_stub(app, batch))
		delete(batch)
	}
	testing.expect_value(t, app_turns_live(app), MAX_TURNS)
	testing.expect_value(t, len(app.run_queue), 5 - MAX_TURNS)
	testing.expect_value(t, todo_display_state(app, app.todos.list[0]), Todo_State.Running)
	testing.expect_value(t, todo_display_state(app, app.todos.list[MAX_TURNS]), Todo_State.Queued)

	// A turn that ends without a word still frees the slot the next one needs.
	app.turns[0].runner.running = false
	turns_reap(app)
	testing.expect_value(t, app_turns_live(app), MAX_TURNS - 1)
	testing.expect(t, turn_slot(app) >= 0)
}

// --- the grid ---------------------------------------------------------------

// The same piece of work picked up in three threads is one card. A context
// that filled up, a window closed and opened again, a second run at it the
// next morning: three threads, three cards saying one thing, and three times
// as much grid for no more work.
@(test)
one_card_for_many_threads :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 3)
	sessions[0] = fake_session("s3", "third go")
	sessions[1] = fake_session("s2", "second go")
	sessions[2] = fake_session("s1", "first go")
	app.sessions = sessions

	// Cards are made in the order the work turns up, so the newest thread's
	// card is made last. One of them is worded differently, and one is only
	// in the newest thread.
	todos_add(&app.todos, "fix the caret", "s1", "/tmp/proj")
	todos_add(&app.todos, "Fix the caret.", "s2", "/tmp/proj")
	todos_add(&app.todos, "fix the caret", "s3", "/tmp/proj")
	todos_add(&app.todos, "rebake the atlas", "s3", "/tmp/proj")

	app_filter(app)

	// Two cards out of four items: the work, and the other work.
	testing.expect_value(t, len(app.todo_view), 2)
	testing.expect_value(t, app.todos.list[app.todo_view[0].todo].text, "rebake the atlas")
	testing.expect_value(t, app.todo_view[0].threads, 1)
	// The newest thread saying a thing is the card for it.
	testing.expect_value(t, app.todos.list[app.todo_view[1].todo].session, "s3")
	testing.expect_value(t, app.todo_view[1].threads, 3)

	// A search is asking to be shown everything by that name, folded or not:
	// what you went looking for is what you want found.
	editor_set_text(&app.search, "caret")
	app_filter(app)
	testing.expect_value(t, len(app.todo_view), 3)
}

// Where a card is put is where it stays. Nothing in the grid's order is a
// clock or a file size, so a turn taken in another window — which touches a
// thread's mtime, and used to be what the grid was sorted by — cannot move a
// card or reorder the projects under it.
@(test)
the_grid_does_not_move_on_its_own :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 2)
	sessions[0] = fake_session("z1", "zebra")
	sessions[0].cwd = "/tmp/zebra"
	sessions[1] = fake_session("a1", "apple")
	sessions[1].cwd = "/tmp/apple"
	app.sessions = sessions

	todos_add(&app.todos, "one", "z1", "/tmp/zebra")
	todos_add(&app.todos, "two", "a1", "/tmp/apple")
	todos_add(&app.todos, "three", "a1", "/tmp/apple")
	app_filter(app)

	before := make([]int, len(app.todo_view))
	defer delete(before)
	for ref, i in app.todo_view do before[i] = ref.todo
	// Projects come in a fixed order, not in the order they were last
	// touched, and inside one the newest card is first.
	testing.expect_value(t, app.todos.list[before[0]].cwd, "/tmp/apple")
	testing.expect_value(t, app.todos.list[before[0]].text, "three")
	testing.expect_value(t, app.todos.list[before[2]].cwd, "/tmp/zebra")

	// Every thread is touched, the way a turn in another window touches one,
	// and the list is handed over the other way round for good measure.
	for &sn in app.sessions do sn.mtime = time.now()
	slice.reverse(app.sessions)
	app_filter(app)

	testing.expect_value(t, len(app.todo_view), len(before))
	for ref, i in app.todo_view do testing.expect_value(t, ref.todo, before[i])
}

// Esc backs out of one thing at a time, and the project the grid is narrowed
// to is not one of them: it is a thing you said, and a press that missed
// everything else should not undo it.
@(test)
esc_leaves_the_project_filter_alone :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 2)
	sessions[0] = fake_session("a1", "one")
	sessions[1] = fake_session("b1", "two")
	sessions[1].cwd = "/tmp/other"
	app.sessions = sessions
	app.focus = .Capture

	canvas_filter_project(app, "/tmp/proj")
	testing.expect_value(t, len(app.visible), 1)

	// What is half-typed goes, and the view it was typed into stays.
	editor_set_text(&app.capture, "half a thought")
	_ = app_cancel(app)
	testing.expect_value(t, editor_text(&app.capture), "")
	testing.expect_value(t, app.canvas.project, "/tmp/proj")

	// And a press with nothing left to back out of changes nothing at all.
	_ = app_cancel(app)
	testing.expect_value(t, app.canvas.project, "/tmp/proj")
	testing.expect_value(t, len(app.visible), 1)
}

// The way in and the way out of a narrowed grid, end to end: `/`, a project
// row, then Esc. The launcher and the filter are separate pieces of state and
// getting the order wrong leaves one of them stuck on with nothing to clear
// it, which is what the strip along the top used to be for.
@(test)
launcher_narrows_and_esc_widens :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 2)
	sessions[0] = fake_session("a1", "one")
	sessions[1] = fake_session("b1", "two")
	sessions[1].cwd = "/tmp/other"
	app.sessions = sessions

	// `/` opens the launcher and the caret goes to its query.
	app_launcher(app, true)
	testing.expect(t, app.canvas.launcher)
	testing.expect_value(t, app.focus, Focus.Search)

	// A project row narrows the grid and shuts the launcher behind it.
	launcher_take(app, Hit{session = -1, cwd = "/tmp/proj", name = "proj"})
	testing.expect(t, !app.canvas.launcher)
	testing.expect_value(t, app.canvas.project, "/tmp/proj")
	testing.expect_value(t, len(app.visible), 1)

	// The way back out is offered where the narrowing was chosen, as the
	// first row of the launcher — not on Esc.
	app_launcher(app, true)
	hits := launcher_hits(app, "")
	testing.expect(t, len(hits) > 0)
	testing.expect_value(t, hits[0].name, "all projects")
	launcher_take(app, hits[0])
	testing.expect_value(t, app.canvas.project, "")
	testing.expect_value(t, len(app.visible), 2)
}

// A card whose thread the last scan knew nothing about — one this window made
// itself a moment ago — still opens when it is clicked. The click used to be
// thrown away, and clicking the card again did nothing either.
@(test)
clicking_a_brand_new_thread_opens_it :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.sessions = make([]Session, 0)

	id := todos_add(&app.todos, "bake the atlas", "sess-fresh", "/tmp/proj")
	app_open_todo(app, id)
	testing.expect_value(t, app.pending_open, "sess-fresh")

	// The scan has not been round yet, so the click is held rather than lost,
	// and one is asked for.
	_ = app_apply_clicks(app)
	testing.expect_value(t, app.pending_open, "sess-fresh")
	testing.expect(t, app.rescan)

	// It lands, and the frame after it the click is honoured.
	delete(app.sessions)
	sessions := make([]Session, 1)
	sessions[0] = fake_session("sess-fresh", "bake the atlas")
	app.sessions = sessions
	_ = app_apply_clicks(app)
	testing.expect_value(t, app.pending_open, "")
	testing.expect_value(t, app.chat.session_id, "sess-fresh")
}

// A turn that could not be started is not a turn that failed. A slot or a
// pipe this window could not get hold of just now says nothing about the
// work, and the card used to read `failed` while the turns beside it carried
// on processing.
@(test)
no_slot_is_not_a_failure :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)
	batch := app.todos.list[0].batch
	testing.expect_value(t, len(app.run_queue), 1)

	// Every slot taken, so there is nowhere for it to go.
	fill_slots(app)
	testing.expect(t, !app_pump_todos(app))
	// Still queued, still waiting, and not called a failure.
	testing.expect_value(t, len(app.run_queue), 1)
	testing.expect_value(t, app.run_queue[0], batch)
	testing.expect_value(t, app.todos.list[0].state, Todo_State.Queued)
	testing.expect_value(t, todo_display_state(app, app.todos.list[0]), Todo_State.Queued)
}

// Esc on the grid does not stop work. It used to fall through to stopping
// every turn in flight, and a killed `claude` exits non-zero, which arrives
// as a failure — so a press that found nothing else to give up turned four
// running cards red at once, for no reason anyone could see.
@(test)
esc_on_the_grid_stops_nothing :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")
	app.focus = .Capture

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)
	batch := app.todos.list[0].batch
	testing.expect(t, turn_start_stub(app, batch))
	testing.expect_value(t, todo_display_state(app, app.todos.list[0]), Todo_State.Running)

	// Nothing to back out of, so nothing happens — and above all the turn
	// keeps running.
	_ = app_cancel(app)
	testing.expect_value(t, app_turns_live(app), 1)
	testing.expect(t, !app.turns[0].stopped)
	testing.expect_value(t, todo_display_state(app, app.todos.list[0]), Todo_State.Running)
}

// Taking the last card of a piece of work off the grid stops the turn running
// it. This is the deliberate way to stop one, and the difference between it
// and what Esc used to do is that you meant it.
@(test)
dismissing_the_last_card_stops_its_turn :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "one\ntwo")
	app_capture(app)
	batch := app.todos.list[0].batch
	testing.expect(t, turn_start_stub(app, batch))

	// One of two: the other card still wants the turn.
	app_dismiss_todo(app, app.todos.list[1].id)
	_ = app_apply_clicks(app)
	testing.expect(t, !app.turns[0].stopped)

	app_dismiss_todo(app, app.todos.list[0].id)
	_ = app_apply_clicks(app)
	testing.expect(t, app.turns[0].stopped)
}

// A turn we killed is not a turn that failed. The kill makes the process exit
// non-zero, which is what the harness reports, and a card that went red
// because you stopped it is a card telling you something untrue.
@(test)
a_stopped_turn_is_not_a_failure :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)
	batch := app.todos.list[0].batch
	testing.expect(t, turn_start_stub(app, batch))
	turn_stop(app, 0)

	// What a killed `claude` looks like coming back.
	ev := Event{kind = .Failed, text = strings.clone("claude exited with 143")}
	defer event_destroy(&ev)
	app_apply_event_for_test(app, 0, &ev)

	testing.expect_value(t, app.todos.list[0].state, Todo_State.Open)
	testing.expect_value(t, app.notes[batch], "stopped")
}

// A card lands in the project you are working in. Opening a thread is saying
// which project that is; work written down afterwards belongs to it, and used
// to go to whatever directory the window happened to be launched from.
@(test)
a_card_lands_in_the_project_you_are_in :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/home/mike/Source/aithing")
	sessions := make([]Session, 1)
	sessions[0] = fake_session("tmm-1", "playback tree")
	sessions[0].cwd = "/home/mike/Source/toomanymachines"
	app.sessions = sessions

	// Typed with nothing open: it goes where the window was launched.
	editor_set_text(&app.capture, "one")
	app_capture(app)
	testing.expect_value(t, app.todos.list[0].cwd, "/home/mike/Source/aithing")

	// Now a thread in another project is opened, which is where the work is.
	app_open(app, 0)
	testing.expect_value(t, app.cwd, "/home/mike/Source/toomanymachines")
	editor_set_text(&app.capture, "two")
	app_capture(app)
	testing.expect_value(t, app.todos.list[1].cwd, "/home/mike/Source/toomanymachines")

	// The grid narrowed to a project still wins: it is the more recent thing
	// said about where you are.
	canvas_filter_project(app, "/home/mike/Source/aithing")
	editor_set_text(&app.capture, "three")
	app_capture(app)
	testing.expect_value(t, app.todos.list[2].cwd, "/home/mike/Source/aithing")
}

// The keyboard cursor holds a card, never a thread. It used to be handed a
// session id when a card was opened, so it pointed at nothing: the arrows
// started from scratch and ctrl c on the grid found no card to stop.
@(test)
the_cursor_holds_a_card :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 1)
	sessions[0] = fake_session("sess-c", "a thread")
	app.sessions = sessions

	id := todos_add(&app.todos, "bake the atlas", "sess-c", "/tmp/proj")
	app_filter(app)
	app_open_todo(app, id)

	testing.expect_value(t, app.canvas.sel, id)
	testing.expect(t, app.canvas.sel != "sess-c")
	// Which is what ctrl c on the grid looks the card up by.
	testing.expect(t, todos_find(&app.todos, app.canvas.sel) >= 0)
}
