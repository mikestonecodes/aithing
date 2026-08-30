package aithing

import "core:sync"
import "core:thread"

// Reading ~/.claude/projects means touching every session file on disk, and
// opening a transcript means parsing megabytes of JSONL. Both happen on worker
// threads: a window that stops answering the pointer for a second is the
// difference between a native app and a toy.

Scan_Job :: struct {
	mu:      sync.Mutex,
	worker:  ^thread.Thread,
	running: bool,
	ready:   bool,
	result:  []Session,
}

scan_start :: proc(j: ^Scan_Job) {
	sync.mutex_lock(&j.mu)
	already := j.running
	sync.mutex_unlock(&j.mu)
	if already do return

	scan_reap(j)
	sync.mutex_lock(&j.mu)
	j.running = true
	j.ready = false
	sync.mutex_unlock(&j.mu)
	j.worker = thread.create_and_start_with_poly_data(j, proc(j: ^Scan_Job) {
		list := sessions_scan()
		sync.mutex_lock(&j.mu)
		j.result = list
		j.ready = true
		j.running = false
		sync.mutex_unlock(&j.mu)
	})
}

// Hands over the finished list, if there is one. The caller owns it.
scan_take :: proc(j: ^Scan_Job) -> ([]Session, bool) {
	sync.mutex_lock(&j.mu)
	defer sync.mutex_unlock(&j.mu)
	if !j.ready do return nil, false
	j.ready = false
	out := j.result
	j.result = nil
	return out, true
}

scan_reap :: proc(j: ^Scan_Job) {
	if j.worker != nil && thread.is_done(j.worker) {
		thread.destroy(j.worker)
		j.worker = nil
	}
}

scan_destroy :: proc(j: ^Scan_Job) {
	if j.worker != nil {
		thread.join(j.worker)
		thread.destroy(j.worker)
		j.worker = nil
	}
	if j.result != nil do sessions_free(j.result)
}

Load_Job :: struct {
	mu:       sync.Mutex,
	worker:   ^thread.Thread,
	session:  Session, // a private copy, so a rescan can't pull it away
	running:  bool,
	ready:    bool,
	ok:       bool,
	chat:     Chat,
	// The newest session asked for while a read was already under way. Only
	// one is kept: clicking through five sessions should read the fifth, not
	// all five in turn.
	next:     Session,
	has_next: bool,
	// Bumped on every request; a result whose token no longer matches is from
	// a session the reader has already clicked away from.
	token:    int,
	want:     int,
}

load_start :: proc(j: ^Load_Job, s: Session) {
	sync.mutex_lock(&j.mu)
	j.want += 1
	session_free(&j.next)
	j.next = session_clone(s)
	j.has_next = true
	sync.mutex_unlock(&j.mu)
	load_try(j)
}

// Called once a frame: starts a request that had to wait for the previous read
// to finish. Without this a click that lands mid-read is simply lost, and the
// transcript sits on "loading..." for a session nothing is reading.
load_poll :: proc(j: ^Load_Job) {
	load_try(j)
}

// The one place a reader thread is started. A load already in flight is left
// alone — its result is dropped by the token check — and the request waits for
// the next frame rather than racing it.
@(private = "file")
load_try :: proc(j: ^Load_Job) {
	if !j.has_next do return
	load_reap(j)
	if j.worker != nil do return // the last thread has not been collected yet

	sync.mutex_lock(&j.mu)
	if j.running {
		sync.mutex_unlock(&j.mu)
		return
	}
	j.token = j.want
	session_free(&j.session)
	j.session = j.next
	j.next = {}
	j.has_next = false
	j.running = true
	j.ready = false
	sync.mutex_unlock(&j.mu)

	j.worker = thread.create_and_start_with_poly_data(j, proc(j: ^Load_Job) {
		chat, ok := session_load(&j.session)
		sync.mutex_lock(&j.mu)
		chat_destroy(&j.chat) // a result nobody came back for
		j.chat = chat
		j.ok = ok
		j.ready = true
		j.running = false
		sync.mutex_unlock(&j.mu)
	})
}

load_busy :: proc(j: ^Load_Job) -> bool {
	sync.mutex_lock(&j.mu)
	defer sync.mutex_unlock(&j.mu)
	return j.running || j.want != j.token
}

// The finished transcript, if it is still the one being waited for.
load_take :: proc(j: ^Load_Job) -> (Chat, bool) {
	sync.mutex_lock(&j.mu)
	if !j.ready {
		sync.mutex_unlock(&j.mu)
		return {}, false
	}
	j.ready = false
	chat := j.chat
	j.chat = {}
	stale := j.token != j.want
	ok := j.ok
	sync.mutex_unlock(&j.mu)

	if stale {
		// The reader moved on while this was parsing; throw it away and start
		// on whatever they are actually looking at.
		chat_destroy(&chat)
		return {}, false
	}
	if !ok do return {}, false
	return chat, true
}

load_reap :: proc(j: ^Load_Job) {
	if j.worker != nil && thread.is_done(j.worker) {
		thread.destroy(j.worker)
		j.worker = nil
	}
}

load_destroy :: proc(j: ^Load_Job) {
	if j.worker != nil {
		thread.join(j.worker)
		thread.destroy(j.worker)
		j.worker = nil
	}
	session_free(&j.session)
	session_free(&j.next)
	chat_destroy(&j.chat)
}
