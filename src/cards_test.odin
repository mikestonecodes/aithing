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

// Where the tests' checkouts go, and it is one fixed path rather than a path
// per test on purpose: the runner runs tests in parallel and the cache is
// named by an environment variable, so two tests pointing it at two different
// directories at once is one of them looking for its trees in the other's.
// Every test that touches the cache sets it to this, and they all agree.
@(private = "file")
SCRATCH_CACHE :: "/tmp/aithing-test-cache"

@(private = "file")
scratch_cache :: proc() {
	_ = os.set_env("AITHING_CACHE", SCRATCH_CACHE)
}

@(private = "file")
fake_session :: proc(id, title: string) -> Session {
	return Session{id = id, title = title, cwd = "/tmp/proj", mtime = time.now(), size = 100}
}

// A turn without a process behind it. Cards start the moment they are asked
// for now, so every test that types into the capture box would otherwise run
// a real `claude` per card; this is what turn_spawn is pointed at instead.
@(private = "file")
stub_spawn :: proc(r: ^Runner, cwd, session_id, prompt, model, effort: string, slot: int) -> bool {
	r.running = true
	return true
}

// A slot stood up by hand, for the tests that want one turn on a card they
// name rather than whatever app_capture started.
@(private = "file")
turn_start_stub :: proc(app: ^App, todo: string) -> bool {
	// The slot first, then the array: taking one can grow app.turns, and the
	// index has to be read out of where it landed rather than where it was.
	at := turn_slot(app)
	t := app.turns[at]
	t^ = Turn {
		live    = true,
		session = strings.clone("s"),
		cwd     = strings.clone("/tmp"),
		todo    = strings.clone(todo),
	}
	t.runner.running = true
	return true
}

@(private = "file")
scratch_free :: proc(app: ^App) {
	editor_destroy(&app.capture)
	editor_destroy(&app.search)
	for id in app.pending_dismiss do delete(id)
	delete(app.todo_view)
	delete(app.visible)
	delete(app.open)
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
	usage_destroy(&app.usage)
	delete(app.sessions)
	free(app)
}

@(private = "file")
scratch_app :: proc() -> ^App {
	app := new(App)
	app.cwd = strings.clone("")
	turn_spawn = stub_spawn
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
		todos_add(&td, "two\twith a tab", "", "/tmp/proj")
		todo_set_session(&td, first, "sess-r", "/tmp/proj")
		todo_set_state(&td, first, .Done)
		td.dirty = true
		todos_save(&td, path)
	}
	back: Todos
	defer todos_destroy(&back)
	todos_load(&back, path)
	testing.expect_value(t, len(back.list), 2)
	testing.expect_value(t, back.list[0].session, "sess-r")
	// A tab is what the file splits on, so an item never carries one.
	testing.expect_value(t, back.list[1].text, "two with a tab")
	testing.expect_value(t, back.list[0].state, Todo_State.Done)
	testing.expect(t, todos_has(&back, "sess-r"))
}

// A card takes the thread the harness hands back, and only that card: the two
// typed beside it are their own conversations and keep their own.
@(test)
a_card_takes_its_own_thread :: proc(t: ^testing.T) {
	td: Todos
	defer todos_destroy(&td)
	first := todos_add(&td, "bake the atlas", "", "/tmp/proj")
	second := todos_add(&td, "and ship it", "", "/tmp/proj")
	testing.expect(t, !todos_has(&td, "sess-new"))

	todo_set_session(&td, first, "sess-new", "/tmp/proj")
	testing.expect_value(t, td.list[0].session, "sess-new")
	testing.expect_value(t, td.list[1].session, "")
	testing.expect(t, todos_has(&td, "sess-new"))

	todo_set_session(&td, second, "sess-other", "/tmp/proj")
	todos_remove(&td, second)
	testing.expect(t, !todos_has(&td, "sess-other"))
	testing.expect(t, todos_has(&td, "sess-new"))
	todos_remove(&td, first)
	testing.expect(t, !todos_has(&td, "sess-new"))
}

// --- typing a list ----------------------------------------------------------

// Enter over a written list: every part becomes a card, and every card its own
// thread. The parts used to be glued back into one prompt on one thread, and
// then nothing about that thread could be read, stopped or dismissed a card at
// a time.
@(test)
capture_makes_a_thread_a_part :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)

	editor_set_text(&app.capture, "fix the caret * rebake the atlas * ship it")
	app_capture(app)

	testing.expect_value(t, len(app.todos.list), 3)
	// Three turns, not one, and all three at once: none of them is waiting on
	// either of the others.
	testing.expect_value(t, app_turns_live(app), 3)
	for item in app.todos.list {
		testing.expect_value(t, todo_display_state(app, item), Todo_State.Running)
	}

	// The thread the harness hands one card is that card's alone, and it
	// finishes on its own.
	id := app.todos.list[0].id
	todo_set_session(&app.todos, id, "sess-one", "/tmp/proj")
	testing.expect_value(t, app.todos.list[0].session, "sess-one")
	testing.expect_value(t, app.todos.list[1].session, "")
	app_todo_finished(app, id, .Done)
	testing.expect_value(t, app.todos.list[0].state, Todo_State.Done)
	testing.expect_value(t, app.todos.list[1].state, Todo_State.Open)
}

// Dismissing one card stops its own turn and leaves the ones typed beside it
// running.
@(test)
dismissing_a_card_leaves_the_rest :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)

	editor_set_text(&app.capture, "one * two")
	app_capture(app)
	testing.expect_value(t, app_turns_live(app), 2)
	first := turn_for_todo(app, app.todos.list[0].id)
	second := turn_for_todo(app, app.todos.list[1].id)
	testing.expect(t, first >= 0 && second >= 0)

	app_dismiss_todo(app, app.todos.list[1].id)
	_ = app_apply_clicks(app)
	testing.expect_value(t, len(app.todos.list), 1)
	testing.expect(t, app.turns[second].stopped)
	testing.expect(t, !app.turns[first].stopped)

	app_dismiss_todo(app, app.todos.list[0].id)
	_ = app_apply_clicks(app)
	testing.expect_value(t, len(app.todos.list), 0)
	testing.expect(t, app.turns[first].stopped)
}

// --- turns ------------------------------------------------------------------

