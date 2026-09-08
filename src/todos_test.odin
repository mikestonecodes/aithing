package aithing

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

@(test)
split_by_sentence :: proc(t: ^testing.T) {
	parts := todos_split("fix the caret. rebake the atlas; ship it")
	testing.expect_value(t, len(parts), 3)
	testing.expect_value(t, parts[2], "ship it")
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
