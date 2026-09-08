package aithing

import "core:strings"
import "core:sync"
import "core:thread"

// A landing that stops on this machine is half a landing. The merge into the
// project's branch used to be the end of it, so a week of finished cards could
// sit in a local `main` that nobody else could see — the work was done, it was
// merged, and asking where it was got you a branch on one laptop.
//
// Off the main thread, because a push talks to a server: a repository that is
// slow to answer would otherwise stop the window mid-frame, and the whole
// point of landing being automatic is that nobody is waiting on it.
//
// One at a time, and a landing that arrives while one is in flight sets
// `again` rather than queueing: a push carries every commit on the branch, so
// the second push after two landings says exactly what four queued ones would
// have. There is nothing to keep in order and nothing to lose.

@(private = "file")
Push :: struct {
	worker:  ^thread.Thread,
	mu:      sync.Mutex,
	running: bool,
	ready:   bool,
	why:     string, // git's sentence about a push that was refused, "" when it worked
	again:   string, // a project that landed while this one was in flight
}

@(private = "file")
g_push: Push

push_destroy :: proc() {
	push_reap()
	delete(g_push.why)
	delete(g_push.again)
}

// Sends what just landed. Called with the project a card landed in, after its
// tree has gone back.
push_start :: proc(app: ^App, project: string) {
	if project == "" do return
	sync.mutex_lock(&g_push.mu)
	busy := g_push.running
	if busy {
		delete(g_push.again)
		g_push.again = strings.clone(project)
	}
	sync.mutex_unlock(&g_push.mu)
	if busy do return

	push_reap()
	sync.mutex_lock(&g_push.mu)
	g_push.running = true
	g_push.ready = false
	sync.mutex_unlock(&g_push.mu)

	g_push.worker = thread.create_and_start_with_poly_data(
		strings.clone(project),
		proc(project: string) {
			defer delete(project)
			why := worktree_push(project)
			// Kept before the scratch goes: what git said is a slice of the
			// temp allocator this thread is about to drop, and the frame that
			// says it runs long after this one has gone.
			kept := why == "" ? "" : strings.clone(why)
			free_all(context.temp_allocator)

			sync.mutex_lock(&g_push.mu)
			delete(g_push.why)
			g_push.why = kept
			g_push.ready = true
			g_push.running = false
			sync.mutex_unlock(&g_push.mu)
		},
	)
}

// Called once a frame. Only a refusal is said out loud: a push that worked is
// what everyone expects a finished card to have done, and a status line
// announcing it on every landing is a line that gets read once and then never
// again.
push_poll :: proc(app: ^App) -> bool {
	push_reap()
	sync.mutex_lock(&g_push.mu)
	ready := g_push.ready
	why := g_push.why
	again := g_push.again
	g_push.ready = false
	g_push.again = ""
	sync.mutex_unlock(&g_push.mu)
	if !ready do return false
	if why != "" do app_status(app, why)
	// A landing that arrived mid-push gets its own, now that the wire is free.
	if again != "" {
		defer delete(again)
		push_start(app, again)
	}
	return why != ""
}

@(private = "file")
push_reap :: proc() {
	if g_push.worker != nil && thread.is_done(g_push.worker) {
		thread.destroy(g_push.worker)
		g_push.worker = nil
	}
}