// Lists typed one after another are threads that all run at once, however
// many of them there are. There used to be four slots and a queue behind
// them, so the fifth thing asked for sat there saying `queued` while the
// machine did nothing about it.
@(test)
separate_lists_run_in_parallel :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	for text in ([?]string{"one", "two", "three", "four", "five", "six", "seven"}) {
		editor_set_text(&app.capture, text)
		app_capture(app)
	}
	testing.expect_value(t, app_turns_live(app), 7) // seven lists, seven threads
	for item in app.todos.list {
		testing.expect_value(t, todo_display_state(app, item), Todo_State.Running)
	}

	// A turn that ends without a word still gives its slot back, and the next
	// turn asked for takes it rather than making an eighth.
	app.turns[0].runner.running = false
	turns_reap(app)
	testing.expect_value(t, app_turns_live(app), 6)
	testing.expect_value(t, turn_slot(app), 0)
	testing.expect_value(t, len(app.turns), 7)
}

// --- the grid ---------------------------------------------------------------

// Every card is its own row. The grid used to fold cards worded alike down to
// one, with a count of how many threads were behind it — which meant the card
// you were looking at belonged to a thread you had not chosen, and dismissing
// it took away one of several. A card is a thread now, so there is nothing to
// fold.
@(test)
every_card_is_its_own_row :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 3)
	sessions[0] = fake_session("s3", "third go")
	sessions[1] = fake_session("s2", "second go")
	sessions[2] = fake_session("s1", "first go")
	app.sessions = sessions

	todos_add(&app.todos, "fix the caret", "s1", "/tmp/proj")
	todos_add(&app.todos, "Fix the caret.", "s2", "/tmp/proj")
	todos_add(&app.todos, "fix the caret", "s3", "/tmp/proj")
	todos_add(&app.todos, "rebake the atlas", "s3", "/tmp/proj")

	app_filter(app)
	testing.expect_value(t, len(app.todo_view), 4)
	// Newest first inside a project.
	testing.expect_value(t, app.todos.list[app.todo_view[0]].text, "rebake the atlas")

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
	for at, i in app.todo_view do before[i] = at
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
	for at, i in app.todo_view do testing.expect_value(t, at, before[i])
}

// Esc backs out of one thing at a time, and the project the grid is narrowed
// to is the last of them: what is half-typed goes first, and only a press
// with nothing else left to give up widens the grid again.
@(test)
esc_widens_the_grid_last :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 2)
	sessions[0] = fake_session("a1", "one")
	sessions[1] = fake_session("b1", "two")
	sessions[1].cwd = "/tmp/other"
	app.sessions = sessions

	canvas_filter_project(app, "/tmp/proj")
	testing.expect_value(t, len(app_visible(app)), 1)

	// What is half-typed goes, and the view it was typed into stays.
	editor_set_text(&app.capture, "half a thought")
	_ = app_cancel(app)
	testing.expect_value(t, editor_text(&app.capture), "")
	testing.expect_value(t, app.canvas.project, "/tmp/proj")

	// And the press after it, with nothing else left, is the way out of the
	// project.
	_ = app_cancel(app)
	testing.expect_value(t, app.canvas.project, "")
	testing.expect_value(t, len(app_visible(app)), 2)

	// Once widened there is nothing left to back out of, and Esc does nothing
	// at all.
	_ = app_cancel(app)
	testing.expect_value(t, app.canvas.project, "")
	testing.expect_value(t, len(app_visible(app)), 2)
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
	testing.expect_value(t, app.overlay, Overlay.Launcher)
	testing.expect_value(t, app_focus(app), Focus.Search)

	// A project row narrows the grid and shuts the launcher behind it.
	launcher_take(app, Hit{session = -1, cwd = "/tmp/proj", name = "proj"})
	testing.expect_value(t, app.overlay, Overlay.None)
	testing.expect_value(t, app.canvas.project, "/tmp/proj")
	testing.expect_value(t, len(app_visible(app)), 1)

	// The way back out is offered where the narrowing was chosen too, as the
	// first row of the launcher.
	app_launcher(app, true)
	hits := launcher_hits(app)
	testing.expect(t, len(hits) > 0)
	testing.expect_value(t, hits[0].name, "all projects")
	launcher_take(app, hits[0])
	testing.expect_value(t, app.canvas.project, "")
	testing.expect_value(t, len(app_visible(app)), 2)
}

// `/` on a grid that has been narrowed to nothing offers the projects before
// anything else, with nothing typed. It used to offer only threads until a
// query was typed, which is the one thing the grid behind the menu is already
// showing.
@(test)
launcher_opens_on_the_projects :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 3)
	sessions[0] = fake_session("a1", "one")
	sessions[1] = fake_session("b1", "two")
	sessions[1].cwd = "/tmp/other"
	sessions[2] = fake_session("c1", "three") // same project as a1
	app.sessions = sessions
	app_filter(app)

	hits := launcher_hits(app)
	testing.expect(t, len(hits) >= 3)
	// One row a project, newest first, and the second of a project's threads
	// counts towards the row rather than making another.
	testing.expect_value(t, hits[0].session, -1)
	testing.expect_value(t, hits[0].name, "proj")
	testing.expect_value(t, hits[0].count, 2)
	testing.expect_value(t, hits[1].session, -1)
	testing.expect_value(t, hits[1].name, "other")
	// Then the threads.
	testing.expect(t, hits[2].session >= 0)

	// Narrowed, the project you are in is not offered again: the row that
	// widens it is what the top of the menu is for.
	canvas_filter_project(app, "/tmp/proj")
	hits = launcher_hits(app)
	testing.expect_value(t, hits[0].name, "all projects")
	for hit in hits {
		testing.expect(t, !(hit.session < 0 && hit.cwd == "/tmp/proj"))
	}
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

// Clicking a card puts you in that card's thread and nothing else, even
// before the scan has heard of it. The page moved on the click and the
// transcript waited for the scan, so a card whose turn had just started —
// which is a file the scan skips, having nothing in it worth a title — left
// the last conversation you had open sitting there under the new card's
// click, wearing its own title, and a message typed into it went there.
@(test)
opening_a_card_leaves_no_other_thread_on_screen :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)

	sessions := make([]Session, 1)
	sessions[0] = fake_session("sess-old", "the last thing read")
	app.sessions = sessions

	// A thread is open and read.
	app_open(app, 0)
	testing.expect_value(t, app.chat.session_id, "sess-old")

	// Now a card whose thread nothing has scanned.
	id := todos_add(&app.todos, "bake the atlas", "sess-fresh", "/tmp/proj")
	app_open_todo(app, id)
	testing.expect_value(t, app.chat.session_id, "sess-fresh")
	testing.expect_value(t, len(app.chat.msgs), 0)
	testing.expect_value(t, app_chat_title(app), "bake the atlas")

	// And when the scan does land, the transcript is read: the empty chat put
	// up on the click must not be mistaken for one already open.
	_ = app_apply_clicks(app)
	testing.expect_value(t, app.pending_open, "sess-fresh")
	delete(app.sessions)
	fresh := make([]Session, 1)
	fresh[0] = fake_session("sess-fresh", "bake the atlas")
	app.sessions = fresh
	_ = app_apply_clicks(app)
	testing.expect_value(t, app.pending_open, "")
	testing.expect(t, load_busy(&app.load))
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

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)
	id := app.todos.list[0].id
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

	editor_set_text(&app.capture, "one * two")
	app_capture(app)

	// One of two: the other card's turn is its own and carries on.
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
	id := app.todos.list[0].id
	turn_stop(app, 0)

	// What a killed `claude` looks like coming back.
	ev := Event{kind = .Failed, text = strings.clone("claude exited with 143")}
	defer event_destroy(&ev)
	app_apply_event_for_test(app, 0, &ev)

	testing.expect_value(t, app.todos.list[0].state, Todo_State.Open)
	testing.expect_value(t, app.notes[id], "stopped")
}

