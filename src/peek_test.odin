package aithing

import "core:strings"
import "core:testing"

// A stone's panel is built out of rows, and which rows depends on what the
// tool is. These are about the shape that comes out — the panel is drawn from
// this list and nothing else, so a list with the right rows in it is a panel
// with the right things on it.

@(private = "file")
tool_block :: proc(name, input, result: string) -> Block {
	b := Block {
		kind   = .Tool,
		name   = strings.clone(name),
		input  = strings.builder_make(),
		result = strings.builder_make(),
	}
	strings.write_string(&b.input, input)
	strings.write_string(&b.result, result)
	return b
}

@(private = "file")
rows_of :: proc(app: ^App, b: ^Block) -> []Row {
	return peek_rows(app, b, 400)
}

@(private = "file")
count :: proc(rows: []Row, kind: Row_Kind) -> int {
	n := 0
	for r in rows do if r.kind == kind do n += 1
	return n
}

@(private = "file")
has_row :: proc(rows: []Row, kind: Row_Kind, text: string) -> bool {
	for r in rows do if r.kind == kind && strings.trim_space(r.text) == text do return true
	return false
}

// The whole point of the exercise: an edit opens as the lines it takes out and
// the lines it puts in, not as a line of JSON with the two strings escaped
// into it.
@(test)
an_edit_opens_as_a_diff :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.rows)

	b := tool_block(
		"Edit",
		`{"file_path": "src/canvas.odin", "old_string": "one\ntwo\nthree\nfour\nfive\nsix\nseven\n", "new_string": "one\ntwo\nthree\nfour\nFIVE\nsix\nseven\n"}`,
		"The file src/canvas.odin has been updated.",
	)
	defer block_destroy(&b)

	rows := rows_of(app, &b)
	testing.expect_value(t, count(rows, .Del), 1)
	testing.expect_value(t, count(rows, .Add), 1)
	testing.expect(t, has_row(rows, .Del, "five"), "the line it took out is not on the panel")
	testing.expect(t, has_row(rows, .Add, "FIVE"), "the line it put in is not on the panel")
	// Two lines either side for bearings, and the rest of the matching run is
	// a count. A panel that printed the whole of both strings would be two
	// copies of the file with one line different.
	testing.expect_value(t, count(rows, .Same), 4)
	testing.expect_value(t, count(rows, .Skip), 1)
}

// A new file is all one side of the same diff.
@(test)
a_write_is_all_additions :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.rows)

	b := tool_block("Write", `{"file_path": "a.odin", "content": "package a\n\nmain :: proc() {}\n"}`, "Wrote 3 lines")
	defer block_destroy(&b)

	rows := rows_of(app, &b)
	testing.expect_value(t, count(rows, .Del), 0)
	testing.expect_value(t, count(rows, .Add), 3)
}

// The command, as a command; the plan, as boxes with a state each.
@(test)
a_tool_opens_in_its_own_shape :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.rows)

	bash := tool_block("Bash", `{"command": "odin test src", "description": "the suite"}`, "ok\ndone")
	defer block_destroy(&bash)
	rows := rows_of(app, &bash)
	testing.expect(t, has_row(rows, .Cmd, "odin test src"), "the command is not on the panel")
	testing.expect_value(t, count(rows, .Mono), 2)

	todo := tool_block(
		"TodoWrite",
		`{"todos": [{"content": "one", "status": "completed"}, {"content": "two", "status": "in_progress"}, {"content": "three", "status": "pending"}]}`,
		"",
	)
	defer block_destroy(&todo)
	rows = rows_of(app, &todo)
	testing.expect_value(t, count(rows, .Check), 3)
	for r in rows do if r.kind == .Check {
		want := r.text == "one" ? 2 : r.text == "two" ? 1 : 0
		testing.expect_value(t, r.num, want)
	}

	// A file read back: the harness numbers the lines, and the numbers go in
	// a column of their own rather than being left in the text where they
	// would move the code along by however wide they happened to be.
	read := tool_block("Read", `{"file_path": "a.odin"}`, "     1→package a\n     2→\n     3→main :: proc() {}")
	defer block_destroy(&read)
	rows = rows_of(app, &read)
	testing.expect(t, has_row(rows, .Mono, "package a"), "the first line is not on the panel")
	for r in rows do if r.kind == .Mono && strings.trim_space(r.text) == "main :: proc() {}" {
		testing.expect_value(t, r.num, 3)
	}
}

// A grep prints the line number ahead of the line, the same as a file read
// back does. Both put the number in the panel's own column: the number is not
// part of what was found, and left in the text it is twelve characters of the
// same digits down the left of every line.
@(test)
numbered_output_puts_the_numbers_in_the_column :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.rows)

	b := tool_block("Bash", `{"command": "grep -n PEEK_ src/peek.odin"}`, "30:PEEK_W :: f32(560)\n43:PEEK_SIGN :: f32(16)")
	defer block_destroy(&b)
	rows := rows_of(app, &b)
	testing.expect(t, has_row(rows, .Mono, "PEEK_W :: f32(560)"), "the line came through with its number still in it")
	for r in rows do if r.kind == .Mono && strings.has_prefix(r.text, "PEEK_SIGN") {
		testing.expect_value(t, r.num, 43)
	}

	// And output that is not numbered keeps every character it printed: a
	// timing line that opens with a number is not a listing.
	plain := tool_block("Bash", `{"command": "./build.sh"}`, "12 files\nbuilt ./aithing")
	defer block_destroy(&plain)
	rows = rows_of(app, &plain)
	testing.expect(t, has_row(rows, .Mono, "12 files"), "an unnumbered line lost its first word")
}

// The input arrives a few bytes at a time, so for most of a call there is no
// object to take apart — only however much of one the model has typed. The
// panel is asked for on every frame of that, and what it must not do is fall
// over or come up empty: the name is still on the head and whatever came back
// is still underneath it.
@(test)
a_call_still_being_typed_still_opens :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.rows)

	b := tool_block("Bash", `{"command": "odin te`, "")
	defer block_destroy(&b)
	rows := rows_of(app, &b)
	testing.expect_value(t, len(rows), 0)
	// And the one line beside the name is what there is of it so far.
	testing.expect_value(t, block_arg(&b), `{"command": "odin te`)
}
