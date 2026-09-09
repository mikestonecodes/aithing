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

// The panel, in the parts it is made of, because the two widths it can be are
// both sums of them and were both written out as numbers once. `usage_rect`
// and `chips_right` work off these, so a ring getting thicker cannot leave the
// panel a pixel too narrow for its own dial.
@(private = "file")
USAGE_PAD :: f32(14)
// One ring per window, thick enough to read at a glance and spaced enough that
// three of them are three rings rather than a gradient.
@(private = "file")
RING_W :: f32(8)
@(private = "file")
RING_GAP :: f32(3.5)
// Wide enough that three rings and the hole in the middle both survive: the
// rings ate the hole at ten thick, and a hole too small for "83%" is a dial
// with nowhere to put the one figure it has to show when the names are gone.
@(private = "file")
DIAL_D :: f32(104)
// The room the three names need beside the dial, and the gap they stand off
// it. Under this there is not enough for "fable" and a figure, and a column of
// clipped words is worse than no column: the dial still says how much is gone,
// and the hover line still says which ring is which.
@(private = "file")
NAMES_W :: f32(56)
@(private = "file")
NAMES_GAP :: f32(14)
// One name and its figure, stacked. Three of these are taller than the dial
// is, which is why they are centred on it rather than laid out inside it.
@(private = "file")
NAME_H :: f32(36)

USAGE_W :: f32(214)
USAGE_H :: f32(150)
// The dial and its margins, and nothing else: what the panel shrinks to. The
// panel gives up width to the box along the bottom rather than jumping above
// it — it used to move up there, which put the one thing that never changes in
// a place that changed every time the box grew a line. What it gives up first
// is the names, because the dial is the part that can be read at a glance.
USAGE_MIN :: USAGE_PAD * 2 + DIAL_D
// The width it takes to keep them.
@(private = "file")
USAGE_NAMED :: USAGE_MIN + NAMES_GAP + NAMES_W

// Where the corner stands, and the one place that answers it: the bottom
// right, in whatever room the box along the bottom leaves beside it. The box
// asks too — its chip row ends where this begins (see chips_right) — and the
// two of them working it out separately is how the chips ended up underneath
// an opaque readout of three numbers.
usage_rect :: proc(full, strip: Rect) -> Rect {
	w := USAGE_W
	if strip.w > 0 {
		room := full.x + full.w - PAD - (strip.x + strip.w + 12)
		w = clamp(room, USAGE_MIN, USAGE_W)
	}
	// Once there is not room for the names the panel is the dial and nothing
	// else, square: a wide panel with a small dial floating in the middle of
	// it is a panel mostly made of nothing, and the width it stops asking for
	// is width the chips underneath it get back.
	if w < USAGE_NAMED do w = USAGE_MIN
	h := w < USAGE_NAMED ? USAGE_MIN : USAGE_H
	return {full.x + full.w - PAD - w, full.y + full.h - PAD - h, w, h}
}

