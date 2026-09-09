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