// Reading along with a card changes nothing about what becomes of it. Opening
// one binds its turn to the transcript, and the failure path on that side used
// to mark the card without writing down why and without noticing the turn had
// been stopped on purpose — so the same turn ended `failed` with a reason on
// the grid and `failed` with nothing beside it if you happened to be watching.
@(test)
a_watched_turn_fails_the_same_way :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)
	id := app.todos.list[0].id

	// Its thread, opened: the turn now draws into the transcript. The harness
	// names the session a moment after the turn starts, which is what this is
	// standing in for.
	delete(app.turns[0].session)
	app.turns[0].session = strings.clone("s")
	app.chat.session_id = strings.clone("s")
	turns_rebind(app)
	testing.expect(t, app.turns[0].chat)

	ev := Event{kind = .Failed, text = strings.clone("claude exited with 1")}
	defer event_destroy(&ev)
	app_apply_event_for_test(app, 0, &ev)

	testing.expect_value(t, app.todos.list[0].state, Todo_State.Failed)
	testing.expect_value(t, app.notes[id], "claude exited with 1")
}

// And a turn stopped by hand is not a failure on that side either.
@(test)
a_stopped_turn_being_watched_is_not_a_failure :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)
	id := app.todos.list[0].id
	delete(app.turns[0].session)
	app.turns[0].session = strings.clone("s")
	app.chat.session_id = strings.clone("s")
	turns_rebind(app)
	turn_stop(app, 0)

	ev := Event{kind = .Failed, text = strings.clone("claude exited with 143")}
	defer event_destroy(&ev)
	app_apply_event_for_test(app, 0, &ev)

	testing.expect_value(t, app.todos.list[0].state, Todo_State.Open)
	testing.expect_value(t, app.notes[id], "stopped")
}

// A card lands in the project you are working in. Opening a thread is saying
// which project that is; work written down afterwards belongs to it, and used
// to go to whatever directory the window happened to be launched from.
@(test)
a_card_lands_in_the_project_you_are_in :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	// Directories that are nobody's repository. A card asked for is a card
	// started, and starting one cuts it a worktree in whatever project it is
	// filed under — so this test, which is only about which project that is,
	// used to leave a branch and a checkout in the repository it names every
	// time the suite ran.
	app.cwd = strings.clone("/tmp/proj-a")
	sessions := make([]Session, 1)
	sessions[0] = fake_session("tmm-1", "playback tree")
	sessions[0].cwd = "/tmp/proj-b"
	app.sessions = sessions

	// Typed with nothing open: it goes where the window was launched.
	editor_set_text(&app.capture, "one")
	app_capture(app)
	testing.expect_value(t, app.todos.list[0].cwd, "/tmp/proj-a")

	// Now a thread in another project is opened, which is where the work is.
	app_open(app, 0)
	testing.expect_value(t, app.cwd, "/tmp/proj-b")
	editor_set_text(&app.capture, "two")
	app_capture(app)
	testing.expect_value(t, app.todos.list[1].cwd, "/tmp/proj-b")

	// The grid narrowed to a project still wins: it is the more recent thing
	// said about where you are.
	canvas_filter_project(app, "/tmp/proj-a")
	editor_set_text(&app.capture, "three")
	app_capture(app)
	testing.expect_value(t, app.todos.list[2].cwd, "/tmp/proj-a")
}

// One variable says what is on screen, and Esc walks it back one step at a
// time. The four booleans this replaced had to be set together at every call
// site, and any two of them disagreeing was a screen you could get stuck on:
// the launcher up over a thread that had been closed underneath it, a picker
// still open on the grid, a caret in a box nobody could see.
@(test)
one_var_says_what_is_on_screen :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 1)
	sessions[0] = fake_session("sess-p", "a thread")
	app.sessions = sessions

	// A grid of every project takes no text at all; narrowed to one, it has
	// its box.
	testing.expect_value(t, app.page, Page.Grid)
	testing.expect_value(t, app_focus(app), Focus.None)
	canvas_filter_project(app, "/tmp/p")
	testing.expect_value(t, app_focus(app), Focus.Capture)
	canvas_filter_project(app, "")

	// The launcher goes over whatever page you were on, and opening a thread
	// from it shuts it: one call, and there is nothing left to disagree.
	app_launcher(app, true)
	testing.expect_value(t, app.overlay, Overlay.Launcher)
	testing.expect_value(t, app_focus(app), Focus.Search)
	canvas_open(app, "sess-p")
	testing.expect_value(t, app.page, Page.Thread)
	testing.expect_value(t, app.overlay, Overlay.None)
	testing.expect_value(t, app_focus(app), Focus.Composer)

	// The picker is over the thread, and Esc gives up one thing per press:
	// the picker, then the thread, and then there is nothing left to give up.
	app.overlay = .Model
	_ = app_cancel(app)
	testing.expect_value(t, app.overlay, Overlay.None)
	testing.expect_value(t, app.page, Page.Thread)
	_ = app_cancel(app)
	testing.expect_value(t, app.page, Page.Grid)
	testing.expect_value(t, app_focus(app), Focus.None)
}

