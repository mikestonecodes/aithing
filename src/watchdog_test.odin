package aithing

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A freeze has to leave its stack in crash.log, not a phase name in a log the
// next launch truncates: the first freeze anyone reported was relaunched away
// before it could be looked at, and all that was left of it was the word.
@(test)
a_stall_leaves_its_stack_behind :: proc(t: ^testing.T) {
	path := "/tmp/aithing-test-stall.log"
	_ = os.remove(path)
	crash_report_install(path)
	watchdog_start()
	watch(.Build)
	time.sleep(time.Duration((STALL_SECONDS + 1.2) * f64(time.Second)))
	watch(.Idle)
	time.sleep(700 * time.Millisecond)
	watchdog_stop()

	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, err == nil)
	said := string(data)
	testing.expectf(t, strings.contains(said, "aithing stalled: Build"), "no stall in %q", said)
	testing.expectf(t, strings.contains(said, "moving again after"), "no recovery in %q", said)
	// The stack is the point: the frames of the thread that stood still,
	// written by that thread, between the two lines.
	stall := strings.index(said, "stalled")
	moving := strings.index(said, "moving again")
	testing.expectf(t, stall >= 0 && stall < moving && strings.count(said[stall:moving], "\n") > 3, "no stack in %q", said)
}
