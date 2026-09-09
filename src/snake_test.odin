package aithing

import "core:testing"

// The pulse runs along the pipe the way the row is read, and a quad carries
// one float to say it with. Two answers went into that one number — where in
// the run the segment sits, and which way the run goes, the second as 10
// added to the first — and the eleventh segment of any path is 10. So from
// the eleventh stone on, every forward run and every drop between rows ran
// its light backwards, which is most of any turn worth looking at.
//
// This decodes it exactly the way ui.frag does. The two have to agree, and
// the whole bug was that they agreed on a number that meant two things.
@(test)
the_pulse_runs_the_way_the_row_is_read :: proc(t: ^testing.T) {
	for at in 0 ..< 400 {
		for back in ([]bool{false, true}) {
			p := wire_param(at, back)
			// ui.frag: bool back = v_param < 0.0; float phase = abs(p) - 1.0;
			got_back := p < 0
			got_at := int(abs(p) - 1)
			testing.expectf(
				t,
				got_back == back,
				"segment %d reads as %v when it is %v",
				at,
				got_back ? "right to left" : "left to right",
				back ? "right to left" : "left to right",
			)
			testing.expect_value(t, got_at, at)
		}
	}
}
