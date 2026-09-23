package aithing

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// A `claude` that names a thread, waits a second and names it again: long
// enough for a window to close in the middle of it and another to open.
@(private = "file")
FAKE_CLAUDE :: `#!/bin/sh
echo '{"type":"system","subtype":"init","session_id":"before"}'
sleep 1
echo '{"type":"system","subtype":"init","session_id":"after"}'
`

// Both tests write the script, and one truncating it while the other's shell
// is reading it is a `claude` that prints nothing.
@(private = "file")
fake_once: sync.Once

@(private = "file")
fake_claude :: proc() {
	sync.once_do(&fake_once, fake_claude_write)
}

@(private = "file")
fake_claude_write :: proc() {
	bin := "/tmp/aithing-test-fakebin"
	os.make_directory_all(bin)
	path := os.get_env("PATH", context.temp_allocator)
	if !strings.has_prefix(path, bin) do _ = os.set_env("PATH", strings.concatenate({bin, ":", path}, context.temp_allocator))
	// Written only when it is not already there, and through a rename. A
	// script is refused with "text file busy" while anything has it open for
	// writing, and the suite forks git from other threads, each fork holding
	// a copy of whatever is open until it execs: rewriting it on every run
	// made a `claude` that sometimes never ran at all.
	script := strings.concatenate({bin, "/claude"}, context.temp_allocator)
	if data, err := os.read_entire_file_from_path(script, context.temp_allocator); err == nil && string(data) == FAKE_CLAUDE do return
	tmp := strings.concatenate({script, ".tmp"}, context.temp_allocator)
	_ = os.write_entire_file(tmp, FAKE_CLAUDE)
	_ = os.chmod(tmp, {.Read_User, .Write_User, .Execute_User})
	_ = os.rename(tmp, script)
}

@(private = "file")
wait_for_output :: proc(dir: string) {
	deadline := time.time_add(time.now(), 5 * time.Second)
	for time.diff(time.now(), deadline) > 0 {
		if info, err := os.stat(run_file(dir, "out"), context.temp_allocator); err == nil && info.size > 0 do return
		time.sleep(5 * time.Millisecond)
	}
}

// Not the cache the other tests share: one of them clears it.
@(private = "file")
fake_run :: proc(name: string) -> string {
	dir := strings.concatenate({"/tmp/aithing-test-runs/", name}, context.temp_allocator)
	os.remove_all(dir)
	return dir
}

// Everything the run says until it says Done, or nil if it never does.
@(private = "file")
drain_to_done :: proc(r: ^Runner) -> [dynamic]Event {
	out: [dynamic]Event
	deadline := time.time_add(time.now(), 10 * time.Second)
	for time.diff(time.now(), deadline) > 0 {
		for e in runner_drain(r, context.temp_allocator) {
			append(&out, e)
			if e.kind == .Done do return out
		}
		time.sleep(10 * time.Millisecond)
	}
	return out
}

// The whole point of a run being a directory: the window that started it can
// go, the work carries on, and the next window reads it to the end — the part
// it missed marked as missed, and nobody else allowed to read it at the same
// time.
@(test)
a_turn_outlives_the_window_that_started_it :: proc(t: ^testing.T) {
	fake_claude()

	first: Runner
	testing.expect(t, runner_start_in(&first, fake_run("outlives"), "/tmp", "", "hi", "", ""))
	wait_for_output(first.dir)
	dir := strings.clone(first.dir, context.temp_allocator)
	pid := first.pid
	runner_destroy(&first) // the window closing

	testing.expect(t, os.exists(dir), "a run still going keeps its directory")

	// Not always on the first try. The suite forks git from other threads,
	// and a fork shares the lock until its child execs and close-on-exec lets
	// go of it. Two windows are two processes and never meet this.
	second: Runner
	adopted := false
	for _ in 0 ..< 100 {
		if adopted = runner_adopt(&second, dir, pid); adopted do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, adopted)
	third: Runner
	testing.expect(t, !runner_adopt(&third, dir, pid), "a run another window holds is that window's")

	events := drain_to_done(&second)
	defer delete(events)
	sessions: [dynamic]Event
	defer delete(sessions)
	failed := false
	for e in events {
		if e.kind == .Session do append(&sessions, e)
		if e.kind == .Failed do failed = true
	}
	testing.expect(t, !failed, "a clean exit read by a window that is not its parent")
	testing.expect_value(t, len(sessions), 2)
	if len(sessions) == 2 {
		testing.expect(t, sessions[0].replay, "written before the window was watching")
		testing.expect(t, !sessions[1].replay, "written while it was")
	}

	runner_destroy(&second)
	testing.expect(t, !os.exists(dir), "a run read to the end is cleared away")
}

// A stop is still a stop: the shell and the harness under it both go, and the
// run ends without an exit code rather than waiting on one that never comes.
@(test)
a_stopped_turn_ends :: proc(t: ^testing.T) {
	fake_claude()

	r: Runner
	testing.expect(t, runner_start_in(&r, fake_run("stopped"), "/tmp", "", "hi", "", ""))
	wait_for_output(r.dir)
	runner_stop(&r)

	events := drain_to_done(&r)
	defer delete(events)
	failed, done := false, false
	for e in events {
		if e.kind == .Failed do failed = true
		if e.kind == .Done do done = true
	}
	testing.expect(t, failed)
	testing.expect(t, done)
	runner_destroy(&r)
}