// The corner. `strip` is the box along the bottom of the window — the composer
// or the capture box — and the panel squeezes to sit beside it.
//
// Three windows, three rings of one dial, outermost first. It was three rows
// of "41%" for a while, which is the same three numbers and reads as a table:
// you have to take all three in and compare them before you know whether you
// are near anything. A ring says that in its shape — how much of the way round
// it has gone — before a digit is read, and three concentric ones say which is
// furthest along without any of them being read at all.
draw_usage :: proc(app: ^App, full: Rect, strip: Rect) {
	ui := &app.ui

	show := app.overlay != .Launcher
	a := ui_anim(ui, ui_id("usage"), show ? 1 : 0, 12)
	if a < 0.01 do return

	box := usage_rect(full, strip)
	box.y += (1 - a) * 16

	ui_rect(ui, {box.x + 1, box.y + 5, box.w, box.h}, color_alpha(Color(0xff000000), 0.30 * a), 14)
	ui_rect(ui, box, color_alpha(PANEL, 0.97 * a), 14)

	// The names sit beside the dial when there is room for them, and the dial
	// takes the middle of the panel when there is not. One question — how wide
	// is the panel — with one answer, so the dial cannot end up centred in a
	// panel that is also drawing a column.
	d := min(min(box.h, box.w) - USAGE_PAD * 2, DIAL_D)
	named := box.w >= USAGE_NAMED
	cx := named ? box.x + USAGE_PAD + d / 2 : box.x + box.w / 2
	centre := [2]f32{cx, box.y + box.h / 2}

	// The three of them, in the order the rings are drawn in and the order the
	// names are listed in, because those two orders being the same is the only
	// thing that says which ring is which. They were three fields read out
	// separately in three places — the rings, the column and the line under
	// the pointer — which is three chances to put them in a different order.
	windows := [3]struct {
		long, short: string,
		w:           Allowance,
	} {
		{"session", "session", app.usage.limits.session},
		{"week", "week", app.usage.limits.week},
		{"fable week", "fable", app.usage.limits.fable},
	}
	worst: f32
	for n in windows do worst = max(worst, window_used(n.w))

	// Tracks first, then every slice over them, so a ring's halo spills across
	// its neighbours' grooves rather than being cut off at them.
	for i in 0 ..< len(windows) {
		ui_dial(ui, centre, ring_r(d, i), RING_W, 1, color_alpha(TRACK, 0.95 * a))
	}
	for n, i in windows {
		// A window nobody has read yet is not a window with nothing used in
		// it. `resets` is the one variable that answers it: the harness sends
		// a reset time with every reading, so a zero there means nothing has
		// reported one, and the ring is left as bare track rather than drawn
		// as a confident nought.
		if n.w.resets == 0 do continue
		used := window_used(n.w)
		// The slice eases round. A reading that has just landed — and the
		// first one lands a second or so after the window opens — is worth
		// watching arrive.
		sweep := ui_anim(ui, ui_id("usage-ring", i), used, 9)
		col := usage_meter_color(used)
		r := ring_r(d, i)
		// The same slice again, wider and faint, so the arc looks lit rather
		// than painted on — and the brighter it is the fuller the window, so
		// the dial glows harder the closer it is to the end of one. It was a
		// disc of light behind the whole thing first, which put the brightest
		// part in the hole in the middle: nothing is there, and the word that
		// is came out through a red haze.
		ui_dial(ui, centre, r + 5, RING_W + 11, sweep, color_alpha(col, (0.13 + 0.27 * used) * a), 0.11)
		ui_dial(ui, centre, r, RING_W, sweep, color_alpha(col, a))
	}

	// What is in the middle of the dial depends on whether the names got
	// drawn, because it is answering whatever they are not: with the column
	// beside it the rings are already labelled and the hole says what the
	// whole panel measures, and without it the hole is the only place a figure
	// can go, so it takes the window that is furthest along.
	hole := Rect{centre.x - 20, centre.y - 11, 40, 22}
	if named {
		ui_text_centred(ui, &ui.regular, "used", hole, 11, color_alpha(FAINT, a))
	} else {
		ui_text_centred(ui, &ui.bold, usage_pct(worst), hole, 17, color_alpha(usage_meter_color(worst), a))
	}

	if named {
		lx := box.x + USAGE_PAD + d + NAMES_GAP
		room := box.x + box.w - USAGE_PAD - lx
		top := centre.y - NAME_H * 1.5 - 1
		for n, i in windows {
			name(app, {lx, top + f32(i) * NAME_H, room, 0}, i, n.long, n.short, n.w, a)
		}
	}

	// Read off the panel rather than printed on it, which is where the reset
	// times went: the dial says how much, the column says of what, and the
	// minute it comes back is a question you have to ask.
	line := strings.builder_make(context.temp_allocator)
	for n, i in windows {
		if i > 0 do strings.write_string(&line, " · ")
		fmt.sbprintf(&line, "%s %s used%s", n.long, usage_pct(window_used(n.w)), until_say(n.w.resets))
	}
	ui_hover_text(ui, box, strings.to_string(line))
}

// The unspent part of a ring. Darker than the panel rather than lighter, so an
// empty allowance reads as a groove waiting to be filled and a full one as
// something sitting in it.
@(private = "file")
TRACK :: Color(0xff222525)

// Where one window's ring sits, outermost first. The order is the only thing
// that says which ring is which, and it is the order the names are listed in
// beside them.
@(private = "file")
ring_r :: proc(d: f32, i: int) -> f32 {
	return d / 2 - f32(i) * (RING_W + RING_GAP)
}

@(private = "file")
until_say :: proc(resets: i64) -> string {
	left := usage_until(resets)
	return left == "" ? "" : fmt.tprintf(" (%s left)", left)
}

// One ring's name and its figure, beside the dial and in the ring's own
// colour, ordered outermost at the top — which is the only thing that says
// which ring is which. The figure is what `/usage` would say about it and
// nothing else: this window worked its own numbers out for a while, and they
// disagreed with the account.
@(private = "file")
name :: proc(app: ^App, at: Rect, i: int, long, short: string, w: Allowance, a: f32) {
	ui := &app.ui
	used := window_used(w)
	known := w.resets != 0
	col := known ? usage_meter_color(used) : FAINT

	// The short name when the long one will not fit whole: a panel squeezed in
	// beside the capture box has room for "fable" and not for "fable week",
	// and "fable w..." is not the name of anything.
	buf, alt: [32]u8
	label := font_ellipsize(&ui.regular, long, 11, at.w - 11, buf[:])
	if label != long do label = font_ellipsize(&ui.regular, short, 11, at.w - 11, alt[:])
	ui_circle(ui, {at.x + 3.5, at.y + 7}, 3.5, color_alpha(col, a))
	ui_text(ui, &ui.regular, label, {at.x + 12, at.y}, 11, color_alpha(FAINT, a))

	// The same easing the ring runs on, off the same stored value, so the
	// figure and the slice it labels cannot say two different things.
	shown := known ? ui_anim(ui, ui_id("usage-ring", i), used, 9) : 0
	ui_text(ui, &ui.bold, known ? usage_pct(shown) : "—", {at.x, at.y + 13}, 17, color_alpha(col, a))
}
