package aithing

import "core:math"

// Immediate mode: there is no widget tree and nothing is retained between
// frames except two ids (what the mouse is over, and what it grabbed). Every
// frame rebuilds one vertex buffer; the bindless table means the whole thing
// usually leaves as a single draw call.

Rect :: struct {
	x, y, w, h: f32,
}

Color :: distinct u32

color_alpha :: proc "contextless" (c: Color, a: f32) -> Color {
	v := u32(c)
	old := f32((v >> 24) & 0xff)
	return Color((v & 0x00ff_ffff) | u32(clamp(old * a, 0, 255)) << 24)
}

color_mix :: proc "contextless" (a, b: Color, t: f32) -> Color {
	out: u32
	for shift in ([4]u32{0, 8, 16, 24}) {
		ca := f32((u32(a) >> shift) & 0xff)
		cb := f32((u32(b) >> shift) & 0xff)
		out |= u32(clamp(ca + (cb - ca) * t, 0, 255)) << shift
	}
	return Color(out)
}

// Which shader path this vertex takes. Matches the EFFECT_* constants in
// src/shaders/ui.frag.
Effect :: enum u32 {
	None  = 0,
	Glow  = 1, // soft radial falloff
	Sheen = 2, // travelling highlight
	Ring  = 3, // fading annulus
	Text  = 4, // a glyph: the texture is a distance field, not coverage
	Punch = 5, // replaces what is under it: see ui_punch
	Pop   = 6, // a transcript tile: lit from inside, rim brightening on hover
	Wire  = 7, // the snake's thread, with a pulse travelling along it
	Dial  = 8, // a ring with a slice of it filled: see ui_dial
}

Vertex :: struct {
	pos:    [2]f32,
	uv:     [2]f32,
	col:    Color,
	tex:    u32,
	rect:   [4]f32, // centre + half extent, for the rounded-corner mask
	radius: f32,
	effect: Effect,
	param:  f32, // what it means depends on the effect
}

DrawCmd :: struct {
	clip:         Rect,
	punch:        bool, // drawn with the replacing pipeline, not the blending one
	index_offset: u32,
	index_count:  u32,
}

UI :: struct {
	verts:      [dynamic]Vertex,
	indices:    [dynamic]u32,
	cmds:       [dynamic]DrawCmd,
	clip:       Rect,
	clip_stack: [dynamic]Rect,
	// What is drawn is drawn at the size it will end up at, and this is where
	// it actually lands: see ui_push_zoom.
	zoom:       f32,
	zoom_at:    [2]f32,
	punching:   bool,

	regular:    Font,
	bold:       Font,
	mono:       Font,

	size:       [2]f32,
	mouse:      [2]f32,
	has_mouse:  bool,
	// The pointer only steals a selection on the frame it actually moved:
	// a menu that opened under a resting cursor keeps the keyboard's row.
	mouse_moved: bool,
	last_mouse: [2]f32,
	down:       bool,
	pressed:    bool,
	released:   bool,
	click_count: int, // 2 on a double click, 3 on a triple
	scroll:     f32, // wheel notches, ~10 per click
	scroll_px:  f32, // touchpad travel, in pixels
	scroll_x:   f32,
	scroll_x_px: f32,
	scroll_end: bool, // the fingers left the touchpad this frame
	mods:       Mods,

	hot:        u64,
	active:     u64,
	// The widget that keys go to. Unlike hot/active this survives frames, so
	// the composer keeps the caret while the pointer is somewhere else.
	focus:      u64,
	cursor_text: bool, // set when the pointer is over something text-editable
	// What the pointer is resting on, in words: a card, a paragraph of an
	// answer, a tool's output. Copy with nothing selected takes this. There is
	// nowhere else to read it from — everything on screen is drawn out of the
	// app state and thrown away again the same frame — so whatever draws text
	// says what it drew here on the way past, and the innermost thing under
	// the pointer wins by being drawn last.
	hover_text: [dynamic]u8,
	// Where the pointer was when the button went down. A widget that has
	// moved out from under a still pointer between the press and the release
	// — a card easing past under a scroll — has still been clicked.
	press_pos:  [2]f32,

	// Animation state is the one thing that survives between frames, keyed by
	// widget id. Values chase a target so nothing in the UI snaps.
	dt:         f32,
	time:       f32, // seconds since start, for the animated shader effects
	anim:       map[u64]Motion,
	animating:  bool, // set while any value is still chasing its target
	// Rings spreading out from where something was touched, each keyed to
	// the widget that draws it (0 for the window itself). They are the one
	// thing here with a beginning and an end rather than a target: a ripple
	// is a moment, and it is drawn out of when it began and the clock.
	ripples:    [dynamic]Ripple,
	// Set when something on screen is driven by the shader clock, which only
	// advances on a redraw. Kept separate so it can be paced more loosely.
	time_effects: bool,
	// Seconds until the next frame something actually needs. A blinking caret
	// wants two frames a second, not sixty, and an idle window should cost
	// nothing in between.
	wake_in:      f32,
}

