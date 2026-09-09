package aithing

import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

// The harness keeps itself current, but only when you sit in front of it: an
// interactive `claude` checks for a newer release on the way up and installs
// it in the background. Nothing in this window is interactive — every turn is
// `claude -p`, print mode, one prompt and out (see runner.odin) — so the one
// path that ever updates the CLI is the one path this program never takes. A
// window left running for a fortnight went on shelling out to whatever version
// happened to be installed the day it was first set up, and the machine had no
// other reason to run `claude` by hand.
//
// So the window asks on its own behalf: `claude update`, once on the way up and
// every few hours after, on a worker thread. It is the same command a person
// would type, so nothing here knows or cares whether the CLI came from npm or
// the native installer — the CLI knows.
//
// It is not held back for running turns. The native installer writes the new
// release beside the old one and moves the symlink onto it, so a turn already
// running keeps the file it was started on, and the next turn to start gets the
// new one. There is nothing to coordinate and nothing to restart.

@(private = "file")
Update :: struct {
	worker:  ^thread.Thread,
	mu:      sync.Mutex,
	running: bool,
	ready:   bool,
	ok:      bool,
	// When the last check finished, zero for never. This is the only thing
	// written down: whether one is happening now is read off `running`, and
	// which version is installed is never recorded at all — the answer to that
	// lives in the symlink `claude` resolves through, and a copy of it here
	// would be a second opinion that goes stale the moment an update lands.
	checked: time.Time,
}

@(private = "file")
g_update: Update

// Far enough apart that a window open all week checks a handful of times, close
// enough that a release landing in the morning is running by the afternoon.
UPDATE_EVERY :: time.Duration(4 * time.Hour)

// A `checked` that was never written is 1970, so "never" needs no special case:
// it is simply very overdue.
update_due :: proc(checked: time.Time, now: time.Time) -> bool {
	return time.diff(checked, now) > UPDATE_EVERY
}

// Called once a frame. Starts a check when one is due, and says so when one
// failed — which is the whole reason there is a message here at all. A build
// that fails is somebody's mistake and is worth reading a log over; an update
// that fails is usually just a laptop with no network, and would be worth
// nothing except that its failure mode is silence for months, which is the bug
// this file exists to fix.
update_poll :: proc(app: ^App) -> bool {
	update_reap()

	sync.mutex_lock(&g_update.mu)
	running, ready, ok := g_update.running, g_update.ready, g_update.ok
	checked := g_update.checked
	g_update.ready = false
	sync.mutex_unlock(&g_update.mu)

	if !running && update_due(checked, time.now()) do update_start()
	if !ready || ok do return false
	app_status(app, "claude update failed; see last-update.log")
	return true
}

update_destroy :: proc() {
	update_reap()
}

@(private = "file")
update_start :: proc() {
	update_reap()
	sync.mutex_lock(&g_update.mu)
	g_update.running = true
	g_update.ready = false
	sync.mutex_unlock(&g_update.mu)

	g_update.worker = thread.create_and_start(proc() {
		context.allocator = context.temp_allocator
		// Everything it says goes to a file, the way the harness's stderr and
		// the build log do: the window has nowhere to put a paragraph about a
		// download, and after a failure it is the only thing worth reading.
		log, lerr := os.open(cache_path("last-update.log"), {.Write, .Create, .Trunc})
		desc := os.Process_Desc {
			command = {"claude", "update"},
			stdout  = lerr == nil ? log : nil,
			stderr  = lerr == nil ? log : nil,
		}
		ok := false
		if p, err := os.process_start(desc); err == nil {
			state, _ := os.process_wait(p)
			ok = state.exited && state.exit_code == 0
		}
		if lerr == nil do os.close(log)

		sync.mutex_lock(&g_update.mu)
		// Written whether it worked or not: a check that failed has still been
		// made, and retrying it every frame is how a machine with no network
		// spends its evening starting processes.
		g_update.checked = time.now()
		g_update.ok = ok
		g_update.ready = true
		g_update.running = false
		sync.mutex_unlock(&g_update.mu)
	})
}

@(private = "file")
update_reap :: proc() {
	if g_update.worker != nil && thread.is_done(g_update.worker) {
		thread.destroy(g_update.worker)
		g_update.worker = nil
	}
}
