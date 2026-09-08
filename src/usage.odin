package aithing

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// What the harness has run through, and the corner of the screen that says so.
//
// The corner used to lead with dollars — the `total_cost_usd` the harness puts
// on every `result` record. On a subscription that is a price nobody pays: the
// thing that actually stops work at four in the afternoon is an allowance
// window, and a window at 3% left says nothing about how many dollars went
// into it. So the money is gone from here entirely, field and all, rather than
// kept around unread — the three windows are the answer, and tokens and turns
// are the size of the day underneath them.
//
// A turn's numbers live in one place and move once. While it runs they are in
// its own runner and nowhere else; when its slot is released they are added
// into the day it finished on and the runner goes. So the total on screen is
// the day's banked figure plus a walk of the turns still running, and there
// is no moment where a turn is counted in both or in neither.

Usage :: struct {
	input:       int,
	output:      int,
	cache_read:  int,
	cache_write: int,
	turns:       int,
}

usage_add :: proc(a: ^Usage, b: Usage) {
	a.input += b.input
	a.output += b.output
	a.cache_read += b.cache_read
	a.cache_write += b.cache_write
	a.turns += b.turns
}

usage_tokens :: proc(u: Usage) -> int {
	return u.input + u.output + u.cache_read + u.cache_write
}

// --- the ledger ---------------------------------------------------------------

// A fortnight of days, which is more than the corner shows and is the point:
// the file is the record of what was spent, and the day on screen is one row
// of it. Older rows are what makes tomorrow's "today" believable after a
// window has been closed and opened.
USAGE_KEEP :: 14

// A day is a whole number of days since the epoch, UTC. Not local: there is no
// timezone database in core, and a day boundary that is a couple of hours out
// is a smaller lie than a total that resets when the machine changes zone.
Day :: struct {
	day: int,
	use: Usage,
}

// What the plan allows and how much of it is gone: the session, the week, and
// the week's separate allowance for Fable — the three windows `/usage`
// reports. The harness writes them on a record of its own in every turn's
// stream, and it is the account's answer rather than the turn's — so the
// newest reading from any turn is the whole of it, and there is nothing to
// add up.
// Not `Window`: that is the one the program is drawn in.
Allowance :: struct {
	util:   f32, // 0..1 of it used
	resets: i64, // unix seconds it rolls over at
}

Limits :: struct {
	session: Allowance,
	week:    Allowance,
	fable:   Allowance,
}

// A reading is per window, not per event. Only a turn running on Fable is told
// about the Fable week — a Haiku turn's record carries the session and the
// week and stops — so assigning the whole struct wiped the Fable meter back to
// unread every time anything else in the window took a turn, which is most of
// them. A window nobody reported is a window nobody reported: it keeps what it
// last said rather than being told it is unknown.
limits_merge :: proc(l: ^Limits, read: Limits) {
	if read.session.resets != 0 do l.session = read.session
	if read.week.resets != 0 do l.week = read.week
	if read.fable.resets != 0 do l.fable = read.fable
}

// A window past its reset is empty again, whoever read it and whenever. This
// is what lets the reading be kept over a restart and still be true: the
// number that goes stale carries the moment it stops being true beside it, so
// nothing has to be invalidated and no clock has to tick.
window_used :: proc(w: Allowance) -> f32 {
	if w.resets == 0 do return 0
	if time.time_to_unix(time.now()) >= w.resets do return 0
	return w.util
}

// Ordered oldest first, which is the order the file keeps them in, so nothing
// has to sort.
Ledger :: struct {
	days:   [dynamic]Day,
	limits: Limits,
	last:   string, // the text last written, so a window spending nothing writes nothing
}

usage_day_now :: proc() -> int {
	return int(time.time_to_unix(time.now()) / (24 * 60 * 60))
}

usage_day :: proc(l: ^Ledger, day: int) -> Usage {
	for d in l.days do if d.day == day do return d.use
	return {}
}

// The one writer. A turn's numbers go through here on their way out of its
// slot and nowhere else, which is what makes the day's figure a total rather
// than a guess at one.
usage_bank :: proc(l: ^Ledger, u: Usage) {
	zero: Usage
	if u == zero do return
	day := usage_day_now()
	for &d in l.days do if d.day == day {
		usage_add(&d.use, u)
		return
	}
	append(&l.days, Day{day = day, use = u})
	// Days arrive in order — a window cannot run a turn yesterday — so the
	// list stays sorted by being appended to, and the old end is trimmed.
	if len(l.days) > USAGE_KEEP do ordered_remove(&l.days, 0)
}

