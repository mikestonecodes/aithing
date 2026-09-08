package aithing

import "core:os"
import "core:strings"
import "core:time"
import "core:testing"

// The one property the corner rests on: a turn's numbers are in exactly one
// place at a time. While it runs they are in its runner; once its slot goes
// they are in the day. A total that read both, or neither, is the whole class
// of bug this is here to catch.

@(private = "file")
usage_app :: proc() -> ^App {
	dir := "/tmp/aithing-usage-test"
	os.make_directory_all(dir)
	_ = os.set_env("AITHING_CONFIG", dir)
	app := new(App)
	return app
}

@(private = "file")
usage_free :: proc(app: ^App) {
	turns_destroy(app)
	usage_destroy(&app.usage)
	free(app)
}

@(private = "file")
live_turn :: proc(app: ^App, u: Usage) -> int {
	at := turn_slot(app)
	t := app.turns[at]
	t^ = Turn {
		live    = true,
		session = strings.clone("s"),
		cwd     = strings.clone("/tmp"),
	}
	t.runner.running = true
	t.runner.usage = u
	return at
}

@(test)
test_usage_counted_once :: proc(t: ^testing.T) {
	app := usage_app()
	defer usage_free(app)

	spend := Usage{cost = 0.25, input = 10, output = 20, cache_read = 30}
	at := live_turn(app, spend)

	// Running: read off the turn, and nowhere else.
	live := app_usage_today(app)
	testing.expect_value(t, live.cost, 0.25)
	testing.expect_value(t, live.input, 10)
	testing.expect_value(t, usage_day(&app.usage, usage_day_now()).cost, 0)

	// Released: the same total, banked instead. Not twice, and not lost.
	app.turns[at].runner.running = false
	turn_release(app, at)
	after := app_usage_today(app)
	testing.expect_value(t, after.cost, 0.25)
	testing.expect_value(t, after.input, 10)
	testing.expect_value(t, after.output, 20)
	testing.expect_value(t, after.cache_read, 30)
	testing.expect_value(t, after.turns, 1)
}

// A turn that would not start, or was killed before it said anything, spent
// nothing — and must not turn up in the day's count of turns.
@(test)
test_usage_silent_turn :: proc(t: ^testing.T) {
	app := usage_app()
	defer usage_free(app)

	at := live_turn(app, Usage{})
	app.turns[at].runner.running = false
	turn_release(app, at)
	testing.expect_value(t, app_usage_today(app).turns, 0)
	testing.expect_value(t, len(app.usage.days), 0)
}

// Two turns at once is the case the window is built for, and the corner has
// to add them up rather than show whichever is nearest.
@(test)
test_usage_parallel_turns :: proc(t: ^testing.T) {
	app := usage_app()
	defer usage_free(app)

	a := live_turn(app, Usage{cost = 0.10, output = 5})
	live_turn(app, Usage{cost = 0.30, output = 7})
	testing.expect_value(t, app_usage_today(app).cost, 0.40)

	app.turns[a].runner.running = false
	turn_release(app, a)
	total := app_usage_today(app)
	testing.expect_value(t, total.cost, 0.40)
	testing.expect_value(t, total.output, 12)
	testing.expect_value(t, total.turns, 1) // only the one that finished
}

// Yesterday stays yesterday: the strip in the corner is a week, and a day
// that ended is not added to.
@(test)
test_usage_day_kept_apart :: proc(t: ^testing.T) {
	app := usage_app()
	defer usage_free(app)

	today := usage_day_now()
	append(&app.usage.days, Day{day = today - 1, use = Usage{cost = 2, turns = 4}})
	usage_bank(&app.usage, Usage{cost = 1, turns = 1})

	testing.expect_value(t, len(app.usage.days), 2)
	testing.expect_value(t, usage_day(&app.usage, today - 1).cost, 2)
	testing.expect_value(t, usage_day(&app.usage, today).cost, 1)
	testing.expect_value(t, usage_day(&app.usage, today - 5).cost, 0)
}

@(test)
test_usage_round_trip :: proc(t: ^testing.T) {
	app := usage_app()
	defer usage_free(app)

	today := usage_day_now()
	app.usage.limits = Limits{five = {util = 0.25, resets = 1_788_922_800}, week = {util = 0.5, resets = 1_789_426_800}}
	append(&app.usage.days, Day{day = today - 2, use = Usage{cost = 1.5, input = 3, output = 4, cache_read = 5, cache_write = 6, turns = 7}})
	usage_bank(&app.usage, Usage{cost = 0.125, turns = 2})
	usage_save(&app.usage)

	back: Ledger
	defer usage_destroy(&back)
	usage_load(&back)
	testing.expect_value(t, len(back.days), 2)
	testing.expect_value(t, usage_day(&back, today - 2).input, 3)
	testing.expect_value(t, usage_day(&back, today - 2).turns, 7)
	testing.expect_value(t, usage_day(&back, today).cost, 0.125)
	testing.expect_value(t, back.limits.week.util, 0.5)
	testing.expect_value(t, back.limits.week.resets, app.usage.limits.week.resets)

	// Nothing changed, so nothing is written: a window sitting still must not
	// rewrite the file on every tick.
	os.remove(config_path("usage"))
	usage_save(&back)
	_, err := os.read_entire_file(config_path("usage"), context.temp_allocator)
	testing.expect(t, err != nil, "an unchanged ledger wrote itself out again")
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

// The allowance arrives on any turn's stream, headless ones included — which
// is nearly all of them here — and the newest reading is the whole answer.
@(test)
test_usage_limits_from_a_headless_turn :: proc(t: ^testing.T) {
	app := usage_app()
	defer usage_free(app)

	at := live_turn(app, Usage{})
	app.turns[at].chat = false
	now := time.time_to_unix(time.now())
	e := Event{kind = .Limits, limits = Limits{five = {util = 0.2, resets = now + 600}, week = {util = 0.5, resets = now + 6000}}}
	app_apply_event_for_test(app, at, &e)
	testing.expect_value(t, window_used(app.usage.limits.five), 0.2)

	e2 := Event{kind = .Limits, limits = Limits{five = {util = 0.3, resets = now + 600}, week = {util = 0.5, resets = now + 6000}}}
	app_apply_event_for_test(app, at, &e2)
	testing.expect_value(t, window_used(app.usage.limits.five), 0.3)

	app.turns[at].runner.running = false
	turn_release(app, at)
	// The turn is gone and the reading is not: it was never the turn's.
	testing.expect_value(t, window_used(app.usage.limits.five), 0.3)
}

@(test)
test_usage_reads_as_numbers :: proc(t: ^testing.T) {
	testing.expect_value(t, usage_short(940), "940")
	testing.expect_value(t, usage_short(1_250), "1.2k")
	testing.expect_value(t, usage_short(42_400), "42k")
	testing.expect_value(t, usage_short(4_120_000), "4.1M")
	testing.expect_value(t, usage_short(12_400_000), "12M")
	// Cents matter on the first turn of the day and stop mattering after it.
	testing.expect_value(t, usage_money(0.042), "$0.042")
	testing.expect_value(t, usage_money(12.5), "$12.50")
}
