package aithing

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// The corner is three readings and nothing else, and each one is a reading of
// its own window. What these are here to catch is one window's silence being
// read as another window's answer.

// One file, one writer at a time. A reading is written through the moment it
// lands — which is the point of it — so every test here that lets one land
// writes the same path, and the runner runs them side by side. The lock is
// the config file's, not any test's.
@(private = "file")
usage_file: sync.Mutex

@(private = "file")
usage_app :: proc() -> ^App {
	// The same directory every other test points AITHING_CONFIG at, and that
	// is the whole reason it is written here rather than a path of its own.
	// The variable is the process's, not the test's, and the runner runs on
	// thirty-two threads: a test with a directory of its own is a test that
	// moves the config out from under whatever is reading it at that moment.
	// This is what made `effort_is_medium_until_it_is_picked` save a level
	// into one directory and read it back out of another.
	dir := "/tmp/aithing-test-config"
	os.make_directory_all(dir)
	_ = os.set_env("AITHING_CONFIG", dir)
	return new(App)
}

@(private = "file")
usage_free :: proc(app: ^App) {
	turns_destroy(app)
	usage_destroy(&app.usage)
	free(app)
}

@(private = "file")
live_turn :: proc(app: ^App) -> int {
	at := turn_slot(app)
	t := app.turns[at]
	t^ = Turn {
		live    = true,
		session = strings.clone("s"),
		cwd     = strings.clone("/tmp"),
	}
	t.runner.running = true
	return at
}

// The reading is kept over a restart, which is only safe because a window
// past its reset is empty whoever read it and whenever.
@(test)
test_usage_allowance_expires :: proc(t: ^testing.T) {
	now := time.time_to_unix(time.now())
	testing.expect_value(t, window_used(Allowance{util = 0.4, resets = now + 600}), 0.4)
	testing.expect_value(t, window_used(Allowance{util = 0.4, resets = now - 1}), 0)
	testing.expect_value(t, window_used(Allowance{util = 0.4}), 0) // never read
}

// Everything the file is for, in one test because there is one file: two of
// these running side by side is one of them reading the other's reading.
@(test)
test_usage_round_trip :: proc(t: ^testing.T) {
	sync.mutex_lock(&usage_file)
	defer sync.mutex_unlock(&usage_file)
	app := usage_app()
	defer usage_free(app)

	// A reading is on disk as soon as it is read, which is what the next
	// window to open draws before its own probe comes back. It used to wait
	// for the slow tick everything else was saved on, so a window killed in
	// between opened on three dashes and asked again.
	os.remove(config_path("usage"))
	usage_take(&app.usage, Limits {
		session = {util = 0.25, resets = 1_788_922_800},
		week    = {util = 0.5, resets = 1_789_426_800},
		fable   = {util = 0.75, resets = 1_789_426_800},
	})

	back: Ledger
	defer usage_destroy(&back)
	usage_load(&back)
	testing.expect_value(t, back.limits.session.util, 0.25)
	testing.expect_value(t, back.limits.week.util, 0.5)
	testing.expect_value(t, back.limits.week.resets, app.usage.limits.week.resets)
	testing.expect_value(t, back.limits.fable.util, 0.75)
	testing.expect(t, back.limits.read_at != 0, "a cached reading with no time on it")

	// Nothing changed, so nothing is written: a window sitting still must not
	// rewrite the file on every tick.
	os.remove(config_path("usage"))
	usage_save(&back)
	_, err := os.read_entire_file(config_path("usage"), context.temp_allocator)
	testing.expect(t, err != nil, "an unchanged ledger wrote itself out again")
}

// The reading arrives on any turn's stream, headless ones included — which is
// nearly all of them here — and the newest one is the whole answer.
@(test)
test_usage_limits_from_a_headless_turn :: proc(t: ^testing.T) {
	sync.mutex_lock(&usage_file)
	defer sync.mutex_unlock(&usage_file)
	app := usage_app()
	defer usage_free(app)

	at := live_turn(app)
	app.turns[at].chat = false
	now := time.time_to_unix(time.now())
	e := Event{kind = .Limits, limits = Limits{session = {util = 0.2, resets = now + 600}, week = {util = 0.5, resets = now + 6000}}}
	app_apply_event_for_test(app, at, &e)
	testing.expect_value(t, window_used(app.usage.limits.session), 0.2)

	e2 := Event{kind = .Limits, limits = Limits{session = {util = 0.3, resets = now + 600}, week = {util = 0.5, resets = now + 6000}}}
	app_apply_event_for_test(app, at, &e2)
	testing.expect_value(t, window_used(app.usage.limits.session), 0.3)

	app.turns[at].runner.running = false
	turn_release(app, at)
	// The turn is gone and the reading is not: it was never the turn's.
	testing.expect_value(t, window_used(app.usage.limits.session), 0.3)
}

