package aithing

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The corner is three readings and nothing else, and each one is a reading of
// its own window. What these are here to catch is one window's silence being
// read as another window's answer.

@(private = "file")
usage_app :: proc() -> ^App {
	dir := "/tmp/aithing-usage-test"
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

@(test)
test_usage_round_trip :: proc(t: ^testing.T) {
	app := usage_app()
	defer usage_free(app)

	app.usage.limits = Limits {
		session = {util = 0.25, resets = 1_788_922_800},
		week    = {util = 0.5, resets = 1_789_426_800},
		fable   = {util = 0.75, resets = 1_789_426_800},
	}
	usage_save(&app.usage)

	back: Ledger
	defer usage_destroy(&back)
	usage_load(&back)
	testing.expect_value(t, back.limits.session.util, 0.25)
	testing.expect_value(t, back.limits.week.util, 0.5)
	testing.expect_value(t, back.limits.week.resets, app.usage.limits.week.resets)
	testing.expect_value(t, back.limits.fable.util, 0.75)

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

// A reading is on disk as soon as it is read, which is what the next window to
// open draws before its own probe comes back. It used to wait for the slow
// tick everything else is saved on, so a window killed in between opened with
// three dashes and had to ask again.
@(test)
test_usage_cached_when_read :: proc(t: ^testing.T) {
	app := usage_app()
	defer usage_free(app)
	os.remove(config_path("usage"))

	now := time.time_to_unix(time.now())
	usage_take(&app.usage, Limits {
		session = {util = 0.2, resets = now + 600},
		week    = {util = 0.5, resets = now + 6000},
		fable   = {util = 0.8, resets = now + 6000},
	})

	back: Ledger
	defer usage_destroy(&back)
	usage_load(&back)
	testing.expect_value(t, window_used(back.limits.fable), 0.8)
	testing.expect_value(t, window_used(back.limits.session), 0.2)
	testing.expect(t, back.limits.read_at != 0, "a cached reading with no time on it")
}