// The box is under the grid exactly when the grid names one project, and it
// is the same answer the caret gets. It has been tried the other way twice:
// there only while narrowed, with nothing on screen saying so, which left a
// grid you could not type into and no hint why; and there always, with the
// project printed over it, which made every list you wrote start by reading
// a line to check where it was going. Narrowing is how you say where work
// goes, and the box appears when you have said it.
@(test)
the_box_is_under_the_grid :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)

	// A grid of every project: nowhere to type, and nothing kept clear for a
	// box that is not there.
	testing.expect(t, !app_capture_open(app))
	testing.expect_value(t, capture_height(app, 1200), 0)
	testing.expect_value(t, app_focus(app), Focus.None)

	canvas_filter_project(app, "/tmp/p")
	testing.expect(t, app_capture_open(app))
	testing.expect(t, capture_height(app, 1200) > 0)
	testing.expect_value(t, app_focus(app), Focus.Capture)

	// Not the launcher's business: the menu goes over the grid without
	// changing what the grid is, and a box that vanished under it would move
	// the cards while they are being read.
	app_launcher(app, true)
	testing.expect(t, app_capture_open(app))
	app_launcher(app, false)

	// The thread has its own composer, so the grid's box is not there either.
	app.page = .Thread
	testing.expect(t, !app_capture_open(app))

	// And shutting the thread puts it back: the project the grid is narrowed
	// to is not something closing a thread gives up.
	canvas_close(app)
	testing.expect(t, app_capture_open(app))
	testing.expect_value(t, app_focus(app), Focus.Capture)

	// Widening takes it away again, which is the whole of "exit to all
	// projects": every card on screen, and nothing on screen to type into.
	canvas_filter_project(app, "")
	testing.expect(t, !app_capture_open(app))
	testing.expect_value(t, app_focus(app), Focus.None)
}

// A card with a turn still running opens like any other. The click used to be
// swallowed by a special case that only moved the cursor onto it, so the one
// card you most want to read along with was the one card that would not open.
@(test)
a_busy_card_still_opens :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	sessions := make([]Session, 1)
	sessions[0] = fake_session("sess-busy", "a thread")
	app.sessions = sessions

	id := todos_add(&app.todos, "bake the atlas", "sess-busy", "/tmp/proj")
	testing.expect(t, turn_start_stub(app, id))
	delete(app.turns[0].session)
	app.turns[0].session = strings.clone("sess-busy")
	app_filter(app)

	app_open_todo(app, id)
	testing.expect_value(t, app.pending_open, "sess-busy")
	_ = app_apply_clicks(app)
	testing.expect_value(t, app.chat.session_id, "sess-busy")
	// And the turn writing that thread draws into the transcript now that it
	// is the thread on screen.
	testing.expect(t, app.turns[0].chat)
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

// --- what became of the work -----------------------------------------------

// A turn that stopped to ask something is not a turn that finished. `claude
// -p` exits zero either way, and the card read `complete` — dimmed, green,
// sitting on the grid next to the work that had actually been done — with the
// question it wanted answered nowhere on screen.
@(test)
a_turn_that_asked_is_not_complete :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)
	id := app.todos.list[0].id

	say := Event {
		kind    = .Verdict,
		verdict = .Blocked,
		text    = strings.clone("msdf or sdf?"),
	}
	defer event_destroy(&say)
	app_apply_event_for_test(app, 0, &say)

	done := Event{kind = .Done}
	defer event_destroy(&done)
	app_apply_event_for_test(app, 0, &done)

	testing.expect_value(t, app.todos.list[0].state, Todo_State.Asked)
	// And the question travels to the card: there is no transcript anyone is
	// watching, so the grid is the only place it can be read.
	testing.expect_value(t, app.notes[id], "msdf or sdf?")
}

// A turn that never said anything about its work is read the same way. The
// safe way round: an agent that did the work and forgot to say so costs a
// glance, and the other way round is the bug.
@(test)
a_silent_turn_is_not_complete :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)

	done := Event{kind = .Done}
	defer event_destroy(&done)
	app_apply_event_for_test(app, 0, &done)
	testing.expect_value(t, app.todos.list[0].state, Todo_State.Asked)
}

// And a turn that said it finished is complete, which is the whole point of
// asking.
@(test)
a_turn_that_said_done_is_complete :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)

	say := Event{kind = .Verdict, verdict = .Done, text = strings.clone("baked it")}
	defer event_destroy(&say)
	app_apply_event_for_test(app, 0, &say)
	done := Event{kind = .Done}
	defer event_destroy(&done)
	app_apply_event_for_test(app, 0, &done)

	testing.expect_value(t, app.todos.list[0].state, Todo_State.Done)
}

// The claim belongs to the message that made it. A turn that says it is done
// and then keeps writing has not said it about the message it ended on.
@(test)
a_later_message_takes_the_claim_back :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	editor_set_text(&app.capture, "bake the atlas")
	app_capture(app)

	say := Event{kind = .Verdict, verdict = .Done, text = strings.clone("baked it")}
	defer event_destroy(&say)
	app_apply_event_for_test(app, 0, &say)

	again := Event{kind = .Msg_Start}
	defer event_destroy(&again)
	app_apply_event_for_test(app, 0, &again)

	done := Event{kind = .Done}
	defer event_destroy(&done)
	app_apply_event_for_test(app, 0, &done)
	testing.expect_value(t, app.todos.list[0].state, Todo_State.Asked)
}

// A card you asked for never reads as one you have not. `waiting` is the word
// for a card nothing has started, and a turn that went away without ever
// saying Done or Failed used to be put back to it — so the grid showed a card
// indistinguishable from one you had never touched, and nothing anywhere said
// a turn had gone out for it at all. A turn that would not start in the first
// place is the same rule, in app_start_todo.
//
// Nothing should be able to reach this: the reader thread emits Done on its
// way out whatever happened to the process. Which is the reason to say so on
// the card rather than tidy it into the state a card starts life in.
@(test)
a_card_that_was_asked_for_never_says_waiting :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)
	app.cwd = strings.clone("/tmp")

	id := todos_add(&app.todos, "bake the atlas", "", "/tmp")
	testing.expect(t, turn_start_stub(app, id))
	testing.expect_value(t, todo_display_state(app, app.todos.list[0]), Todo_State.Running)

	// The process gone and nothing left to read out of it, with no ending
	// ever applied: what turns_reap is the last word on.
	for turn in app.turns do turn.runner.running = false
	turns_reap(app)
	testing.expect_value(t, app.todos.list[0].state, Todo_State.Failed)
	testing.expect_value(t, app.notes[id], "the turn ended without a word")
}

// The handshake never reaches the screen. A thread read back off disk has
// always had the marker taken off it, but a thread you had open while its turn
// finished watched `<aithing>done</aithing>` type itself out at the bottom —
// the transcript is written by the deltas, and nothing stripped those.
@(test)
the_marker_is_not_in_the_transcript :: proc(t: ^testing.T) {
	scratch_dir(t)
	app := scratch_app()
	defer scratch_free(app)

	at := turn_slot(app)
	app.turns[at]^ = Turn{live = true, chat = true, cwd = strings.clone("/tmp")}
	app.turns[at].runner.running = true

	start := Event{kind = .Block_Start, block_kind = .Text}
	defer event_destroy(&start)
	app_apply_event_for_test(app, at, &start)

	// In pieces, the way it arrives: the marker is one line and the deltas cut
	// it wherever the bytes happened to land, which is why nothing can strip
	// it until the block has stopped.
	for piece in ([]string{"baked it\n\n", "<aithing>", "done</aithing>"}) {
		d := Event{kind = .Delta, text = strings.clone(piece)}
		app_apply_event_for_test(app, at, &d)
		event_destroy(&d)
	}
	stop := Event{kind = .Block_Stop}
	defer event_destroy(&stop)
	app_apply_event_for_test(app, at, &stop)

	testing.expect_value(t, block_text(chat_block(&app.chat, Ref{0, 0, -1})), "baked it")
}