usage_destroy :: proc(l: ^Ledger) {
	delete(l.days)
	delete(l.last)
}

@(private = "file")
USAGE_VERSION :: "2"

// One line a day: the fields in the order the struct has them. Written to the
// same config directory everything else here remembers itself in.
usage_text :: proc(l: ^Ledger) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "version %s", USAGE_VERSION)
	fmt.sbprintfln(
		&b,
		"limits %.4f %d %.4f %d %.4f %d",
		l.limits.session.util,
		l.limits.session.resets,
		l.limits.week.util,
		l.limits.week.resets,
		l.limits.fable.util,
		l.limits.fable.resets,
	)
	for d in l.days {
		fmt.sbprintfln(
			&b,
			"day %d %d %d %d %d %d",
			d.day,
			d.use.input,
			d.use.output,
			d.use.cache_read,
			d.use.cache_write,
			d.use.turns,
		)
	}
	return strings.to_string(b)
}

usage_load :: proc(l: ^Ledger) {
	data, err := os.read_entire_file(config_path("usage"), context.temp_allocator)
	if err != nil do return
	lines := each_line(string(data))
	for line in iter_next(&lines) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 2 && f[0] == "version" {
			if f[1] != USAGE_VERSION do return // written under an older shape
			continue
		}
		if len(f) == 7 && f[0] == "limits" {
			session, _ := strconv.parse_f64(f[1])
			week, _ := strconv.parse_f64(f[3])
			fable, _ := strconv.parse_f64(f[5])
			l.limits.session = {util = f32(session), resets = atoi(f[2])}
			l.limits.week = {util = f32(week), resets = atoi(f[4])}
			l.limits.fable = {util = f32(fable), resets = atoi(f[6])}
			continue
		}
		if len(f) != 7 || f[0] != "day" do continue
		d := Day{day = int(atoi(f[1]))}
		d.use.input = int(atoi(f[2]))
		d.use.output = int(atoi(f[3]))
		d.use.cache_read = int(atoi(f[4]))
		d.use.cache_write = int(atoi(f[5]))
		d.use.turns = int(atoi(f[6]))
		append(&l.days, d)
	}
	l.last = strings.clone(usage_text(l))
}

// Called on the same slow tick the rest of what this program remembers is
// written on, and on the way out.
usage_save :: proc(l: ^Ledger) {
	text := usage_text(l)
	if text == l.last do return
	delete(l.last)
	l.last = strings.clone(text)
	_ = os.write_entire_file(config_path("usage"), transmute([]byte)text)
}

@(private = "file")
atoi :: proc(s: string) -> i64 {
	v, _ := strconv.parse_i64(s)
	return v
}

// --- what is on screen --------------------------------------------------------

// Today, whole: what finished turns banked plus what the running ones have run
// up so far.
app_usage_today :: proc(app: ^App) -> Usage {
	u := usage_day(&app.usage, usage_day_now())
	for t in app.turns do if t.live do usage_add(&u, runner_usage(&t.runner))
	return u
}

// A count at a glance: four figures at most, so the line of tokens does not
// change width every time a message lands.
usage_short :: proc(n: int) -> string {
	switch {
	case n >= 10_000_000:
		return fmt.tprintf("%dM", n / 1_000_000)
	case n >= 1_000_000:
		return fmt.tprintf("%.1fM", f64(n) / 1_000_000)
	case n >= 10_000:
		return fmt.tprintf("%dk", n / 1000)
	case n >= 1_000:
		return fmt.tprintf("%.1fk", f64(n) / 1000)
	}
	return fmt.tprintf("%d", n)
}

// How much of an allowance is gone, in the colour that says so: the ramp runs
// from spent-nothing to spent-it-all, and a meter that is only ever one colour
// is a meter nobody reads twice.
usage_meter_color :: proc(used: f32) -> Color {
	if used < 0.5 do return color_mix(GREEN, ACCENT, used * 2)
	return color_mix(ACCENT, RED, min((used - 0.5) * 2, 1))
}

// How long a window has left, short enough to sit beside its name.
usage_until :: proc(resets: i64) -> string {
	left := resets - time.time_to_unix(time.now())
	if left <= 0 do return ""
	if left < 60 * 60 do return fmt.tprintf("%dm", left / 60)
	if left < 24 * 60 * 60 do return fmt.tprintf("%dh %dm", left / 3600, (left % 3600) / 60)
	days, hours := left / 86400, (left % 86400) / 3600
	if hours == 0 do return fmt.tprintf("%dd", days)
	return fmt.tprintf("%dd %dh", days, hours)
}

