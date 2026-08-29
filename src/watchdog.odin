package aithing

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

// A freeze is the one bug a window cannot report on its own: by the time it is
// noticed, the thing that would have printed the reason is the thing that is
// stuck. So the frame loop stamps where it is into one static word, and a
// second thread watches that word. If it stops moving, the phase it stopped in
// is written out.
//
// No allocation, no per-frame cost beyond a store: the phase is a plain
// integer in static storage.

Phase :: enum u32 {
	Idle,
	Poll, // waiting on the compositor with nothing to do
	Wait, // waiting on the compositor with a frame owed
	Events, // applying what the runner streamed
	Jobs, // taking finished scans and transcripts
	Input, // keys and clicks
	Build, // laying the frame out
	Draw, // Vulkan
	Send, // starting a claude process
	Paste, // reading the clipboard
}

@(private = "file")
Watchdog :: struct {
	phase:   Phase,
	seq:     u64, // bumped on every phase change; a stall is this standing still
	worker:  ^thread.Thread,
	running: bool,
	warned:  bool,
	last_seq: u64,
	since:   time.Time,
}

@(private = "file")
g_watch: Watchdog

// Marks what the loop is doing. Called a handful of times a frame.
watch :: proc "contextless" (p: Phase) {
	sync.atomic_store_explicit(&g_watch.phase, p, .Relaxed)
	sync.atomic_add_explicit(&g_watch.seq, 1, .Relaxed)
}

STALL_SECONDS :: 3.0

watchdog_start :: proc() {
	g_watch.running = true
	g_watch.since = time.now()
	g_watch.worker = thread.create_and_start(proc() {
		for sync.atomic_load_explicit(&g_watch.running, .Relaxed) {
			time.sleep(500 * time.Millisecond)
			seq := sync.atomic_load_explicit(&g_watch.seq, .Relaxed)
			if seq != g_watch.last_seq {
				g_watch.last_seq = seq
				g_watch.since = time.now()
				g_watch.warned = false
				continue
			}
			// Waiting on the compositor with nothing to do is not a stall;
			// that is what an idle window is supposed to look like.
			phase := sync.atomic_load_explicit(&g_watch.phase, .Relaxed)
			if phase == .Poll || phase == .Idle do continue

			stuck := time.duration_seconds(time.since(g_watch.since))
			if stuck > STALL_SECONDS && !g_watch.warned {
				g_watch.warned = true
				fmt.eprintfln("STALL: %v for %.1fs", phase, stuck)
			}
		}
	})
}

watchdog_stop :: proc() {
	sync.atomic_store_explicit(&g_watch.running, false, .Relaxed)
	if g_watch.worker != nil {
		thread.join(g_watch.worker)
		thread.destroy(g_watch.worker)
		g_watch.worker = nil
	}
}
