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

// The letters are the grid's only while the box under it is empty. That is
// the same thing the arrows already ask, and it is what `/` has always done.
@(test)
the_box_takes_the_letters_back :: proc(t: ^testing.T) {
	app := seven_cards()
	defer drop_app(app)

	app.page = .Grid
	app.overlay = .None
	canvas_set_sel(app, grid_id(app, 0))

	testing.expect(t, grid_command(app, 'l'), "l walks the grid over an empty box")
	testing.expect_value(t, app.canvas.sel, grid_id(app, 1))
	testing.expect(t, !grid_command(app, 'q'), "q is not a command, so it is text")

	editor_set_text(&app.capture, "hello")
	testing.expect(t, !grid_command(app, 'l'), "with something written, l is text")
	testing.expect_value(t, app.canvas.sel, grid_id(app, 1))
}