// Where a moving thing is, and how fast it is going. ui_anim and ui_tween
// only ever read the position; the velocity is the spring's, and it is kept
// beside the position rather than in a second map so that one id is one
// moving thing wherever it is asked about.
Motion :: struct {
	pos, vel: f32,
}

// Eases `id`'s stored value toward `target`. `speed` is the rate the distance
// left decays at, per second. The exponential is what keeps the motion the
// same shape whether the frame took 4ms or 40: a plain `dt * speed` lerp
// overshoots on a slow frame and crawls on a fast one, which is most of what
// makes a scroll feel wrong.
ui_anim :: proc(ui: ^UI, id: u64, target: f32, speed: f32 = 22) -> f32 {
	current := ui.anim[id].pos
	t := ease_rate(ui.dt, speed)
	next := current + (target - current) * t
	if abs(next - target) < 0.001 do next = target
	else do ui.animating = true
	ui.anim[id] = {next, 0}
	return next
}

// A movement with weight: `id`'s value is pulled toward `target` by a spring
// and, unless it is heavily damped, goes past it and comes back. That
// overshoot is the whole reason it exists beside ui_anim, which only ever
// closes in. Something that lifts under the pointer and settles back a
// touch, a menu that lands a hair too big and relaxes, a card that gets
// bumped and wobbles — an exponential cannot do any of it, because nothing
// in it ever carries speed.
//
// `stiffness` is how hard the pull is and `damping` how fast the swing dies:
// at damping under about 2*sqrt(stiffness) it rings. The step is fixed and
// small so a slow frame cannot blow the integration up — a 100ms frame at a
// stiffness of 400 with one Euler step goes to infinity, not to the target.
//
// An id seen for the first time starts at rest on its target: a card that
// has just been laid out is where it is, not sliding in from zero. Use
// ui_spring_seed to say otherwise before the first tick.
SPRING_STEP :: f32(1.0 / 240)

ui_spring :: proc(ui: ^UI, id: u64, target: f32, stiffness: f32 = 220, damping: f32 = 14) -> f32 {
	m, known := ui.anim[id]
	if !known do m = {target, 0}
	left := ui.dt
	for left > 0 {
		h := min(left, SPRING_STEP)
		left -= h
		m.vel += (stiffness * (target - m.pos) - damping * m.vel) * h
		m.pos += m.vel * h
	}
	if abs(m.pos - target) < 0.0005 && abs(m.vel) < 0.01 {
		m = {target, 0}
	} else {
		ui.animating = true
	}
	ui.anim[id] = m
	return m.pos
}

// Starts `id` somewhere other than where it is going, for the first frame
// only: a thing that appears should be able to pop in rather than be there.
ui_spring_seed :: proc(ui: ^UI, id: u64, at: f32) {
	if id not_in ui.anim do ui.anim[id] = {at, 0}
}

// Shoves a spring. Where it lands is unchanged; how it gets there is not.
ui_spring_kick :: proc(ui: ^UI, id: u64, dv: f32) {
	if m, ok := &ui.anim[id]; ok {
		m.vel += dv
		ui.animating = true
	}
}

// Whether the pointer arrived on something this frame, which is the moment
// a ripple starts from. The answer for last frame is kept beside the widget's
// animation, under its own salt, because there is nowhere else it could be
// read from: hot is worked out afresh every frame and forgotten.
ENTER_SALT :: 0x5eed

