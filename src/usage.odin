package aithing

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// What is left of the plan, and the corner of the screen that says so.
//
// This corner has been wrong twice, and both times for the same reason: it
// answered a question nobody was asking. First it led with `total_cost_usd`,
// a price that is never charged on a subscription. Then it said what it had
// worked out from those numbers — tokens, turns, "59% left" — while the thing
// it was standing in for, `/usage` in the harness, says "41% used". Two
// numbers for one question, and the one on screen was the one nobody could
// check.
//
// So there is one question here now and the harness owns the answer to it:
// the three windows `/usage` reports, said the way `/usage` says them. There
// is no ledger, no day, no token count — a figure this window worked out for
// itself is a figure that can disagree with the account, and every one of
// them did.

// One window: how much of it is gone, and when it starts again.
// Not `Window`: that is the one the program is drawn in.
Allowance :: struct {
	util:   f32, // 0..1 used, exactly as the harness reports it
	resets: i64, // unix seconds it rolls over at
}

// The three the harness reports on a `rate_limit_event`, under the names it
// gives them in `/usage`: `five_hour` is the session, `seven_day` the week
// across every model, and `seven_day_overage_included` is Fable's own week —
// "Fable limit", which is what this window runs on and what runs out first.
Limits :: struct {
	session: Allowance,
	week:    Allowance,
	fable:   Allowance,
	read_at: i64, // unix seconds the newest of these arrived, 0 for never
}

// A reading is per window, not per event. Only a turn running on Fable is told
// about the Fable week — every other model's record carries the session and
// the week and stops — so assigning the whole struct wiped that meter back to
// unread on the next turn anything else took, which is most of them. A window
// nobody reported keeps what it last said.
limits_merge :: proc(l: ^Limits, read: Limits) {
	if read.session.resets != 0 do l.session = read.session
	if read.week.resets != 0 do l.week = read.week
	if read.fable.resets != 0 do l.fable = read.fable
	l.read_at = time.time_to_unix(time.now())
}

// The one way in, and it writes through. A reading is worth more to the next
// window that opens than to this one — the panel is drawn from the newest
// answer either way, and the file is what a window has to show for itself in
// the second before its own probe comes back. It used to be written on the
// slow tick everything else here is saved on, so a window killed between the
// reading and the tick opened blank next time and asked again.
usage_take :: proc(l: ^Ledger, read: Limits) {
	limits_merge(&l.limits, read)
	usage_save(l)
}

// A window past its reset is empty again, whoever read it and whenever. This
// is what lets a reading be kept over a restart and still be true: the number
// that goes stale carries the moment it stops being true beside it, so nothing
// has to be invalidated and no clock has to tick.
window_used :: proc(w: Allowance) -> f32 {
	if w.resets == 0 do return 0
	if time.time_to_unix(time.now()) >= w.resets do return 0
	return w.util
}

Ledger :: struct {
	limits: Limits,
	last:   string, // the text last written, so a window reading nothing writes nothing
}

usage_destroy :: proc(l: ^Ledger) {
	delete(l.last)
}

// --- what is remembered -------------------------------------------------------

@(private = "file")
USAGE_VERSION :: "3"

// One line, and it is the reading: written to the same config directory
// everything else here remembers itself in, so a window opening has something
// to draw while it asks for a fresher one.
usage_text :: proc(l: ^Ledger) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "version %s", USAGE_VERSION)
	fmt.sbprintfln(
		&b,
		"limits %d %.4f %d %.4f %d %.4f %d",
		l.limits.read_at,
		l.limits.session.util,
		l.limits.session.resets,
		l.limits.week.util,
		l.limits.week.resets,
		l.limits.fable.util,
		l.limits.fable.resets,
	)
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
		if len(f) != 8 || f[0] != "limits" do continue
		session, _ := strconv.parse_f64(f[2])
		week, _ := strconv.parse_f64(f[4])
		fable, _ := strconv.parse_f64(f[6])
		l.limits.read_at = atoi(f[1])
		l.limits.session = {util = f32(session), resets = atoi(f[3])}
		l.limits.week = {util = f32(week), resets = atoi(f[5])}
		l.limits.fable = {util = f32(fable), resets = atoi(f[7])}
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

// --- asking, without waiting for a turn ---------------------------------------

// The corner used to say "after the next turn" on three lines until somebody
// started some work, which is exactly when nobody is looking at it. The
// reading is not a turn's — it is the account's, and every `claude -p` carries
// it on its stream before the model has said a word — so the window asks for
// itself the moment it opens: a turn is started, the reading is taken off it,
// and the process is killed on the spot. What is paid for is the request; the
// answer arrives before there is any work to pay for.
//
// It runs on Fable because the Fable week is only on the record of a turn that
// ran on Fable, and it is the window that runs out first.
USAGE_PROBE_FRESH :: i64(120) // seconds a reading is worth reopening on

probe_start :: proc(app: ^App) {
	if runner_busy(&app.probe) do return
	if time.time_to_unix(time.now()) - app.usage.limits.read_at < USAGE_PROBE_FRESH do return
	runner_start(&app.probe, app.cwd, "", "hi", model_flag[.Fable], effort_flag[.Low], PROBE_SLOT)
}

// Everything the probe says is thrown away except the one record it was
// started for.
probe_pump :: proc(app: ^App) -> bool {
	events := runner_drain(&app.probe, context.temp_allocator)
	read := false
	for &e in events {
		if e.kind == .Limits {
			usage_take(&app.usage, e.limits)
			runner_stop(&app.probe)
			read = true
		}
		event_destroy(&e)
	}
	return read
}

// --- what is on screen --------------------------------------------------------

