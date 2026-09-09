package aithing

import "core:testing"
import "core:time"

// What a check is due on is one number — when the last one finished — and the
// case that matters is the one with nothing in it. A window that has never
// checked is a window that has just opened, and it is the launch after an
// update landed that has the most to gain from asking.
@(test)
test_update_is_due_when_never_checked :: proc(t: ^testing.T) {
	testing.expect(t, update_due({}, time.now()), "a window that has never checked is due")
}

@(test)
test_update_waits_after_a_check :: proc(t: ^testing.T) {
	now := time.now()
	just := time.time_add(now, -UPDATE_EVERY / 2)
	testing.expect(t, !update_due(just, now), "a check made an hour ago is not repeated")
	stale := time.time_add(now, -(UPDATE_EVERY + time.Duration(time.Minute)))
	testing.expect(t, update_due(stale, now), "a window open all day checks again")
}
