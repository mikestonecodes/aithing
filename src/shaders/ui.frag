#version 450
#extension GL_EXT_nonuniform_qualifier : require

// The bindless table: every texture the UI can ever draw lives here, so the
// whole frame is one descriptor set bound once and (usually) one draw call.
// Slot 0 is the font atlas, slot 1 is a 1x1 white pixel, the rest is art.
layout(set = 0, binding = 0) uniform sampler2D textures[];

layout(push_constant) uniform Push {
	vec2  inv_screen;
	float time;
} pc;

layout(location = 0)      in vec2  v_uv;
layout(location = 1)      in vec4  v_col;
layout(location = 2) flat in uint  v_tex;
layout(location = 3)      in vec2  v_pos;
layout(location = 4) flat in vec4  v_rect;
layout(location = 5) flat in float v_radius;
layout(location = 6) flat in uint  v_effect;
layout(location = 7) flat in float v_param;

layout(location = 0) out vec4 out_col;

#define EFFECT_NONE     0u
#define EFFECT_GLOW     1u // soft radial falloff, for the halo behind a button
#define EFFECT_SHEEN    2u // a highlight that travels along the progress fill
#define EFFECT_RING     3u // a ring that fades outward, for click ripples
#define EFFECT_TEXT     4u // a glyph: the texture is a distance field
#define EFFECT_PUNCH    5u // replaces what is under it, alpha and all
#define EFFECT_POP      6u // a transcript tile: inner light and a hover rim
#define EFFECT_WIRE     7u // the thread between tiles, with a pulse on it
#define EFFECT_DIAL     8u // a ring with a slice of it filled: see ui_dial

// The distance a multi-channel field encodes is the median of its three
// channels — the channels disagree exactly at a corner, and taking the middle
// one is what keeps the corner sharp instead of rounding it off.
float median3(vec3 v) {
	return max(min(v.r, v.g), min(max(v.r, v.g), v.b));
}