// How much of an allowance is gone, in the colour that says so: the ramp runs
// from spent-nothing to spent-it-all, and a figure that is only ever one
// colour is a figure nobody reads twice.
usage_meter_color :: proc(used: f32) -> Color {
	if used < 0.5 do return color_mix(GREEN, ACCENT, used * 2)
	return color_mix(ACCENT, RED, min((used - 0.5) * 2, 1))
}

// The same words `/usage` uses, so a figure here and a figure there can be put
// side by side: `%d%% used`, rounded down, never up — a window at 99.6% has
// not used it all.
usage_pct :: proc(used: f32) -> string {
	return fmt.tprintf("%d%%", int(used * 100))
}

// How long a window has left, for the line that only shows on hover.
usage_until :: proc(resets: i64) -> string {
	left := resets - time.time_to_unix(time.now())
	if left <= 0 do return ""
	if left < 60 * 60 do return fmt.tprintf("%dm", left / 60)
	if left < 24 * 60 * 60 do return fmt.tprintf("%dh %dm", left / 3600, (left % 3600) / 60)
	days, hours := left / 86400, (left % 86400) / 3600
	if hours == 0 do return fmt.tprintf("%dd", days)
	return fmt.tprintf("%dd %dh", days, hours)
}

USAGE_W :: f32(214)
USAGE_H :: f32(150)
// Narrow enough to keep three rows readable, and no narrower: the panel gives
// up width to the box along the bottom rather than jumping above it — it used
// to move up there, which put the one thing that never changes in a place that
// changed every time the box grew a line.
USAGE_MIN :: f32(150)
@(private = "file")
USAGE_PAD :: f32(16)
@(private = "file")
ROW_H :: f32(42)

// The corner. `strip` is the box along the bottom of the window — the composer
// or the capture box — and the panel squeezes to sit beside it.
draw_usage :: proc(app: ^App, full: Rect, strip: Rect) {
	ui := &app.ui

	show := app.overlay != .Launcher
	a := ui_anim(ui, ui_id("usage"), show ? 1 : 0, 12)
	if a < 0.01 do return

	w := USAGE_W
	if strip.w > 0 {
		room := full.x + full.w - PAD - (strip.x + strip.w + 12)
		w = clamp(room, USAGE_MIN, USAGE_W)
	}
	x := full.x + full.w - PAD - w
	y := full.y + full.h - PAD - USAGE_H
	box := Rect{x, y + (1 - a) * 16, w, USAGE_H}

	ui_rect(ui, {box.x + 1, box.y + 5, box.w, box.h}, color_alpha(Color(0xff000000), 0.30 * a), 14)
	ui_rect(ui, box, color_alpha(PANEL, 0.97 * a), 14)

	row(app, box, 0, "session", "session", app.usage.limits.session, a)
	row(app, box, 1, "week", "week", app.usage.limits.week, a)
	// Squeezed hard enough there is no room for both words, and "fable w..."
	// is not a name — the week is the only Fable window there is, so the row
	// drops the word rather than the letters.
	row(app, box, 2, "fable week", "fable", app.usage.limits.fable, a)

	// Read off the panel rather than printed on it, which is where the reset
	// times went: the rows say the number and nothing else.
	ui_hover_text(
		ui,
		box,
		fmt.tprintf(
			"session %s used%s · week %s used%s · fable week %s used%s",
			usage_pct(window_used(app.usage.limits.session)),
			until_say(app.usage.limits.session.resets),
			usage_pct(window_used(app.usage.limits.week)),
			until_say(app.usage.limits.week.resets),
			usage_pct(window_used(app.usage.limits.fable)),
			until_say(app.usage.limits.fable.resets),
		),
	)
}

@(private = "file")
until_say :: proc(resets: i64) -> string {
	left := usage_until(resets)
	return left == "" ? "" : fmt.tprintf(" (%s left)", left)
}

// One window: what it is called, and how much of it is gone. The figure is
// what `/usage` would say about it and nothing else — this window worked its
// own numbers out for a while, and they disagreed with the account.
@(private = "file")
row :: proc(app: ^App, box: Rect, at: int, name, short: string, w: Allowance, a: f32) {
	ui := &app.ui
	top := box.y + 14 + f32(at) * ROW_H

	// A window nobody has read yet is not a window with nothing used in it.
	// `resets` is the one variable that answers it: the harness sends a reset
	// time with every reading, so a zero there means nothing has reported one
	// and the row says so rather than printing a confident nought.
	used := window_used(w)
	known := w.resets != 0

	// The figure eases into place. A reading that has just landed — and the
	// first one lands a second or so after the window opens — is worth
	// watching arrive.
	shown := known ? ui_anim(ui, ui_id("usage-row", at), used, 9) : 0
	pct := known ? usage_pct(shown) : "—"
	col := known ? usage_meter_color(used) : FAINT
	pw := font_width(&ui.bold, pct, 30)
	ui_text(ui, &ui.bold, pct, {box.x + box.w - USAGE_PAD - pw, top}, 30, color_alpha(col, a))

	// The short name when the long one will not fit whole: a panel squeezed in
	// beside the capture box has room for "fable" and not for "fable week",
	// and "fable w..." is not the name of anything.
	room := box.w - USAGE_PAD * 2 - pw - 10
	buf, alt: [32]u8
	label := font_ellipsize(&ui.regular, name, 12.5, room, buf[:])
	if label != name do label = font_ellipsize(&ui.regular, short, 12.5, room, alt[:])
	ui_text(ui, &ui.regular, label, {box.x + USAGE_PAD, top + 11}, 12.5, color_alpha(FAINT, a))
}