// Reading the marker off a message. The later of the two wins, so a message
// that quotes the instructions before using them still says what it meant.
@(test)
the_last_marker_is_the_verdict :: proc(t: ^testing.T) {
	testing.expect_value(t, verdict_read("nothing here"), Verdict.None)
	testing.expect_value(t, verdict_read("all built\n" + DONE_MARK), Verdict.Done)
	testing.expect_value(t, verdict_read("which one?\n" + BLOCK_MARK), Verdict.Blocked)
	testing.expect_value(
		t,
		verdict_read("say " + DONE_MARK + " when finished\n\nwhich one?\n" + BLOCK_MARK),
		Verdict.Blocked,
	)
	// What the card shows is the line under the work, not the marker.
	said := verdict_say("rebuilt the atlas\nmsdf or sdf?\n" + BLOCK_MARK)
	testing.expect_value(t, said, "msdf or sdf?")
}

// The preamble is ours, not the card's. Claude Code writes the prompt it was
// handed straight into the session file, so every read of that file that ends
// up on screen — the thread's title, the row under it, the transcript — was
// showing the instructions this program wrote to itself.
@(test)
the_preamble_is_not_what_was_typed :: proc(t: ^testing.T) {
	sent := verdict_preamble("bake the msdf atlas")
	testing.expect_value(t, verdict_unwrap(sent), "bake the msdf atlas")
	// Anything that did not come from us is left exactly as it is, markers
	// quoted inside it and all.
	testing.expect_value(t, verdict_unwrap("just a prompt"), "just a prompt")
	testing.expect_value(t, verdict_unwrap(DONE_MARK), DONE_MARK)
	// The handshake at the end of an answer is not part of the answer.
	testing.expect_value(t, verdict_unmark("built it\n\n" + DONE_MARK), "built it")
	testing.expect_value(t, verdict_unmark("which one?\n" + BLOCK_MARK), "which one?")
	testing.expect_value(t, verdict_unmark("nothing to strip"), "nothing to strip")
}

// The same read end to end, off a file shaped like the one the harness
// writes: the transcript of a card's thread shows what was typed on the card,
// with our half of the conversation out of the way at both ends.
@(test)
a_card_thread_reads_as_the_card :: proc(t: ^testing.T) {
	path := "/tmp/aithing-test-preamble.jsonl"
	body := strings.concatenate(
		{
			`{"type":"user","cwd":"/tmp/proj","message":{"role":"user","content":`,
			json_quote(verdict_preamble("bake the msdf atlas")),
			"}}\n",
			`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":`,
			json_quote("baked it\n\n" + DONE_MARK),
			"}]}}\n",
		},
		context.temp_allocator,
	)
	_ = os.write_entire_file(path, transmute([]byte)body)
	defer os.remove(path)

	s := Session {
		id   = "sess-p",
		path = path,
		size = i64(len(body)),
	}
	chat, ok := session_load(&s)
	defer chat_destroy(&chat)
	testing.expect(t, ok)
	testing.expect_value(t, len(chat.msgs), 2)
	testing.expect_value(t, block_text(chat_block(&chat, Ref{0, 0, -1})), "bake the msdf atlas")
	testing.expect_value(t, block_text(chat_block(&chat, Ref{1, 0, -1})), "baked it")
}