// Only a Fable turn is told about the Fable week. Every other turn's reading
// is silent about it, and a silence is not a zero — the number used to be
// wiped back to unread by the next Haiku turn that happened to report.
@(test)
test_usage_fable_week_survives_other_models :: proc(t: ^testing.T) {
	sync.mutex_lock(&usage_file)
	defer sync.mutex_unlock(&usage_file)
	app := usage_app()
	defer usage_free(app)

	at := live_turn(app)
	now := time.time_to_unix(time.now())
	fable := Event{kind = .Limits, limits = Limits {
		session = {util = 0.2, resets = now + 600},
		week    = {util = 0.5, resets = now + 6000},
		fable   = {util = 0.8, resets = now + 6000},
	}}
	app_apply_event_for_test(app, at, &fable)
	testing.expect_value(t, window_used(app.usage.limits.fable), 0.8)

	// A turn on any other model: the same two windows, and nothing about
	// Fable's.
	other := Event{kind = .Limits, limits = Limits {
		session = {util = 0.25, resets = now + 600},
		week    = {util = 0.55, resets = now + 6000},
	}}
	app_apply_event_for_test(app, at, &other)
	testing.expect_value(t, window_used(app.usage.limits.session), 0.25)
	testing.expect_value(t, window_used(app.usage.limits.fable), 0.8)
}

// The corner is the one thing in the window that never moves, and what it
// stands on is the box's bottom right corner — which is where the model and
// effort chips are. It kept a floor under its own width, so at the width the
// composer actually is there was not room beside it and the panel came down
// over the chips: the only two controls the window has, under an opaque
// readout, with the picker opening behind it.
//
// Nothing here needs a window or a font, which is the point — it is two
// numbers agreeing, and they used to be worked out in two places.
@(test)
the_corner_never_stands_on_the_chips :: proc(t: ^testing.T) {
	// Every width from too narrow for the box to wider than it will ever
	// grow, because the two answers are worked out from the same room and
	// the failure was a width in the middle of that range.
	for w := f32(600); w <= 2400; w += 7 {
		full := Rect{0, 0, w, 800}
		// The box along the bottom, laid out the way draw_page lays it out:
		// content width at most, centred, PAD clear either side.
		bw := min(w - 16 * 2, 880)
		box := Rect{(w - bw) / 2, 700, bw, 84}
		corner := usage_rect(full, box)
		if corner.w <= 0 do continue
		testing.expectf(
			t,
			chips_right(full, box) <= corner.x,
			"at %v wide the chips end at %v, inside a corner that starts at %v",
			w,
			chips_right(full, box),
			corner.x,
		)
		// And the corner is still in the window it was given.
		testing.expect(t, corner.x + corner.w <= full.w)
	}
}

// How far along the green-to-warning run a colour has got, 0 at GREEN and 1 at
// ACCENT. Read off the one channel the two differ in most, which is enough to
// say whether a figure looks green or looks gold.
@(private = "file")
toward_warning :: proc(c: Color) -> f32 {
	chan :: proc(c: Color, shift: u32) -> f32 {return f32((u32(c) >> shift) & 0xff)}
	g, a, x := chan(GREEN, 0), chan(ACCENT, 0), chan(c, 0)
	return (x - g) / (a - g)
}

// A window with four fifths of it left is not a warning. The ramp used to run
// straight from nothing to half, so 18% of the week gone came out a third of
// the way to the warning colour — visibly gold beside the green figures either
// side of it, for a window nobody needed to think about.
@(test)
a_barely_used_window_reads_green :: proc(t: ^testing.T) {
	testing.expectf(
		t,
		toward_warning(usage_meter_color(0.18)) < 0.15,
		"18%% used is %v of the way to the warning colour",
		toward_warning(usage_meter_color(0.18)),
	)
	testing.expect_value(t, usage_meter_color(0), GREEN)
	testing.expect_value(t, usage_meter_color(1), RED)

	// And it only ever goes one way: every step up the ramp is a step further
	// from green, which is the whole of what the colour is for.
	last := f32(-1)
	for i in 0 ..= 100 {
		here := toward_warning(usage_meter_color(f32(i) / 100))
		testing.expectf(t, here >= last, "%d%% used stepped back toward green", i)
		last = here
	}
}
