package aithing

import "core:os"
import "core:testing"

// What a typed list cuts into: the split is what the grid is made of, and it
// is made on the spot with nothing asked of a model. A `*` is the whole of
// the rule.

@(test)
split_on_stars :: proc(t: ^testing.T) {
	parts := todos_split("fix the caret * rebake the atlas * ship it")
	testing.expect_value(t, len(parts), 3)
	testing.expect_value(t, parts[0], "fix the caret")
	testing.expect_value(t, parts[1], "rebake the atlas")
	testing.expect_value(t, parts[2], "ship it")
}

// The spaces and newlines around a star are text breakup, not part of what
// was asked for, so a star on a line of its own reads the same as one typed
// mid-sentence.
@(test)
split_takes_the_spacing_off :: proc(t: ^testing.T) {
	parts := todos_split("fix the caret\n\n*\n\nrebake the atlas*ship it")
	testing.expect_value(t, len(parts), 3)
	testing.expect_value(t, parts[0], "fix the caret")
	testing.expect_value(t, parts[1], "rebake the atlas")
	testing.expect_value(t, parts[2], "ship it")
}

// A paragraph is one job. Lines, bullets, numbers and full stops all used to
// cut, which answered anything written at length with a card per sentence.
@(test)
split_keeps_a_paragraph_whole :: proc(t: ^testing.T) {
	text := "bump to 1.2 in build.sh and tag it. check it at 1200 sessions\n- and again after the atlas rebake\n2) then ship it"
	parts := todos_split(text)
	testing.expect_value(t, len(parts), 1)
	testing.expect_value(t, parts[0], text)
}

// A lone line is one card, and the box's own trailing whitespace is none.
@(test)
split_keeps_one :: proc(t: ^testing.T) {
	parts := todos_split("  bump to 1.2 everywhere  ")
	testing.expect_value(t, len(parts), 1)
	testing.expect_value(t, parts[0], "bump to 1.2 everywhere")
}

// A star with nothing on one side of it is not an empty card.
@(test)
split_drops_the_empty_parts :: proc(t: ^testing.T) {
	parts := todos_split("* rebake the atlas **")
	testing.expect_value(t, len(parts), 1)
	testing.expect_value(t, parts[0], "rebake the atlas")
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
