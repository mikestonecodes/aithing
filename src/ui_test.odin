package aithing

import "core:testing"

// The picker is drawn over the transcript and over the grid, and both of
// those are made of buttons. A press is claimed by the first widget under it,
// so the popup — drawn last, asking last — was picking up nothing at all.
@(test)
a_popup_takes_the_press_from_what_it_covers :: proc(t: ^testing.T) {
	ui: UI
	defer ui_destroy(&ui)
	input: Input
	input.has_mouse = true

	tile := Rect{100, 100, 400, 300}
	row := Rect{150, 150, 200, 34}

	// The press: the tile underneath asks first and takes it, then the row
	// on top asks for it back.
	input.mouse = {200, 160}
	input.pressed[0] = true
	input.down[0] = true
	ui_begin(&ui, 800, 600, &input, 1.0 / 60)
	_, _ = ui_invisible_button(&ui, ui_id("tile"), tile)
	ui_claim(&ui, row)
	_, _ = ui_invisible_button(&ui, ui_id("row"), row)
	ui_end(&ui)
	testing.expect_value(t, ui.active, ui_id("row"))

	// The release, in the same place: the row fires and the tile does not.
	input.pressed[0] = false
	input.released[0] = true
	input.down[0] = false
	ui_begin(&ui, 800, 600, &input, 1.0 / 60)
	tile_clicked, _ := ui_invisible_button(&ui, ui_id("tile"), tile)
	ui_claim(&ui, row)
	row_clicked, _ := ui_invisible_button(&ui, ui_id("row"), row)
	ui_end(&ui)
	testing.expect(t, row_clicked, "the row the pointer was on did not fire")
	testing.expect(t, !tile_clicked, "the tile under the popup fired instead")
}

// A wheel notch used to be 280 pixels wherever it was turned. Over a stone's
// peek, which is 470 pixels at its tallest, one click threw most of the panel
// past the top: "scrolling in popup feels too fast". A notch is now a fifth
// of what it is turned over, so the panel steps and the full-height list is
// where it was.
@(test)
a_notch_steps_a_short_panel :: proc(t: ^testing.T) {
	ui: UI
	defer ui_destroy(&ui)
	input: Input
	input.has_mouse = true
	input.mouse = {200, 200}

	panel := Rect{100, 100, 300, 400}
	tall := Rect{100, 100, 300, 1400}

	// One notch of the wheel arrives as ten units.
	small, big: Scroll
	input.scroll = -10
	ui_begin(&ui, 1600, 1500, &input, 1.0 / 60)
	ui_begin_scroll(&ui, panel, &small, 8000)
	ui_end_scroll(&ui, panel, &small)
	ui_begin_scroll(&ui, tall, &big, 8000)
	ui_end_scroll(&ui, tall, &big)
	ui_end(&ui)

	testing.expect_value(t, small.target, panel.h / 5)
	testing.expect_value(t, big.target, 280)
}
