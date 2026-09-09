package aithing

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// What a frame on the grid costs, at the size a machine that has been used
// for a while actually reaches. Everything on screen is derived on read —
// nothing is cached and nothing is invalidated — and that only stays the
// right answer while deriving it is cheap. So the cost is measured here
// rather than assumed, which is also what any future argument for a cache
// has to beat.
//
// It is pinned because it was once wrong by two orders of magnitude. Both
// sweeps asked `worktree_card` whether each session ran in a card's own tree,
// and that worked the cache directory out from scratch every time it was
// asked: a getenv, a join and a `mkdir`, per session, per call, several calls
// a frame. Searching then lowercased four fields of every session and both
// fields of every card into fresh copies on top. A keystroke in the search
// box cost a hundred milliseconds of that before the letter appeared.
@(private = "file")
SESSIONS :: 1200
@(private = "file")
CARDS :: 400
// Generous against the 0.2ms it actually takes: this is here to catch a
// return to per-session syscalls, not to police a tenth of a millisecond.
@(private = "file")
BUDGET_MS :: f64(3)

@(test)
the_grid_is_cheap_to_rebuild :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.cwd = strings.clone("")

	sessions := make([]Session, SESSIONS)
	for i in 0 ..< SESSIONS {
		sessions[i] = Session {
			id      = fmt.aprintf("sess-%d", i),
			title   = fmt.aprintf("a thread about thing number %d", i),
			preview = fmt.aprintf("some preview text for thread %d, of about the length one has", i),
			cwd     = fmt.aprintf("/tmp/proj%d", i % 12),
			project = fmt.aprintf("proj%d", i % 12),
			mtime   = time.now(),
		}
	}
	app.sessions = sessions
	for i in 0 ..< CARDS {
		text := fmt.aprintf("card number %d, and the work written out on it", i)
		session := fmt.aprintf("sess-%d", i)
		cwd := fmt.aprintf("/tmp/proj%d", i % 12)
		todos_add(&app.todos, text, session, cwd)
		delete(text)
		delete(session)
		delete(cwd)
	}
	app.canvas.view = {0, 0, 1180, 800}

	defer {
		for s in sessions {
			delete(s.id)
			delete(s.title)
			delete(s.preview)
			delete(s.cwd)
			delete(s.project)
		}
		delete(sessions)
		editor_destroy(&app.search)
		delete(app.todo_view)
		delete(app.visible)
		canvas_destroy(&app.canvas)
		todos_destroy(&app.todos)
	}

	// The two sweeps a frame is made of: the grid, and the menu over it.
	// Every reader of either goes through one of these.
	measure :: proc(what: string, app: ^App, work: proc(app: ^App)) -> f64 {
		ROUNDS :: 50
		work(app) // the first one grows the arrays it appends into
		start := time.now()
		for _ in 0 ..< ROUNDS do work(app)
		ms := time.duration_milliseconds(time.since(start)) / ROUNDS
		free_all(context.temp_allocator)
		fmt.eprintfln("  %s: %.3f ms", what, ms)
		return ms
	}

	layout := measure("grid, nothing typed", app, proc(app: ^App) {canvas_layout(app)})
	menu := measure("menu, nothing typed", app, proc(app: ^App) {_ = launcher_hits(app)})
	editor_set_text(&app.search, "Number 3")
	searched := measure("grid, searching", app, proc(app: ^App) {canvas_layout(app)})
	menu_searched := measure("menu, searching", app, proc(app: ^App) {_ = launcher_hits(app)})

	costs := [?]struct {
		what: string,
		ms:   f64,
	} {
		{"the grid with nothing typed", layout},
		{"the menu with nothing typed", menu},
		{"the grid while searching", searched},
		{"the menu while searching", menu_searched},
	}
	for c in costs {
		testing.expect(
			t,
			c.ms <= BUDGET_MS,
			fmt.tprintf("%s costs %.2fms a frame, over the %.0fms budget", c.what, c.ms, BUDGET_MS),
		)
	}

	// And the search still finds things, case and all: the match no longer
	// makes a lowercase copy of either side, so this is what says the fold is
	// still being done.
	app_filter(app)
	testing.expect(t, len(app.visible) > 0, "a mixed-case query found no threads")
	testing.expect(t, len(app.todo_view) > 0, "a mixed-case query found no cards")
}
