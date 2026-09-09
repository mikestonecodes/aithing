package aithing

import "core:strings"
import "core:testing"

// Walking the grid from the keyboard, pinned. h and l go one card along in
// reading order and j and k go a whole row, and the row they land on is
// worked out from the cards themselves rather than from a column count kept
// beside them — a count would be a second copy of something the layout
// already decided, and it would be wrong on the short last row of a section.

@(private = "file")
GRID_VIEW :: Rect{0, 0, 1180, 800} // three columns wide

// The id of the nth card in the order the grid reads, headers skipped.
@(private = "file")
grid_id :: proc(app: ^App, n: int) -> string {
	canvas_layout(app)
	at := 0
	for card in app.canvas.cards {
		if card.head do continue
		if at == n do return app.todos.list[card.todo].id
		at += 1
	}
	return ""
}

@(private = "file")
seven_cards :: proc() -> ^App {
	app := new(App)
	app.cwd = strings.clone("")
	for i in 0 ..< 7 {
		todos_add(&app.todos, "a card", "", "/tmp/proj")
	}
	app.canvas.view = GRID_VIEW
	return app
}

@(private = "file")
drop_app :: proc(app: ^App) {
	for id in app.pending_dismiss do delete(id)
	todos_destroy(&app.todos)
	delete(app.todo_view)
	delete(app.visible)
	editor_destroy(&app.search)
	editor_destroy(&app.capture)
	canvas_destroy(&app.canvas)
	delete(app.cwd)
	free(app)
}

@(test)
hjkl_walks_the_grid :: proc(t: ^testing.T) {
	app := seven_cards()
	defer drop_app(app)

	canvas_set_sel(app, grid_id(app, 0))

	// l and h: one card along, in the order the grid is read.
	canvas_step_sel(app, 1)
	testing.expect_value(t, app.canvas.sel, grid_id(app, 1))
	canvas_step_sel(app, -1)
	testing.expect_value(t, app.canvas.sel, grid_id(app, 0))

	// j: a whole row, staying in the column it started in.
	canvas_step_sel(app, 1)
	canvas_step_row(app, 1)
	testing.expect_value(t, app.canvas.sel, grid_id(app, 4))

	// The last row is one card wide, so j takes the card nearest across
	// rather than refusing to move. Seven cards over three columns is what
	// makes it short, and a short row that could not be entered is why the
	// old nearest-in-direction walk was thrown away.
	canvas_step_row(app, 1)
	testing.expect_value(t, app.canvas.sel, grid_id(app, 6))

	// And back up into the column it came from.
	canvas_step_row(app, -1)
	testing.expect_value(t, app.canvas.sel, grid_id(app, 3))

	// The top row has nothing above it and the bottom nothing below.
	canvas_step_row(app, -1)
	testing.expect_value(t, app.canvas.sel, grid_id(app, 0))
	canvas_step_row(app, -1)
	testing.expect_value(t, app.canvas.sel, grid_id(app, 0))
}

@(test)
x_takes_the_card_and_the_cursor_stays_put :: proc(t: ^testing.T) {
	app := seven_cards()
	defer drop_app(app)

	third := strings.clone(grid_id(app, 2), context.temp_allocator)
	fourth := strings.clone(grid_id(app, 3), context.temp_allocator)
	canvas_set_sel(app, third)
	canvas_dismiss_sel(app)

	testing.expect_value(t, len(app.pending_dismiss), 1)
	testing.expect_value(t, app.pending_dismiss[0], third)
	// The cursor lands on the card that takes its place. It used to be left
	// on the id that had just gone, and the next h or l started over at the
	// first card of the grid.
	testing.expect_value(t, app.canvas.sel, fourth)
}

// Esc takes the keyboard out of the box and onto the cards, i puts it back,
// and the list that was half written survives the trip. The rule used to be
// whether the box was empty, so a list starting with an h could not be typed
// at all and one already written could not be left alone.
@(test)
esc_goes_to_the_cards_and_i_comes_back :: proc(t: ^testing.T) {
	app := seven_cards()
	defer drop_app(app)

	// A grid narrowed to one project is a grid with a box under it.
	app.canvas.project = strings.clone("/tmp/proj")
	canvas_set_sel(app, grid_id(app, 0))

	// The caret starts in the box, so every letter is text — h and l
	// included.
	testing.expect_value(t, app_focus(app), Focus.Capture)
	testing.expect(t, !grid_command(app, 'l'), "in the box, l is text")
	testing.expect_value(t, app.canvas.sel, grid_id(app, 0))

	// Esc over a half-written list: the caret comes out, the words stay.
	editor_set_text(&app.capture, "hello")
	app_cancel(app)
	testing.expect_value(t, app_focus(app), Focus.None)
	testing.expect_value(t, editor_text(&app.capture), "hello")

	testing.expect(t, grid_command(app, 'l'), "on the cards, l walks them")
	testing.expect_value(t, app.canvas.sel, grid_id(app, 1))
	testing.expect(t, !grid_command(app, 'q'), "q is not a command")

	// i puts the caret back, and the list is where it was left.
	testing.expect(t, grid_command(app, 'i'), "i goes back to the box")
	testing.expect_value(t, app_focus(app), Focus.Capture)
	testing.expect_value(t, editor_text(&app.capture), "hello")
	testing.expect(t, !grid_command(app, 'l'), "back in the box, l is text again")

	// The second Esc is the one that throws the list away.
	app_cancel(app)
	testing.expect_value(t, editor_text(&app.capture), "hello")
	app_cancel(app)
	testing.expect_value(t, editor_text(&app.capture), "")
}

// A grid of every project has no box, so it has nothing to take the letters:
// they are the cards' whatever the mode says, because app_focus answers .None
// before it ever looks.
@(test)
with_no_box_the_letters_are_always_the_cards :: proc(t: ^testing.T) {
	app := seven_cards()
	defer drop_app(app)

	canvas_set_sel(app, grid_id(app, 0))
	app.on_cards = false
	testing.expect(t, grid_command(app, 'l'), "no box, so l walks the grid")
	testing.expect_value(t, app.canvas.sel, grid_id(app, 1))
}