ui_entered :: proc(ui: ^UI, id: u64, hovered: bool) -> bool {
	key := id ~ ENTER_SALT
	was := ui.anim[key].pos > 0.5
	ui.anim[key] = {hovered ? 1 : 0, 0}
	return hovered && !was && ui.has_mouse
}

// Whether a value is different from the one handed in here last frame, which
// is the moment a change is worth a knock. Kept the way ui_entered keeps its
// answer — beside the widget's own animation, under a salt — because a frame
// is the only place a "before" can live: everything else on screen is worked
// out afresh and forgotten, and the alternative is a copy of the value parked
// somewhere else that has to be kept in step with the real one.
CHANGE_SALT :: 0xc4a9

ui_changed :: proc(ui: ^UI, id: u64, value: f32) -> bool {
	key := id ~ CHANGE_SALT
	was, known := ui.anim[key]
	ui.anim[key] = {value, 0}
	return known && was.pos != value
}

// A ring that spreads from `at` and fades as it goes. `size` is how far it
// gets; `key` is who draws it, so a card's ripple is clipped to the card and
// the window's click ripple is drawn over everything last.
Ripple :: struct {
	key:  u64,
	at:   [2]f32,
	born: f32,
	col:  Color,
	size: f32,
}

RIPPLE_LIFE :: f32(0.75)

// The ring the pointer leaves on arriving: a pale one, thin enough to be
// felt rather than seen. It was the accent for a day, and a red ring on
// every card the pointer crossed read as a warning on each of them, and
// then it was pale but still a ring — a hard bright arc that announced
// itself on every card the pointer passed over. What is wanted is the card
// catching the light for a moment, so the colour is down to a breath and
// the ring below is drawn thin inside a wide fade.
TOUCH :: Color(0x16e9f0f2)

ui_ripple :: proc(ui: ^UI, key: u64, at: [2]f32, col: Color, size: f32) {
	append(&ui.ripples, Ripple{key, at, ui.time, col, size})
	ui.animating = true
}

// Every live ripple with this key, as it stands right now.
ui_draw_ripples :: proc(ui: ^UI, key: u64) {
	for rp in ui.ripples {
		if rp.key != key do continue
		age := ui.time - rp.born
		if age < 0 || age >= RIPPLE_LIFE do continue
		t := age / RIPPLE_LIFE
		grow := ease_out(t)
		radius := rp.size * (0.08 + 0.92 * grow)
		// Bright and tight at birth, wide and faint by the end: the same
		// curve as a real ring on water, which thins as it spreads. Cubed
		// rather than squared, so most of the life is spent nearly gone
		// instead of holding a visible arc for two thirds of it.
		fade := (1 - t) * (1 - t) * (1 - t)
		// A thin ring inside a fade almost as wide as the circle: the dial
		// shader squares its coverage when soft is set, so what lands is a
		// bloom with no edge to trace rather than a line with a blur on it.
		thick := radius * (0.30 - 0.24 * grow)
		ui_dial(ui, rp.at, radius, max(thick, 1.5), 1, color_alpha(rp.col, fade), 0.95)
		ui.animating = true
	}
}

// The fraction of the remaining distance to cover this frame.
ease_rate :: proc "contextless" (dt, speed: f32) -> f32 {
	return 1 - math.exp(-speed * dt)
}

// A movement with a length, rather than one that only ever gets closer.
// ui_anim covers a fraction of what is left each frame, so the last tenth of
// the way takes as long as the first half did: the card opening into a thread
// grew for a hundred milliseconds and then crept for three hundred more, with
// nothing inside it, because the transcript only goes in once the panel has
// stopped. This arrives, and it arrives when it looks like it has.
//
// It shares ui.anim with ui_anim — one store of where every moving thing is —
// so an id belongs to one or the other and not to both.
ui_tween :: proc(ui: ^UI, id: u64, target: f32, seconds: f32) -> f32 {
	current := ui.anim[id].pos
	step := ui.dt / max(seconds, 0.0001)
	next := target > current ? min(current + step, target) : max(current - step, target)
	if next != target do ui.animating = true
	ui.anim[id] = {next, 0}
	return next
}

