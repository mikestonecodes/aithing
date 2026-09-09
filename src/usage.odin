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
//
// The knee is at three fifths and the green half is squared, because the ramp
// used to be straight from nothing to half and a week 18% spent came out
// visibly gold — a third of the way to the warning colour for a window with
// four fifths of it left. A figure only earns a colour once there is something
// to say, so the low end stays green and the last two fifths carry the change.
USAGE_KNEE :: f32(0.6)
usage_meter_color :: proc(used: f32) -> Color {
	if used < USAGE_KNEE {
		t := used / USAGE_KNEE
		return color_mix(GREEN, ACCENT, t * t)
	}
	return color_mix(ACCENT, RED, min((used - USAGE_KNEE) / (1 - USAGE_KNEE), 1))
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

// The dial, in the parts it is made of. One ring per window, thick enough to
// read at a glance and spaced enough that three of them are three rings rather
// than a gradient.
@(private = "file")
RING_W :: f32(7.5)
@(private = "file")
RING_GAP :: f32(2.5)
// How wide the dial is when it has the room, how small it will go before it
// stops fitting beside the box along the bottom, and how far it stands off
// that box and off the corner of the window.
DIAL_D :: f32(84)
@(private = "file")
DIAL_MIN :: f32(56)
@(private = "file")
DIAL_GAP :: f32(12)

// Where the dial stands, and the one place that answers it: the bottom right
// corner, in whatever room the box along the bottom leaves beside it.
//
// It was a panel here for a long time, with the figures printed down the side
// of it and a slab of background behind the lot. The slab was there to hold the
// words; take the words away and there is nothing for it to hold, and the rings
// sit on the window the way the cards do. Without the slab there is also
// nothing to keep off the two chips the composer carries: the panel was opaque
// and wide enough to come down over them, and a bare dial standing outside the
// box entirely cannot.
usage_rect :: proc(full, strip: Rect) -> Rect {
	right := full.x + full.w - PAD
	bottom := full.y + full.h - PAD
	if strip.w <= 0 do return {right - DIAL_D, bottom - DIAL_D, DIAL_D, DIAL_D}
	// Beside the box while there is room for it, shrinking into what is left.
	room := right - (strip.x + strip.w + DIAL_GAP)
	if room >= DIAL_MIN {
		d := min(room, DIAL_D)
		return {right - d, bottom - d, d, d}
	}
	// A narrow window is all box: it is centred and takes everything but a
	// margin, so there is no beside to be in. The dial goes above its top right
	// corner rather than shrinking away to nothing or sitting on the chips.
	return {right - DIAL_D, strip.y - DIAL_GAP - DIAL_D, DIAL_D, DIAL_D}
}

// The dial. `strip` is the box along the bottom of the window — the composer
// or the capture box — and the dial sits beside it.
//
// Three windows, three rings, outermost first. It was three rows of "41%" for
// a while, which is the same three numbers and reads as a table: you have to
// take all three in and compare them before you know whether you are near
// anything. A ring says that in its shape — how much of the way round it has
// gone — before a digit is read, and three concentric ones say which is
// furthest along without any of them being read at all.
//
// So the digits are not on screen at all now. They are what the pointer is
// for: the rings are the answer to "am I near the end of anything", and the
// popover is the answer to "near the end of which, and how long until it comes
// back", which is a question you only ask once the first answer is yes.
draw_usage :: proc(app: ^App, full: Rect, strip: Rect) {
	ui := &app.ui

	show := app.overlay != .Launcher
	a := ui_anim(ui, ui_id("usage"), show ? 1 : 0, 12)
	if a < 0.01 do return

	box := usage_rect(full, strip)
	box.y += (1 - a) * 16
	d := box.w
	centre := [2]f32{box.x + d / 2, box.y + d / 2}

	// The three of them, in the order the rings are drawn in and the order the
	// popover lists them in, because those two orders being the same is the
	// only thing that says which ring is which. They were three fields read
	// out separately in three places — the rings, the column and the line
	// under the pointer — which is three chances to put them in a different
	// order.
	windows := [3]struct {
		long, short: string,
		w:           Allowance,
	} {
		{"session", "session", app.usage.limits.session},
		{"week", "week", app.usage.limits.week},
		{"fable week", "fable", app.usage.limits.fable},
	}

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
		// was came out through a red haze.
		ui_dial(ui, centre, r + 4, RING_W + 9, sweep, color_alpha(col, (0.13 + 0.27 * used) * a), 0.12)
		ui_dial(ui, centre, r, RING_W, sweep, color_alpha(col, a))
	}

	// The words, only while the pointer is on the rings. The popover is not
	// drawn over the dial and does not reach it, so nothing it says can hide
	// the thing it is saying it about.
	pop := ui_anim(ui, ui_id("usage-pop"), ui_hovered(ui, box) ? 1 : 0, 16)
	if pop > 0.01 do popover(app, box, windows[:], pop * a)

	// What Super+C takes off the dial: the whole reading on one line, whether
	// or not the popover has come up.
	line := strings.builder_make(context.temp_allocator)
	for n, i in windows {
		if i > 0 do strings.write_string(&line, " · ")
		fmt.sbprintf(&line, "%s %s used%s", n.long, usage_pct(window_used(n.w)), until_say(n.w.resets))
	}
	ui_hover_text(ui, box, strings.to_string(line))
}

