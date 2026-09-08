package aithing

import "core:os"
import "core:testing"

// What a typed list cuts into: the split is what the grid is made of, and it
// is made on the spot with nothing asked of a model.

@(test)
split_by_line :: proc(t: ^testing.T) {
	parts := todos_split("fix the caret\n- rebake the atlas\n2) ship it")
	testing.expect_value(t, len(parts), 3)
	testing.expect_value(t, parts[0], "fix the caret")
	testing.expect_value(t, parts[1], "rebake the atlas")
	testing.expect_value(t, parts[2], "ship it")
}

// A full stop in the middle of a line is where the next card starts. Typing
// two things on one line and getting one card back was what made the box look
// like it had not heard.
@(test)
split_by_sentence :: proc(t: ^testing.T) {
	parts := todos_split("fix the caret. rebake the atlas; ship it")
	testing.expect_value(t, len(parts), 3)
	testing.expect_value(t, parts[0], "fix the caret")
	testing.expect_value(t, parts[1], "rebake the atlas")
	testing.expect_value(t, parts[2], "ship it")
}

// A stop with no space after it is inside a word, not the end of a sentence.
@(test)
split_keeps_a_version_whole :: proc(t: ^testing.T) {
	parts := todos_split("bump to 1.2 in build.sh and tag it")
	testing.expect_value(t, len(parts), 1)
	testing.expect_value(t, parts[0], "bump to 1.2 in build.sh and tag it")
}

// A line that ends in a full stop is one card, not one and an empty one.
@(test)
split_ignores_a_trailing_stop :: proc(t: ^testing.T) {
	parts := todos_split("rebake the atlas.")
	testing.expect_value(t, len(parts), 1)
	testing.expect_value(t, parts[0], "rebake the atlas")
}

// A version number is not two items, and a lone line is not none.
@(test)
split_keeps_one :: proc(t: ^testing.T) {
	parts := todos_split("  bump to 1.2 everywhere  ")
	testing.expect_value(t, len(parts), 1)
	testing.expect_value(t, parts[0], "bump to 1.2 everywhere")
}

// The state file has to survive a draft with newlines in it.
@(test)
escape_round_trip :: proc(t: ^testing.T) {
	text := "two\nlines \\ and a slash"
	back := unescape_line(escape_line(text))
	defer delete(back)
	testing.expect_value(t, back, text)
}

// The state column's number 4 meant Queued in a version 4 file and means
// Asked in this one. A file written by the last build still has to read back
// as what it said, and a card that was queued when a window quit was a card
// nothing had started.
@(test)
an_older_file_still_reads :: proc(t: ^testing.T) {
	path := "/tmp/aithing-test-todos-v4"
	_ = os.write_entire_file(
		path,
		transmute([]byte)string("4\n4\t0\tn-1\t\t/tmp/proj\tqueued when it quit\n"),
	)
	back: Todos
	defer todos_destroy(&back)
	todos_load(&back, path)
	testing.expect_value(t, len(back.list), 1)
	testing.expect_value(t, back.list[0].state, Todo_State.Open)
}