// JSON string literal, for the fixture above: the preamble is several lines
// with quotes in it, and a session file holds it as one.
@(private = "file")
json_quote :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(text) {
		switch c := text[i]; c {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case:
			strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// A card whose turn ran in a worktree still belongs to the project the tree
// was cut from. Filing it under the tree put the work in a directory under
// the cache that nothing else on the grid shared.
@(test)
a_worktree_is_not_a_project :: proc(t: ^testing.T) {
	scratch_dir(t)
	scratch_cache()
	app := scratch_app()
	defer scratch_free(app)

	id := todos_add(&app.todos, "bake the atlas", "sess-w", "/tmp/proj")
	tree := worktree_path("/tmp/proj", id, context.temp_allocator)
	testing.expect_value(t, worktree_project(app, tree), "/tmp/proj")
	// Anywhere else is itself, whatever it is called.
	testing.expect_value(t, worktree_project(app, "/tmp/proj"), "/tmp/proj")
}

// Only this program's own repository is worth a build, and the answer comes
// off where the binary sits rather than off anything written down. A window
// run out of one checkout and asked about another used to be the same
// question as "did a turn just finish", which every landing anywhere answered
// yes to.
@(test)
only_this_windows_own_project_is_rebuilt :: proc(t: ^testing.T) {
	build_init()
	defer build_destroy()
	// The test binary sits in a directory of its own, and that is the repo as
	// far as this is concerned: what matters is that it is exactly one place
	// and that nowhere else matches it.
	testing.expect(t, !build_is_own("/tmp/proj"), "a stranger's project asked for a build")
	testing.expect(t, !build_is_own(""), "nowhere at all asked for a build")
}

// --- giving a tree back -------------------------------------------------------

// A real repository and a real cache, because what is being pinned below is
// what git does: the whole of the policy about which trees may go is which
// ones git refuses to remove, and a fake git would pin our opinion of it
// instead.
//
// One test, not three: the sweep walks everything under the cache root, and
// the tests share one — a second test's trees would be swept as readily as
// its own.
@(test)
a_finished_card_gives_its_tree_back :: proc(t: ^testing.T) {
	scratch_dir(t)
	scratch_cache()
	cache := SCRATCH_CACHE
	repo := "/tmp/aithing-test-repo"
	if !testing.expect(t, run(t, "rm", "-rf", cache, repo), "could not clear the scratch dirs") {
		return
	}
	os.make_directory_all(repo)
	made :=
		run(t, "git", "-C", repo, "init", "-q") &&
		run(t, "git", "-C", repo, "config", "user.email", "test@example.com") &&
		run(t, "git", "-C", repo, "config", "user.name", "test") &&
		os.write_entire_file(strings.concatenate({repo, "/f"}, context.temp_allocator), "a") ==
			nil &&
		run(t, "git", "-C", repo, "add", "f") &&
		run(t, "git", "-C", repo, "commit", "-qm", "one")
	if !testing.expect(t, made, "git is needed for this one") do return

	app := scratch_app()
	defer scratch_free(app)

	// A finished card's checkout does not sit in the cache for good. It goes,
	// its branch goes with it while the branch has nothing in it, and asking
	// for the card again checks it out afresh.
	id := todos_add(&app.todos, "bake the atlas", "sess-w", repo)
	tree, why := worktree_for(repo, id, context.temp_allocator)
	testing.expect_value(t, why, "")
	testing.expect(t, os.exists(tree), "the tree was not made")
	testing.expect(t, !worktree_idle(&app.todos, id), "an open card is still working in it")
	todo_set_state(&app.todos, id, .Done)
	testing.expect(t, worktree_idle(&app.todos, id), "a finished card is not")
	testing.expect(t, worktree_release(repo, id), "the tree did not go")
	testing.expect(t, !os.exists(tree), "the tree is still there")
	testing.expect(t, !has_branch(t, repo, id), "an empty branch was left behind")
	again, _ := worktree_for(repo, id, context.temp_allocator)
	testing.expect_value(t, again, tree)
	testing.expect(t, os.exists(tree), "the tree did not come back")

	// The other half of the rule: git decides, and git will not remove a tree
	// with anything in it that is not committed. Removing them regardless was
	// the version of this that could lose an afternoon.
	_ = os.write_entire_file(
		strings.concatenate({tree, "/half-done"}, context.temp_allocator),
		"x",
	)
	testing.expect(t, !worktree_release(repo, id), "git should have refused")
	testing.expect(t, os.exists(tree), "an afternoon of work was thrown away")

	// Committed, and the tree may go — and the branch stays, because the
	// commits are what makes it worth keeping, not the checkout.
	run(t, "git", "-C", tree, "add", "half-done")
	run(t, "git", "-C", tree, "commit", "-qm", "half")
	testing.expect(t, worktree_release(repo, id), "a committed tree may go")
	testing.expect(t, !os.exists(tree), "the tree is still there")
	testing.expect(t, has_branch(t, repo, id), "the commits went with the tree")

	// Landing it, which is what a card finishing actually does: the work goes
	// back into the branch the project is on, uncommitted or not, and only
	// then does the tree go. Nothing ever merged one before, so a week of
	// green cards was a week of `aithing/n-*` branches to go through by hand.
	land := todos_add(&app.todos, "wire it up", "s-land", repo)
	land_tree, _ := worktree_for(repo, land, context.temp_allocator)
	_ = os.write_entire_file(join(land_tree, "wired"), "y")
	landed, _ := worktree_land(repo, land, "wire it up")
	testing.expect_value(t, landed, "")
	testing.expect(t, os.exists(join(repo, "wired")), "the work never reached the project")
	todo_set_state(&app.todos, land, .Done)
	testing.expect(t, worktree_release(repo, land), "a landed tree may go")
	testing.expect(t, !has_branch(t, repo, land), "a landed branch was left behind")

	// And what happens when it will not go back. Two cards cut from the same
	// commit, both editing the same line: the first lands, the second cannot,
	// and the second keeps everything — the whole point of resolving it on
	// the card's branch is that there is still a tree to resolve it in.
	one := todos_add(&app.todos, "say hello", "s-one", repo)
	two := todos_add(&app.todos, "say goodbye", "s-two", repo)
	one_tree, _ := worktree_for(repo, one, context.temp_allocator)
	two_tree, _ := worktree_for(repo, two, context.temp_allocator)
	_ = os.write_entire_file(join(one_tree, "f"), "hello")
	_ = os.write_entire_file(join(two_tree, "f"), "goodbye")
	first, _ := worktree_land(repo, one, "say hello")
	testing.expect_value(t, first, "")
	second, conflicted := worktree_land(repo, two, "say goodbye")
	testing.expect(t, second != "", "a conflict landed anyway")
	// And it is left mid-merge on purpose: the markers in the files are what
	// an agent is put in there to settle, and aborting was the version of
	// this that made a card that had done its work into a chore.
	testing.expect(t, conflicted, "the conflict was not offered to anyone")
	testing.expect(t, worktree_merging(two_tree), "the merge was thrown away")
	testing.expect(t, os.exists(two_tree), "the tree to resolve it in was taken away")
	testing.expect(t, has_branch(t, repo, two), "the branch with the work on it went")
	// Asked again, it says the same thing and offers the same conflict — and
	// the offer is the point. One go was the old policy, and what it bought
	// was a card sitting on `needs you` for ever over a merge the thing that
	// wrote both sides could have finished. The merge is not started over
	// either: the tree is still mid-merge and the markers are still where the
	// last attempt left them, so an agent put back in there carries on rather
	// than beginning again. What keeps it from going round inside one session
	// is app_resolving; what starts a new go is a landing, and landings
	// happen when a turn ends or when the window opens.
	retry, twice := worktree_land(repo, two, "say goodbye")
	testing.expect_value(t, retry, "the merge was left unresolved")
	testing.expect(t, twice, "the conflict was not offered to anyone a second time")
	testing.expect(t, worktree_merging(two_tree), "the merge was started over")
	// And the project is exactly where the first card left it: a failed
	// landing touches nothing.
	f, _ := os.read_entire_file_from_path(join(repo, "f"), context.temp_allocator)
	testing.expect_value(t, string(f), "hello")
	todos_dismiss(&app.todos, two)

	// A card that did its work perfectly, and an unrelated file open in the
	// project that git will not fast-forward over. Refusing to land on that
	// is a card held up by something that has nothing to do with it, so the
	// work is put aside, the fast-forward taken, and the work put back.
	lines := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20 do strings.write_string(&lines, "keep\n")
	_ = os.write_entire_file(join(repo, "big"), transmute([]byte)strings.to_string(lines))
	run(t, "git", "-C", repo, "add", "big")
	run(t, "git", "-C", repo, "commit", "-qm", "big")

	three := todos_add(&app.todos, "change the end", "s-three", repo)
	three_tree, _ := worktree_for(repo, three, context.temp_allocator)
	_ = os.write_entire_file(join(three_tree, "big"), transmute([]byte)strings.concatenate(
		{strings.to_string(lines)[:len("keep\n") * 19], "the card was here\n"},
		context.temp_allocator,
	))
	// And the same file open in the project, edited at the other end of it.
	mine := strings.concatenate(
		{"i was in the middle of this\n", strings.to_string(lines)[len("keep\n"):]},
		context.temp_allocator,
	)
	_ = os.write_entire_file(join(repo, "big"), transmute([]byte)mine)

	blocked, _ := worktree_land(repo, three, "change the end")
	testing.expect_value(t, blocked, "")
	got, _ := os.read_entire_file_from_path(join(repo, "big"), context.temp_allocator)
	// The card's work is in, and so is the line that was never committed:
	// nothing was taken off the project's tree and left off it.
	testing.expect(t, strings.contains(string(got), "the card was here"), "the card did not land")
	testing.expect(t, strings.contains(string(got), "i was in the middle of this"), "work was stashed and never given back")
	todo_set_state(&app.todos, three, .Done)
	testing.expect(t, worktree_release(repo, three), "a landed tree may go")
	run(t, "git", "-C", repo, "checkout", "-q", "--", "big")

	// And the pile that built up while nothing ever removed one: a tree per
	// card ever run. The sweep reads the card list — a tree whose card is
	// still open is somewhere work is happening.
	open_id := todos_add(&app.todos, "two", "s2", repo)
	gone_id := todos_add(&app.todos, "three", "s3", repo)
	done_tree, _ := worktree_for(repo, id, context.temp_allocator)
	open_tree, _ := worktree_for(repo, open_id, context.temp_allocator)
	gone_tree, _ := worktree_for(repo, gone_id, context.temp_allocator)
	todos_dismiss(&app.todos, gone_id)

	worktree_sweep(&app.todos)
	testing.expect(t, !os.exists(done_tree), "a finished card kept its tree")
	testing.expect(t, !os.exists(gone_tree), "a dismissed card kept its tree")
	testing.expect(t, os.exists(open_tree), "a card still working lost its tree")
}

// A finished card whose tree has already gone still gets its work in. This is
// the hole the whole "I rebuilt and I still cannot see it" afternoon came out
// of: landing only ever ran at the end of a turn, the sweep took the tree of
// every finished card as the window opened, and worktree_land answered
// "landed" for a card with no tree without doing anything — so the work sat on
// a branch that nothing would ever merge.
@(test)
a_finished_card_lands_even_with_no_tree_left :: proc(t: ^testing.T) {
	scratch_dir(t)
	scratch_cache()
	repo := "/tmp/aithing-test-treeless"
	if !testing.expect(t, run(t, "rm", "-rf", repo), "could not clear the scratch dir") do return
	os.make_directory_all(repo)
	made :=
		run(t, "git", "-C", repo, "init", "-q") &&
		run(t, "git", "-C", repo, "config", "user.email", "test@example.com") &&
		run(t, "git", "-C", repo, "config", "user.name", "test") &&
		os.write_entire_file(join(repo, "f"), "a") == nil &&
		run(t, "git", "-C", repo, "add", "f") &&
		run(t, "git", "-C", repo, "commit", "-qm", "one")
	if !testing.expect(t, made, "git is needed for this one") do return

	app := scratch_app()
	defer scratch_free(app)

	id := todos_add(&app.todos, "leave a branch behind", "s-treeless", repo)
	tree, _ := worktree_for(repo, id, context.temp_allocator)
	_ = os.write_entire_file(join(tree, "landed"), "y")
	run(t, "git", "-C", tree, "add", "landed")
	run(t, "git", "-C", tree, "commit", "-qm", "the work")

	// The tree goes first, the way the sweep takes it on the way up, and the
	// branch is all that is left of the card.
	todo_set_state(&app.todos, id, .Done)
	testing.expect(t, worktree_release(repo, id), "the tree did not go")
	testing.expect(t, !os.exists(tree), "the tree is still there")
	testing.expect(t, has_branch(t, repo, id), "the work went with the tree")
	testing.expect(t, !os.exists(join(repo, "landed")), "it was in the project already")

	app_land_finished(app)
	testing.expect(t, os.exists(join(repo, "landed")), "a done card's work never reached the project")
	// And the card says which of the two it is. Complete and merged read the
	// same on the grid before this, so a card whose work was still sitting on
	// a branch looked exactly like one that had gone in.
	testing.expect_value(t, app.todos.list[todos_find(&app.todos, id)].state, Todo_State.Merged)

	// And again, because this runs on every launch: a card already in is not
	// a card that fails, it is a card with nothing to do.
	app_land_finished(app)
	testing.expect(t, os.exists(join(repo, "landed")), "landing it twice undid it")
}

// A card that says `needs you` about work that is already in the project is a
// card asking about nothing. Three of them stood like that at once — merged,
// branches gone, still amber on the grid — and every one of them was a job
// left to a person that the window could have answered from git.
@(test)
a_card_stops_asking_once_there_is_nothing_left_to_land :: proc(t: ^testing.T) {
	scratch_dir(t)
	scratch_cache()
	repo := "/tmp/aithing-test-settled"
	if !testing.expect(t, run(t, "rm", "-rf", repo), "could not clear the scratch dir") do return
	os.make_directory_all(repo)
	made :=
		run(t, "git", "-C", repo, "init", "-q") &&
		run(t, "git", "-C", repo, "config", "user.email", "test@example.com") &&
		run(t, "git", "-C", repo, "config", "user.name", "test") &&
		os.write_entire_file(join(repo, "f"), "a") == nil &&
		run(t, "git", "-C", repo, "add", "f") &&
		run(t, "git", "-C", repo, "commit", "-qm", "one")
	if !testing.expect(t, made, "git is needed for this one") do return

	app := scratch_app()
	defer scratch_free(app)

	// Its work went in and its branch went with it, and all that is left of
	// it is a state written down at the end of a turn.
	asked := todos_add(&app.todos, "already in", "s-settled", repo)
	todo_set_state(&app.todos, asked, .Asked)
	testing.expect(t, worktree_settled(repo, asked), "a card with no branch has nothing left")
	app_land_finished(app)
	testing.expect_value(t, app.todos.list[todos_find(&app.todos, asked)].state, Todo_State.Merged)

	// Still on a branch of its own, and still the person's to answer.
	held := todos_add(&app.todos, "not in yet", "s-held", repo)
	tree, _ := worktree_for(repo, held, context.temp_allocator)
	_ = os.write_entire_file(join(tree, "held"), "y")
	run(t, "git", "-C", tree, "add", "held")
	run(t, "git", "-C", tree, "commit", "-qm", "work")
	todo_set_state(&app.todos, held, .Asked)
	testing.expect(t, !worktree_settled(repo, held), "a branch with commits of its own is not settled")
	app_land_finished(app)
	testing.expect_value(t, app.todos.list[todos_find(&app.todos, held)].state, Todo_State.Asked)

	// A verdict about the work is not a verdict about where it went: failed
	// stays failed however little is left on its branch.
	broke := todos_add(&app.todos, "went wrong", "s-broke", repo)
	todo_set_state(&app.todos, broke, .Failed)
	app_land_finished(app)
	testing.expect_value(t, app.todos.list[todos_find(&app.todos, broke)].state, Todo_State.Failed)

	// And a card nothing has ever run is waiting, not finished. It has no
	// branch for the same reason a landed card has none, and only the thread
	// behind it tells the two apart.
	fresh := todos_add(&app.todos, "never started", "", repo)
	app_land_finished(app)
	testing.expect_value(t, app.todos.list[todos_find(&app.todos, fresh)].state, Todo_State.Open)
}

// --- and out ------------------------------------------------------------------

// Landing used to end at the merge, which is a branch on one machine. This is
// the half that was missing: a finished card's work reaches the remote without
// anyone asking it to, and a project with no remote says nothing rather than
// putting a failure on a card that did everything right.
@(test)
a_landed_card_goes_out_to_the_remote :: proc(t: ^testing.T) {
	scratch_dir(t)
	remote := "/tmp/aithing-test-remote.git"
	repo := "/tmp/aithing-test-push"
	alone := "/tmp/aithing-test-alone"
	if !testing.expect(t, run(t, "rm", "-rf", remote, repo, alone), "could not clear the scratch dirs") {
		return
	}
	os.make_directory_all(remote)
	os.make_directory_all(repo)
	os.make_directory_all(alone)
	made :=
		run(t, "git", "-C", remote, "init", "-q", "--bare") &&
		run(t, "git", "-C", repo, "init", "-q") &&
		run(t, "git", "-C", repo, "config", "user.email", "test@example.com") &&
		run(t, "git", "-C", repo, "config", "user.name", "test") &&
		os.write_entire_file(join(repo, "f"), "a") == nil &&
		run(t, "git", "-C", repo, "add", "f") &&
		run(t, "git", "-C", repo, "commit", "-qm", "one") &&
		run(t, "git", "-C", repo, "remote", "add", "origin", remote)
	if !testing.expect(t, made, "git is needed for this one") do return

	testing.expect_value(t, worktree_push(repo), "")
	head, _ := git_head(t, repo)
	there, ok := git_head(t, remote)
	testing.expect(t, ok, "the remote has no branch at all")
	testing.expect_value(t, there, head)

	// A second landing pushes what the first one did not — the branch carries
	// every commit on it, which is why one push in flight can swallow the
	// landing that arrived behind it.
	_ = os.write_entire_file(join(repo, "g"), "b")
	run(t, "git", "-C", repo, "add", "g")
	run(t, "git", "-C", repo, "commit", "-qm", "two")
	testing.expect_value(t, worktree_push(repo), "")
	head2, _ := git_head(t, repo)
	there2, _ := git_head(t, remote)
	testing.expect_value(t, there2, head2)

	// Nowhere to send it is not a failure. Plenty of what this runs on never
	// leaves the machine, and a note on every card about it would be noise.
	nothing :=
		run(t, "git", "-C", alone, "init", "-q") &&
		run(t, "git", "-C", alone, "config", "user.email", "test@example.com") &&
		run(t, "git", "-C", alone, "config", "user.name", "test") &&
		os.write_entire_file(join(alone, "f"), "a") == nil &&
		run(t, "git", "-C", alone, "add", "f") &&
		run(t, "git", "-C", alone, "commit", "-qm", "one")
	if !testing.expect(t, nothing, "git is needed for this one") do return
	testing.expect_value(t, worktree_push(alone), "")
}

@(private = "file")
git_head :: proc(t: ^testing.T, dir: string) -> (sha: string, ok: bool) {
	state, out, _, err := os.process_exec(
		{command = {"git", "-C", dir, "rev-parse", "HEAD"}, working_dir = "/tmp"},
		context.temp_allocator,
	)
	if err != nil || !state.exited || state.exit_code != 0 do return "", false
	return strings.trim_space(string(out)), true
}

@(private = "file")
join :: proc(dir, name: string) -> string {
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

@(private = "file")
has_branch :: proc(t: ^testing.T, repo, id: string) -> bool {
	ref := strings.concatenate({"refs/heads/", worktree_branch(id)}, context.temp_allocator)
	return run(t, "git", "-C", repo, "rev-parse", "--verify", "--quiet", ref)
}

@(private = "file")
run :: proc(t: ^testing.T, args: ..string) -> bool {
	state, _, _, err := os.process_exec(
		{command = args, working_dir = "/tmp"},
		context.temp_allocator,
	)
	return err == nil && state.exited && state.exit_code == 0
}

// A card's tree is where work happens, not a place you can go. Threads that
// ran in one used to fill the launcher with a project row per card ever run —
// `aithing-n-12`, `aithing-n-13`, every one of them the same project wearing a
// card's id, and half of those directories given back the moment their card
// finished. The card on the grid is the door to that thread.
@(test)
the_launcher_never_offers_a_tree :: proc(t: ^testing.T) {
	scratch_dir(t)
	// The shared root, like everything else that touches the cache: the
	// environment is one variable for the whole process and the runner runs
	// these on 32 threads, so a test with a cache root of its own is every
	// other test's trees moving out from under it mid-run.
	scratch_cache()
	app := scratch_app()
	defer scratch_free(app)

	id := todos_add(&app.todos, "bake the atlas", "w1", "/tmp/proj")
	tree := worktree_path("/tmp/proj", id, context.temp_allocator)
	testing.expect_value(t, worktree_card(tree), id)
	testing.expect_value(t, worktree_card("/tmp/proj"), "")

	sessions := make([]Session, 2, context.temp_allocator)
	sessions[0] = fake_session("a1", "one")
	sessions[1] = fake_session("w1", "in a tree")
	sessions[1].cwd = tree
	app.sessions = sessions
	// The list is the temp allocator's here, and scratch_free frees the one
	// it is handed.
	defer app.sessions = nil

	testing.expect_value(t, len(app_visible(app)), 1)
	// And it stays hidden when it is asked for by name: a thread that ran in
	// a card's tree is one you reach through the card.
	editor_set_text(&app.search, "tree")
	testing.expect_value(t, len(app_visible(app)), 0)
}

// A window nobody has told otherwise thinks as hard as the harness would on
// its own, and the word it saves is the word the CLI takes. The chip used to
// be able to show a level the flag did not spell the same way, because the
// label and the flag were two lists.
@(test)
effort_is_medium_until_it_is_picked :: proc(t: ^testing.T) {
	scratch_dir(t)
	os.remove(config_path("effort"))
	testing.expect_value(t, effort_load(), EFFORT_DEFAULT)
	testing.expect_value(t, EFFORT_DEFAULT, Effort.Medium)

	effort_save(.Xhigh)
	testing.expect_value(t, effort_load(), Effort.Xhigh)

	// Anything that is not one of the five is the default again, not a level
	// the harness would reject.
	e, ok := effort_parse("thorough")
	testing.expect(t, !ok)
	testing.expect_value(t, e, EFFORT_DEFAULT)
}