// The unspent part of a ring. Nearly black, and darker than anything else in
// the window: a groove cut into the background for the arc to sit in. It was
// only a shade under the panel it used to be drawn on, which on the bare window
// read as three grey rings of its own — a dial that looked full of something
// when it was full of nothing.
@(private = "file")
TRACK :: Color(0xff141616)

// Where one window's ring sits, outermost first. The order is the only thing
// that says which ring is which, and it is the order the popover lists them
// in.
@(private = "file")
ring_r :: proc(d: f32, i: int) -> f32 {
	return d / 2 - f32(i) * (RING_W + RING_GAP)
}

// How long a window has left, said in full. The bare duration is what the dial
// is measured in and reads as one beside a percentage — "41% 2h 40m" is a rate
// until the word is there.
@(private = "file")
until_left :: proc(resets: i64) -> string {
	return fmt.tprintf("%s left", usage_until(resets))
}

@(private = "file")
until_say :: proc(resets: i64) -> string {
	left := usage_until(resets)
	return left == "" ? "" : fmt.tprintf(" (%s left)", left)
}

@(private = "file")
POP_PAD :: f32(14)
@(private = "file")
POP_ROW :: f32(34)

// What each ring is and how long it has left, standing above the dial while
// the pointer is on it. One row per ring, top to bottom as the rings go
// outside in, in the ring's own colour — the order and the colour together are
// the whole of what ties a row to its arc.
//
// It is sized to what it is about to say rather than to a number written here:
// the column that used to be beside the dial had a width picked by hand, and
// "fable week" ended a pixel off the edge of it.
@(private = "file")
popover :: proc(app: ^App, dial: Rect, windows: []struct {
		long, short: string,
		w:           Allowance,
	}, a: f32) {
	ui := &app.ui

	w: f32
	for n in windows {
		used, known := window_used(n.w), n.w.resets != 0
		row := font_width(&ui.regular, n.long, 11) + 12
		figure := font_width(&ui.bold, known ? usage_pct(used) : "—", 15)
		if known && usage_until(n.w.resets) != "" {
			figure += 7 + font_width(&ui.regular, until_left(n.w.resets), 10.5)
		}
		w = max(w, row, figure)
	}
	w += POP_PAD * 2

	h := POP_PAD * 2 + POP_ROW * f32(len(windows))
	// Above the dial, and never off the top of the window: a dial that has had
	// to move up out of a box filling a short window has less above it than
	// the popover is tall.
	// Right edge to the dial's, so a popover wider than the dial grows into the
	// window rather than off the side of it.
	box := Rect{dial.x + dial.w - w, max(dial.y - DIAL_GAP - h, PAD), w, h}
	box.y += (1 - a) * 8

	ui_rect(ui, {box.x + 1, box.y + 5, box.w, box.h}, color_alpha(Color(0xff000000), 0.30 * a), 12)
	ui_rect(ui, box, color_alpha(PANEL, 0.97 * a), 12)

	for n, i in windows {
		at := [2]f32{box.x + POP_PAD, box.y + POP_PAD + f32(i) * POP_ROW}
		used, known := window_used(n.w), n.w.resets != 0
		col := known ? usage_meter_color(used) : FAINT

		ui_circle(ui, {at.x + 3.5, at.y + 7}, 3.5, color_alpha(col, a))
		ui_text(ui, &ui.regular, n.long, {at.x + 12, at.y}, 11, color_alpha(FAINT, a))

		// The same easing the ring runs on, off the same stored value, so the
		// figure and the slice it labels cannot say two different things.
		shown := known ? ui_anim(ui, ui_id("usage-ring", i), used, 9) : 0
		figure := known ? usage_pct(shown) : "—"
		x := ui_text(ui, &ui.bold, figure, {at.x, at.y + 13}, 15, color_alpha(col, a))
		if known && usage_until(n.w.resets) != "" {
			ui_text(ui, &ui.regular, until_left(n.w.resets), {at.x + x + 7, at.y + 17}, 10.5, color_alpha(FAINT, a))
		}
	}
}