// Out fast and a little past the mark, then back: the way something that
// was thrown lands. `over` is how far past, as a fraction.
ease_back :: proc "contextless" (t: f32, over: f32 = 0.6) -> f32 {
	u := t - 1
	return 1 + u * u * ((over + 1) * u + over)
}

// Out of the gate fast and settling into place, which is how something that
// was picked up moves. The old curve was a smoothstep laid over an easing
// that was already slowing down, so the movement was slow at both ends and
// only quick in a moment in the middle nobody could see.
ease_out :: proc "contextless" (t: f32) -> f32 {
	u := 1 - t
	return 1 - u * u * u
}

NO_ROUND :: f32(-1)
NEVER :: f32(1e9)

// Asks for a redraw in `seconds`, if nothing sooner already did.
ui_wake_in :: proc(ui: ^UI, seconds: f32) {
	ui.wake_in = min(ui.wake_in, max(seconds, 0))
}

rect_contains :: proc "contextless" (r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

rect_intersect :: proc "contextless" (a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return Rect{x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

// FNV-1a over the label, so widget identity survives layout changes.
ui_id :: proc "contextless" (label: string, index: int = 0) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(label) {
		h = (h ~ u64(label[i])) * 0x100000001b3
	}
	h = (h ~ u64(index)) * 0x100000001b3
	return h
}

// An id for something addressed by where it lives — a block in the transcript,
// an editor. Hashing the address costs nothing and, unlike formatting it into
// a string, allocates nothing.
ui_id_ptr :: proc "contextless" (p: rawptr, salt: int = 0) -> u64 {
	h: u64 = 0xcbf29ce484222325
	v := u64(uintptr(p))
	for i in 0 ..< 8 {
		h = (h ~ ((v >> uint(i * 8)) & 0xff)) * 0x100000001b3
	}
	return (h ~ u64(salt)) * 0x100000001b3
}

ui_begin :: proc(ui: ^UI, width, height: int, input: ^Input, dt: f32 = 1.0 / 60) {
	ui.dt = clamp(dt, 0, 0.1)
	ui.time += ui.dt
	clear(&ui.verts)
	clear(&ui.indices)
	clear(&ui.cmds)
	clear(&ui.clip_stack)

	ui.size = {f32(width), f32(height)}
	ui.clip = {0, 0, ui.size.x, ui.size.y}
	ui.zoom, ui.zoom_at = 1, {0, 0}

	ui.mouse_moved = ui.has_mouse && input.has_mouse && input.mouse != ui.last_mouse
	ui.last_mouse = input.mouse
	ui.mouse = input.mouse
	ui.has_mouse = input.has_mouse
	ui.down = input.down[0]
	ui.pressed = input.pressed[0]
	if ui.pressed do ui.press_pos = input.mouse
	ui.released = input.released[0]
	ui.click_count = input.click_count
	ui.scroll = input.scroll
	ui.scroll_px = input.scroll_px
	ui.scroll_x = input.scroll_x
	ui.scroll_x_px = input.scroll_x_px
	ui.scroll_end = input.scroll_end
	ui.mods = input.mods
	clear(&ui.hover_text)
	ui.hot = 0
	ui.animating = false
	// Spent ripples go, and one born after the clock — the clock is wound
	// back for a screenshot — goes with them rather than waiting on a
	// moment that has already been.
	for i := 0; i < len(ui.ripples); i += 1 {
		age := ui.time - ui.ripples[i].born
		if age < 0 || age >= RIPPLE_LIFE {
			unordered_remove(&ui.ripples, i)
			i -= 1
		}
	}
	// Every press lands somewhere, and the window says so where it landed.
	if ui.pressed && ui.has_mouse do ui_ripple(ui, 0, ui.mouse, color_alpha(TEXT, 0.22), 36)
	ui.time_effects = false
	ui.wake_in = NEVER
}

ui_end :: proc(ui: ^UI) {
	if !ui.down do ui.active = 0
}

ui_push_clip :: proc(ui: ^UI, r: Rect) {
	append(&ui.clip_stack, ui.clip)
	ui.clip = rect_intersect(ui.clip, r)
}

ui_pop_clip :: proc(ui: ^UI) {
	ui.clip = pop(&ui.clip_stack)
}

// Draws the next thing at a fraction of its size, somewhere else: everything
// emitted until ui_pop_zoom lands at `p * scale + at`, text and rounded
// corners and all.
//
// It is here so that a thread opening out of its card can be laid out once,
// at the size it ends up, and put through the hole the panel is opening. The
// panel used to be an empty box with the thread's name in the corner while
// the real thing waited for it to stop, and drawing the thread at the panel's
// own changing width instead would re-measure every message in it every frame
// of the movement — the measurement is keyed on the width (see
// draw_transcript), and that width is the one thing a zoom does not change.
//
// One level deep: there is one zoom in the program and nesting two would only
// be a way to lose track of which is which.
ui_push_zoom :: proc(ui: ^UI, scale: f32, at: [2]f32) {
	ui.zoom, ui.zoom_at = scale, at
}

ui_pop_zoom :: proc(ui: ^UI) {
	ui.zoom, ui.zoom_at = 1, {0, 0}
}

@(private = "file")
zoom_rect :: proc(ui: ^UI, r: Rect) -> Rect {
	if ui.zoom == 1 do return r
	return {r.x * ui.zoom + ui.zoom_at.x, r.y * ui.zoom + ui.zoom_at.y, r.w * ui.zoom, r.h * ui.zoom}
}

@(private = "file")
current_cmd :: proc(ui: ^UI) -> ^DrawCmd {
	if len(ui.cmds) > 0 {
		last := &ui.cmds[len(ui.cmds) - 1]
		if last.clip == ui.clip && last.punch == ui.punching do return last
		if last.index_count == 0 {
			last.clip = ui.clip
			last.punch = ui.punching
			return last
		}
	}
	append(&ui.cmds, DrawCmd{clip = ui.clip, punch = ui.punching, index_offset = u32(len(ui.indices))})
	return &ui.cmds[len(ui.cmds) - 1]
}

ui_quad :: proc(
	ui: ^UI,
	r: Rect,
	uv0, uv1: [2]f32,
	col: Color,
	tex: u32,
	radius: f32,
	effect: Effect = .None,
	param: f32 = 0,
) {
	if r.w <= 0 || r.h <= 0 do return
	// Placed and sized where it actually lands, before anything is decided
	// about it: the clip is in window pixels and so is the corner radius, and
	// a quad tested against the clip where it was laid out rather than where
	// it is drawn is a quad that disappears while a zoom is on.
	r := zoom_rect(ui, r)
	radius := radius >= 0 ? radius * ui.zoom : radius
	// The distance ramp is in screen pixels and scales with the type: see
	// font_px_range.
	param := effect == .Text ? param * ui.zoom : param
	if rect_intersect(r, ui.clip).w <= 0 do return

	cmd := current_cmd(ui)
	base := u32(len(ui.verts))
	shape := [4]f32{r.x + r.w / 2, r.y + r.h / 2, r.w / 2, r.h / 2}

	append(&ui.verts, Vertex{{r.x, r.y}, uv0, col, tex, shape, radius, effect, param})
	append(&ui.verts, Vertex{{r.x + r.w, r.y}, {uv1.x, uv0.y}, col, tex, shape, radius, effect, param})
	append(&ui.verts, Vertex{{r.x + r.w, r.y + r.h}, uv1, col, tex, shape, radius, effect, param})
	append(&ui.verts, Vertex{{r.x, r.y + r.h}, {uv0.x, uv1.y}, col, tex, shape, radius, effect, param})

	append(&ui.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	cmd.index_count += 6
}

// The general case: four corners, each with its own position, texture
// coordinate and colour. Everything else here is a special case of it.
ui_quad_corners :: proc(
	ui: ^UI,
	p: [4][2]f32,
	uv: [4][2]f32,
	col: [4]Color,
	tex: u32,
	effect: Effect = .None,
) {
	cmd := current_cmd(ui)
	base := u32(len(ui.verts))
	shape := [4]f32{0, 0, 0, 0}

	for i in 0 ..< 4 {
		at := ui.zoom == 1 ? p[i] : p[i] * ui.zoom + ui.zoom_at
		append(&ui.verts, Vertex{at, uv[i], col[i], tex, shape, NO_ROUND, effect, 0})
	}
	append(&ui.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	cmd.index_count += 6
}

ui_rect :: proc(ui: ^UI, r: Rect, col: Color, radius: f32 = NO_ROUND) {
	ui_quad(ui, r, {0, 0}, {1, 1}, col, WHITE_TEX, radius)
}

ui_circle :: proc(ui: ^UI, centre: [2]f32, radius: f32, col: Color) {
	ui_rect(ui, {centre.x - radius, centre.y - radius, radius * 2, radius * 2}, col, radius)
}

// A ring with the first `sweep` of it filled, clockwise from twelve o'clock,
// with both ends rounded. One quad: the shape is cut out of it in the fragment
// shader, so a dial costs the same as a rectangle however round it looks. The
// thickness rides in the texture coordinate because the vertex has no other
// spare field and the white texture is one pixel, so it does not care what uv
// it is sampled at.
// `soft` fades the edge out over that fraction of the radius instead of over
// one pixel, which is how a slice is drawn as the light coming off itself.
ui_dial :: proc(ui: ^UI, centre: [2]f32, radius, thickness, sweep: f32, col: Color, soft: f32 = 0) {
	if radius <= 0 || thickness <= 0 do return
	// The quad used to be the circle's bounding box exactly, which leaves the
	// fade nowhere to go: it ran off the edge of the quad and stopped there,
	// so a ripple — whose fade is nearly as wide as its radius — arrived as a
	// bright disc inside a hard square. The box is grown by the fade instead,
	// and both numbers go over as fractions of the grown half extent, which
	// is what the shader reads them as.
	s := clamp(soft, 0, 1)
	half := radius * (1 + s)
	t := clamp(thickness / half, 0, 1)
	fade := s / (1 + s)
	ui_quad(
		ui,
		{centre.x - half, centre.y - half, half * 2, half * 2},
		{t, fade},
		{t, fade},
		col,
		WHITE_TEX,
		NO_ROUND,
		.Dial,
		clamp(sweep, 0, 1),
	)
}

ui_image :: proc(ui: ^UI, r: Rect, tex: u32, radius: f32 = NO_ROUND, tint: Color = 0xffffffff) {
	ui_quad(ui, r, {0, 0}, {1, 1}, tint, tex, radius)
}

// A picture filling `r` at its own proportions, cropped evenly at both ends of
// whichever side is too long, rather than squashed to fit. A screenshot is
// three times as wide as the square a thumbnail gets, and squeezed into that
// square there is nothing left in it anybody could recognise.
ui_image_cover :: proc(ui: ^UI, r: Rect, tex: u32, width, height: int, radius: f32 = NO_ROUND) {
	if width <= 0 || height <= 0 || r.w <= 0 || r.h <= 0 {
		ui_image(ui, r, tex, radius)
		return
	}
	want := r.w / r.h
	have := f32(width) / f32(height)
	// Half the span kept, per axis: the whole of the short side, and as much
	// of the long one as the box is shaped for.
	u, v := f32(0.5), f32(0.5)
	if have > want {
		u = want / have * 0.5
	} else {
		v = have / want * 0.5
	}
	ui_quad(ui, r, {0.5 - u, 0.5 - v}, {0.5 + u, 0.5 + v}, 0xffffffff, tex, radius)
}

ui_text :: proc(
	ui: ^UI,
	font: ^Font,
	text: string,
	pos: [2]f32,
	size: f32,
	col: Color,
) -> f32 {
	scale := font_scale(font, size)
	pen := pos
	// `pos` is the top-left of the line box, and the baseline hangs off
	// `font.baseline` rather than off `font.ascent`: the metric ascender is a
	// third of an em above anything Latin text actually draws, so hanging the
	// line off it left all the slack above the ink and none below and every
	// string sat low in whatever box it had been given — about two pixels at
	// reading sizes, which is exactly enough to see. font_baseline works out
	// where the ink is and has done since it was written; this line was still
	// reading the metric, so the dot centred beside a word in a card's badge
	// sat two pixels above the word it belonged to.
	pen.y += font.baseline * scale

	// One number the shader needs and cannot work out for itself: how many
	// screen pixels the distance ramp covers at this size.
	px_range := font_px_range(size)

	for ch in text {
		g := font_glyph(font, ch)

		// Plane bounds are em from the baseline with y up; the screen has y
		// down, so the top edge is the ascent subtracted from the pen.
		left := pen.x + g.plane[0] * scale
		right := pen.x + g.plane[2] * scale
		top := pen.y - g.plane[3] * scale
		bottom := pen.y - g.plane[1] * scale
		if right > left && bottom > top {
			// Atlas bounds are pixels with y up from the bottom of the sheet,
			// and the decoded image has its first row at the top.
			uv0 := [2]f32{g.atlas[0] / g_atlas.width, 1 - g.atlas[3] / g_atlas.height}
			uv1 := [2]f32{g.atlas[2] / g_atlas.width, 1 - g.atlas[1] / g_atlas.height}
			ui_quad(
				ui,
				{left, top, right - left, bottom - top},
				uv0,
				uv1,
				col,
				font.tex,
				NO_ROUND,
				.Text,
				px_range,
			)
		}
		pen.x += g.advance * scale
	}
	return pen.x - pos.x
}

// Text at a given x, sitting in the middle of a rect's height. The line box
// is what ui_text is positioned by, so this is the same sum ui_text_centred
// does — without giving up the horizontal placing.
ui_text_middle :: proc(ui: ^UI, font: ^Font, text: string, x: f32, r: Rect, size: f32, col: Color) {
	line := (font.ascent - font.descent) * font_scale(font, size)
	ui_text(ui, font, text, {x, r.y + (r.h - line) / 2}, size, col)
}

ui_text_centred :: proc(ui: ^UI, font: ^Font, text: string, r: Rect, size: f32, col: Color) {
	w := font_width(font, text, size)
	line := font.ascent - font.descent
	y := r.y + (r.h - line * font_scale(font, size)) / 2
	ui_text(ui, font, text, {r.x + (r.w - w) / 2, y}, size, col)
}

// Cuts a hole through everything already drawn: the rect is not blended with
// what is under it, it replaces it. A colour with a low alpha therefore leaves
// the window see-through there, so what shows is the desktop behind the
// window rather than the interface behind the rect.
ui_punch :: proc(ui: ^UI, r: Rect, col: Color, radius: f32 = NO_ROUND) {
	ui.punching = true
	ui_quad(ui, r, {0, 0}, {1, 1}, col, WHITE_TEX, radius, .Punch)
	ui.punching = false
}

// Returns whether the pointer is inside `r`, honouring the current clip.
// Says what is drawn in `r`, if the pointer is in it. Unlike ui_hovered this
// does not care whether something is being dragged: reading is not clicking.
ui_hover_text :: proc(ui: ^UI, r: Rect, text: string) {
	if text == "" || !ui.has_mouse do return
	if !rect_contains(rect_intersect(r, ui.clip), ui.mouse) do return
	clear(&ui.hover_text)
	append(&ui.hover_text, ..transmute([]byte)text)
}

// What the last frame found under the pointer. Read before the next frame
// clears it, which is where input is handled.
ui_hovered_text :: proc(ui: ^UI) -> string {
	return string(ui.hover_text[:])
}

ui_hovered :: proc(ui: ^UI, r: Rect) -> bool {
	if !ui.has_mouse do return false
	if ui.active != 0 do return false
	return rect_contains(rect_intersect(r, ui.clip), ui.mouse)
}

// How far the pointer may have travelled since the press and still count as a
// click on the thing that was pressed rather than a drag off it.
CLICK_SLOP :: f32(4)

// A popup takes the press inside it back from whatever it is covering.
//
// Everything here is drawn in the order it is stacked, and a press is claimed
// by the first widget that is under it — ui_invisible_button will not hover
// anything at all while another widget is held, which is what stops a drag
// off a button from lighting up everything it crosses. A popup is drawn last
// and so asks last, by which time the transcript tile or the card underneath
// it has already taken the press: every row of the model picker was dead, and
// clicking a model opened whatever the picker happened to be covering.
ui_claim :: proc(ui: ^UI, r: Rect) {
	if ui.pressed && rect_contains(rect_intersect(r, ui.clip), ui.mouse) do ui.active = 0
}

// The whole button protocol: hot on hover, active while held, fires on release
// inside. No retained state beyond the two ids on UI.
//
// "Inside" is the release position against the rect this frame, which is not
// enough on its own: the rects here are recomputed every frame, so a card
// sliding under an easing scroll takes its buttons out from under a pointer
// that never moved, and the click is dropped with nothing to show for it. A
// press the pointer has not walked away from is therefore a click wherever the
// widget has got to. Moving off it still cancels, which is what a drag off a
// button is for.
ui_invisible_button :: proc(ui: ^UI, id: u64, r: Rect) -> (clicked: bool, hovered: bool) {
	hovered = ui_hovered(ui, r) || ui.active == id
	if hovered do ui.hot = id

	if ui.pressed && ui_hovered(ui, r) do ui.active = id
	if ui.released && ui.active == id {
		d := ui.mouse - ui.press_pos
		still := abs(d.x) <= CLICK_SLOP && abs(d.y) <= CLICK_SLOP
		if still || rect_contains(rect_intersect(r, ui.clip), ui.mouse) do clicked = true
		ui.active = 0
	}
	return
}

Scroll :: struct {
	offset:      f32, // eased toward target
	target:      f32,
	content:     f32,
	view_height: f32,
	// A touchpad flick keeps going after the fingers lift: the speed they
	// left at, in pixels a second, dying out under friction.
	vel:         f32,
	gliding:     bool,
}

SCROLL_FRICTION :: f32(5.5) // how fast a flick runs out, per second
SCROLL_STOP :: f32(20) // below this it has stopped, in pixels a second

// Scrolls with the wheel and clamps to content. Draw items at
// `r.y - scroll.offset + i * row_height`, clipped to `r`.
ui_begin_scroll :: proc(ui: ^UI, r: Rect, s: ^Scroll, content_height: f32) {
	s.content = content_height
	s.view_height = r.h
	limit := max(content_height - r.h, 0)
	hovered := ui_hovered(ui, r)

	// A press puts a stop to a glide, the way a finger on a spinning record
	// does.
	if ui.pressed && hovered do s.vel, s.gliding = 0, false

	if hovered && ui.scroll != 0 {
		// One wheel notch arrives as ~10 units; this lands it near three rows.
		s.target -= ui.scroll * 28
		s.vel, s.gliding = 0, false
	}
	if hovered && ui.scroll_px != 0 {
		// A touchpad already speaks pixels, and pixels belong under the
		// fingers: no easing, no lag, and the speed is remembered for the
		// glide that may follow.
		s.target -= ui.scroll_px
		s.target = clamp(s.target, 0, limit)
		s.offset = s.target
		inst := -ui.scroll_px / max(ui.dt, 1.0 / 240)
		s.vel = s.vel * 0.7 + inst * 0.3
		s.gliding = false
	} else if hovered && ui.scroll_end {
		s.gliding = abs(s.vel) > SCROLL_STOP
	} else if s.gliding {
		s.vel *= math.exp(-SCROLL_FRICTION * ui.dt)
		s.target = clamp(s.target + s.vel * ui.dt, 0, limit)
		s.offset = s.target
		// Spent, or run into an end.
		if abs(s.vel) < SCROLL_STOP || s.target <= 0 || s.target >= limit {
			s.vel, s.gliding = 0, false
		} else {
			ui.animating = true
		}
	}
	s.target = clamp(s.target, 0, limit)

	// Chase the target so the wheel glides instead of jumping.
	s.offset += (s.target - s.offset) * ease_rate(ui.dt, 26)
	if abs(s.target - s.offset) < 0.35 do s.offset = s.target
	else do ui.animating = true

	ui_push_clip(ui, r)
}

ui_end_scroll :: proc(ui: ^UI, r: Rect, s: ^Scroll) {
	ui_pop_clip(ui)
}

ui_destroy :: proc(ui: ^UI) {
	delete(ui.anim)
	delete(ui.ripples)
	delete(ui.verts)
	delete(ui.indices)
	delete(ui.cmds)
	delete(ui.clip_stack)
	delete(ui.hover_text)
}