// Wider and taller than it was, because it says three things now rather than
// two and they are the point of the panel: at the old size the meters were a
// footnote under a dollar figure, and the figure is gone.
USAGE_W :: f32(310)
USAGE_H :: f32(190)
@(private = "file")
USAGE_PAD :: f32(16)
@(private = "file")
METER_H :: f32(8)
@(private = "file")
METER_TOP :: f32(74)
@(private = "file")
METER_ROW :: f32(38)

// The corner. `strip` is the box along the bottom of the window — the composer
// or the capture box — so that a window too narrow to have room beside it puts
// this above it rather than on top of it.
draw_usage :: proc(app: ^App, full: Rect, strip: Rect) {
	ui := &app.ui

	u := app_usage_today(app)
	live := app_turns_live(app)

	// Always there, and this is the second try at that. It used to hide until
	// something had been spent or an allowance read, which meant a window
	// opened on a fresh day showed nothing at all and read as a feature that
	// had not landed. What is left of the plan is worth a corner even when the
	// answer is "all of it" — so the panel stands, and a window not yet read
	// says so rather than being absent.
	show := app.overlay != .Launcher
	a := ui_anim(ui, ui_id("usage"), show ? 1 : 0, 12)
	if a < 0.01 do return

	x := full.x + full.w - PAD - USAGE_W
	y := full.y + full.h - PAD - USAGE_H
	if strip.w > 0 && x < strip.x + strip.w + 12 do y = strip.y - 10 - USAGE_H
	box := Rect{x, y + (1 - a) * 16, USAGE_W, USAGE_H}

	// A halo rather than a brighter panel: the corner should catch the eye
	// from across the room while a turn is running, and sit still when none
	// is. The glow does not vary with time, so holding it costs no frames.
	if live > 0 {
		g := f32(44)
		ui_quad(
			ui,
			{box.x - g, box.y - g, box.w + g * 2, box.h + g * 2},
			{0, 0},
			{1, 1},
			color_alpha(ACCENT, 0.30 * a),
			WHITE_TEX,
			NO_ROUND,
			.Glow,
		)
	}
	ui_rect(ui, {box.x + 1, box.y + 5, box.w, box.h}, color_alpha(Color(0xff000000), 0.30 * a), 14)
	ui_rect(ui, box, color_alpha(PANEL, 0.97 * a), 14)

	// The size of the day, which is what the dollars were standing in for. It
	// counts up rather than jumping, because turns land one at a time and the
	// point of the corner is to be worth glancing at while the work runs.
	shown := int(ui_anim(ui, ui_id("usage", 1), f32(u.turns), 7) + 0.5)
	head := shown == 1 ? "1 turn" : fmt.tprintf("%d turns", shown)
	hw := ui_text(ui, &ui.bold, head, {box.x + USAGE_PAD, box.y + 14}, 20, color_alpha(TEXT, a))
	// What the count is of. A window left open overnight would otherwise say a
	// number that quietly became yesterday's.
	ui_text(ui, &ui.regular, "today", {box.x + USAGE_PAD + hw + 8, box.y + 22}, 12, color_alpha(FAINT, a))

	// What is happening, while anything is. Nothing takes its place when the
	// window is idle: the count above already said what the day came to.
	if live > 0 {
		label := fmt.tprintf("%d running", live)
		pulse := 0.55 + 0.45 * (0.5 + 0.5 * math.sin(ui.time * 5))
		ui.time_effects = true
		DOT :: f32(7)
		lw := font_width(&ui.regular, label, 12)
		pill := Rect{box.x + box.w - USAGE_PAD - (DOT + 7 + lw + 20), box.y + 16, DOT + 7 + lw + 20, 22}
		ui_rect(ui, pill, color_alpha(ACCENT, 0.16 * pulse * a), 11)
		cx := pill.x + (pill.w - (DOT + 7 + lw)) / 2
		ui_circle(ui, {cx + DOT / 2, pill.y + pill.h / 2}, DOT / 2, color_alpha(ACCENT, pulse * a))
		ui_text_middle(ui, &ui.regular, label, cx + DOT + 7, pill, 12, color_alpha(ACCENT, pulse * a))
	}

	// Where it went. Cache reads are most of what a long turn sends and cost
	// almost nothing, so they are said apart from the tokens that do.
	line := fmt.tprintf("%s in · %s out · %s cached", usage_short(u.input), usage_short(u.output), usage_short(u.cache_read))
	buf: [96]u8
	line = font_ellipsize(&ui.regular, line, 11.5, box.w - USAGE_PAD * 2, buf[:])
	ui_text(ui, &ui.regular, line, {box.x + USAGE_PAD, box.y + 48}, 11.5, color_alpha(MUTED, a))

	// What is left of the plan, which is the whole of why the corner is here.
	// Three windows and not two: Fable has a week of its own, it is what this
	// window runs on by default, and it is the one that runs out first — a
	// panel that only knew the shared week said everything was fine on an
	// afternoon when the next turn would not start.
	session := window_used(app.usage.limits.session)
	week := window_used(app.usage.limits.week)
	fable := window_used(app.usage.limits.fable)
	meter(app, box, 0, "session", session, app.usage.limits.session.resets, live > 0, a)
	meter(app, box, 1, "week", week, app.usage.limits.week.resets, false, a)
	meter(app, box, 2, "fable week", fable, app.usage.limits.fable.resets, false, a)

	// Read off the panel rather than printed on it: there is no room for the
	// exact figures, and a copy with nothing selected takes this.
	ui_hover_text(
		ui,
		box,
		fmt.tprintf(
			"today: %d in · %d out · %d cache read · %d cache write · %d turns · session %.0f%% left, week %.0f%% left, fable week %.0f%% left",
			u.input,
			u.output,
			u.cache_read,
			u.cache_write,
			u.turns,
			(1 - session) * 100,
			(1 - week) * 100,
			(1 - fable) * 100,
		),
	)
}