// Signed distance to a box with rounded corners, in pixels.
float rounded_box(vec2 p, vec2 half_extent, float r) {
	vec2 q = abs(p) - half_extent + r;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
	vec4 texel = texture(textures[nonuniformEXT(v_tex)], v_uv);
	vec4 c;

	if (v_effect == EFFECT_TEXT) {
		// A glyph carries no colour of its own: the field says how far this
		// pixel is from the outline, and v_param says how many pixels the
		// field's ramp spans, which together give a coverage the edge stays
		// sharp through at any size.
		float sd = median3(texel.rgb);
		c = vec4(v_col.rgb, v_col.a * clamp(v_param * (sd - 0.5) + 0.5, 0.0, 1.0));
	} else {
		c = v_col * texel;
	}

	// Position within the quad, -1..1 on each axis.
	vec2 p = (v_pos - v_rect.xy) / max(v_rect.zw, vec2(0.0001));

	if (v_effect == EFFECT_GLOW) {
		// Quadratic falloff reads as light rather than as a blurred circle.
		// Deliberately not time-varying: a static glow costs nothing to leave
		// on screen, because the frame does not need redrawing to hold it.
		float d = length(p);
		c.a *= pow(clamp(1.0 - d, 0.0, 1.0), 2.5);
	} else if (v_effect == EFFECT_SHEEN) {
		// A band that sweeps left to right across the filled part.
		float x = p.x * 0.5 + 0.5;
		float head = fract(pc.time * 0.30) * 1.7 - 0.35;
		float band = exp(-pow((x - head) * 5.0, 2.0));
		c.rgb += band * 0.45;
	} else if (v_effect == EFFECT_POP) {
		// A tile is a lit surface, not a flat swatch: brighter towards the
		// top-left corner the light comes from, and its rim brightens as the
		// pointer takes it. v_param is how far it has been taken, 0..1, so a
		// resting transcript is still and only what is under the pointer
		// moves — the whole grid shimmering at once read as noise, and cost a
		// redraw every frame to say nothing.
		float lit = clamp(1.0 - length(p - vec2(-0.6, -0.9)) * 0.55, 0.0, 1.0);
		c.rgb += lit * lit * (0.055 + 0.16 * v_param);
		float edge = max(abs(p.x), abs(p.y));
		c.rgb += smoothstep(0.82, 1.0, edge) * (0.05 + 0.5 * v_param);
		if (v_param > 0.01) {
			// The sheen only exists while the tile is up, and it crosses the
			// long way, so a wide tile is swept and a small one blinks.
			float head = fract(pc.time * 0.55) * 2.4 - 0.7;
			c.rgb += exp(-pow((p.x - head) * 3.0, 2.0)) * 0.28 * v_param;
		}
	} else if (v_effect == EFFECT_WIRE) {
		// The thread the tiles hang off. A pulse runs along it in the
		// direction the row is read — v_param says where in the run this
		// segment sits, and its sign says which way that run is read, so the
		// light travels the way the eye does rather than always rightwards
		// down a snake that turns back on itself.
		//
		// The two used to be packed into one positive number, 10 added to it
		// meaning right to left. The eleventh segment of any path is 10, so
		// from the eleventh stone on every forward run and every drop between
		// rows animated backwards — which is most of a real turn.
		bool back = v_param < 0.0;
		float phase = abs(v_param) - 1.0;
		// Whichever way the segment is long is the way the pulse travels.
		float along = v_rect.z >= v_rect.w ? p.x : p.y;
		if (back) along = -along;
		float u = along * 0.5 + 0.5;
		float head = fract(pc.time * 0.22 - phase * 0.08);
		float d = abs(fract(u - head + 0.5) - 0.5);
		c.a *= 0.5 + 1.6 * exp(-pow(d * 9.0, 2.0));
	} else if (v_effect == EFFECT_DIAL) {
		// One allowance, as the slice of a ring that is gone. The quad is the
		// circle's bounding box, so p is already the unit disc; v_uv.x is how
		// thick the ring is as a fraction of its radius and v_param is how far
		// round it goes, 0..1 clockwise from twelve o'clock.
		//
		// It is one quad rather than a fan of triangles because a fan wide
		// enough to look round at 116 pixels is forty vertices per ring and
		// three rings a frame, and because the cap at each end wants to be a
		// half-circle, which a fan gives you as a flat chord.
		float ht = v_uv.x * 0.5;   // half the ring's thickness
		float rm = 1.0 - ht;       // the radius the ring is centred on
		float turn = atan(p.x, -p.y) / 6.28318531;
		if (turn < 0.0) turn += 1.0;
		float d;
		if (turn <= v_param || v_param >= 1.0) {
			d = abs(length(p) - rm) - ht;
		} else {
			// Past the end of the slice the shape is whichever cap is nearer,
			// which rounds both ends for free and keeps a slice of nothing
			// from vanishing: at 0% the two caps sit on each other and leave
			// a bead at twelve o'clock, which is what "none of it yet" looks
			// like on a dial.
			float th = v_param * 6.28318531;
			d = min(length(p - vec2(0.0, -rm)), length(p - vec2(sin(th), -cos(th)) * rm)) - ht;
		}
		// The quad is square, so either half extent is the pixel size. v_uv.y
		// widens the edge from that one pixel out to a fade, which is the
		// difference between an arc and the light coming off one: the halo is
		// the same slice drawn fatter, and drawn hard it read as a second arc
		// with a dark seam down the middle of it.
		float px = 1.0 / max(v_rect.z, 1.0);
		float edge = max(v_uv.y, px);
		float cover = 1.0 - smoothstep(-edge, edge, d);
		c.a *= v_uv.y > 0.0 ? cover * cover : cover;
	} else if (v_effect == EFFECT_RING) {
		// Thin annulus at the quad's edge, fading as it expands.
		float d = length(p);
		float ring = smoothstep(0.55, 1.0, d) * (1.0 - smoothstep(1.0, 1.06, d));
		c.a *= ring;
	}

	if (v_radius >= 0.0) {
		float d = rounded_box(v_pos - v_rect.xy, v_rect.zw, v_radius);
		c.a *= 1.0 - smoothstep(-0.7, 0.7, d);
	}

	if (v_effect == EFFECT_PUNCH) {
		// Drawn with replacing blend, so what lands here is what the window
		// holds: a low alpha means the desktop shows through, whatever the
		// interface had already drawn underneath. There is no blending to
		// feather the edge with, so the shape is cut hard and the border
		// drawn over it covers the step.
		if (c.a < v_col.a * 0.5) discard;
		out_col = vec4(v_col.rgb * v_col.a, v_col.a);
		return;
	}

	if (c.a <= 0.0) discard;
	out_col = c;
}
