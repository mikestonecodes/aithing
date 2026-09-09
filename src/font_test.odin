package aithing

import "core:testing"

// Where the ink lands inside the box the layout gave it.
//
// Every vertical placing in the program is a line box: `ui_text_middle`
// centres one in a pill, the composer stacks them a line height apart, and the
// caret is drawn exactly one of them tall. So a string that does not sit in
// the middle of its own box is a string that sits wrong everywhere at once —
// which is what the badge on a card showed, the dot beside a word centred to
// the pixel and the word itself two pixels below it.
//
// The cause was that `ui_text` hung the baseline off `font.ascent`. Noto Sans'
// ascender is 1.069em, a third of an em above anything Latin text draws, so
// all the slack ended up above the letters and none below. `font_baseline`
// works the real thing out from the ink and has done since it was written;
// nothing was reading it.
@(test)
type_sits_in_the_middle_of_its_line_box :: proc(t: ^testing.T) {
	g_atlas = Atlas{width = 1, height = 1, distance_range = 4, em_px = 48}

	// A font of one letter: ink from the baseline up to 0.7em, the way a
	// capital sits, under a metric ascender a long way above it.
	INK :: f32(0.7)
	f: Font
	f.ascent, f.descent = 1.069, -0.293
	// Where font_baseline puts it: the ink centred in the box rather than
	// hung off the ascender.
	f.baseline = ((f.ascent - f.descent) + INK) / 2
	f.dense[int('H' - DENSE_FIRST)] = Glyph {
		code    = u32('H'),
		advance = 0.6,
		plane   = {0, 0, 0.6, INK},
		atlas   = {0, 0, 1, 1},
	}

	ui: UI
	defer ui_destroy(&ui)
	input: Input
	ui_begin(&ui, 800, 600, &input, 1.0 / 60)

	SIZE :: f32(20)
	TOP :: f32(100)
	ui_text(&ui, &f, "H", {0, TOP}, SIZE, TEXT)

	testing.expect_value(t, len(ui.verts), 4)
	ink_top := ui.verts[0].pos.y
	ink_bottom := ui.verts[2].pos.y
	box_bottom := TOP + (f.ascent - f.descent) * SIZE

	above := ink_top - TOP
	below := box_bottom - ink_bottom
	testing.expectf(
		t,
		abs(above - below) < 0.01,
		"the air above the ink is %v and below it is %v",
		above,
		below,
	)
}