// One allowance: what it is called and how long it has left on the left, how
// much of it is gone on the right, and the bar under both.
@(private = "file")
meter :: proc(app: ^App, box: Rect, row: int, name: string, used: f32, resets: i64, sheen: bool, a: f32) {
	ui := &app.ui
	top := box.y + METER_TOP + f32(row) * METER_ROW
	col := usage_meter_color(used)

	// A window nobody has read yet is not a window with nothing used in it.
	// `resets` is the one variable that answers it: the harness sends a reset
	// time with every reading, so a zero there means no turn has reported one
	// since this window opened, and the meter says that instead of drawing a
	// confident empty bar.
	known := resets != 0

	label := name
	if left := usage_until(resets); left != "" do label = fmt.tprintf("%s · %s left", name, left)
	else if !known do label = fmt.tprintf("%s · after the next turn", name)
	ui_text(ui, &ui.regular, label, {box.x + USAGE_PAD, top}, 11.5, color_alpha(FAINT, a))

	// What is left, not what is gone. Both are the same number and this is
	// the one that answers the question the corner is glanced at to answer.
	pct := known ? fmt.tprintf("%.0f%% left", (1 - used) * 100) : "—"
	pw := font_width(&ui.bold, pct, 12.5)
	ui_text(ui, &ui.bold, pct, {box.x + box.w - USAGE_PAD - pw, top - 1}, 12.5, color_alpha(known ? col : FAINT, a))

	track := Rect{box.x + USAGE_PAD, top + 18, box.w - USAGE_PAD * 2, METER_H}
	ui_rect(ui, track, color_alpha(BORDER, 0.55 * a), METER_H / 2)
	// The bar is what is left, because the figure beside it is: a bar drawn
	// to what was spent under a number reading "59% left" is two answers to
	// one question and the eye takes the wrong one. It drains rather than
	// fills as the window goes, which is the shape the thing actually has.
	//
	// The fill eases into place, and a reading that has just landed is worth
	// watching arrive. An allowance nearly gone still shows a stub, so the
	// meter reads as a meter rather than as an empty slot.
	grown := ui_anim(ui, ui_id("usage-meter", row), 1 - used, 9)
	if grown <= 0 || !known do return
	fill := Rect{track.x, track.y, max(track.w * grown, METER_H), track.h}
	ui_rect(ui, fill, color_alpha(col, a), METER_H / 2)
	// The sheen travels along the session meter while a turn is running: it
	// is the one thing here that is moving while you watch it.
	if sheen {
		ui_quad(ui, fill, {0, 0}, {1, 1}, color_alpha(col, 0.9 * a), WHITE_TEX, METER_H / 2, .Sheen)
		ui.time_effects = true
	}
}
