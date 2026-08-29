package aithing

import "core:testing"

// The composer is the one place where a wrong byte offset is felt immediately,
// so the editing primitives are checked here rather than by typing into the
// window and squinting.

@(test)
insert_and_backspace :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)

	editor_insert(&e, "hello")
	testing.expect_value(t, editor_text(&e), "hello")
	testing.expect_value(t, e.cursor, 5)

	editor_key(&e, Key{KEY_BACKSPACE, {}}, 0)
	testing.expect_value(t, editor_text(&e), "hell")
	testing.expect_value(t, e.cursor, 4)
	testing.expect_value(t, e.anchor, 4)

	// Backspace in the middle takes the character to the left, not the right.
	e.cursor, e.anchor = 2, 2
	editor_key(&e, Key{KEY_BACKSPACE, {}}, 0)
	testing.expect_value(t, editor_text(&e), "hll")
	testing.expect_value(t, e.cursor, 1)
}

@(test)
delete_forward_and_selection :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)

	editor_insert(&e, "abcdef")
	e.cursor, e.anchor = 0, 0
	editor_key(&e, Key{KEY_DELETE, {}}, 0)
	testing.expect_value(t, editor_text(&e), "bcdef")

	// A selection is replaced by what is typed next.
	e.anchor, e.cursor = 1, 3
	editor_insert(&e, "X")
	testing.expect_value(t, editor_text(&e), "bXef")
	testing.expect_value(t, e.cursor, 2)

	// Backspace with a selection deletes the selection and nothing else.
	e.anchor, e.cursor = 0, 2
	editor_key(&e, Key{KEY_BACKSPACE, {}}, 0)
	testing.expect_value(t, editor_text(&e), "ef")
}

@(test)
word_motion :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)

	editor_insert(&e, "one two three")
	editor_key(&e, Key{KEY_BACKSPACE, {.Ctrl}}, 0)
	testing.expect_value(t, editor_text(&e), "one two ")

	editor_key(&e, Key{KEY_LEFT, {.Ctrl}}, 0)
	testing.expect_value(t, e.cursor, 4)
	editor_key(&e, Key{KEY_RIGHT, {.Ctrl}}, 0)
	testing.expect_value(t, e.cursor, 7)
}

@(test)
utf8_backspace :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)

	// A multi-byte character goes in one press, not four.
	editor_insert(&e, "aé漢")
	editor_key(&e, Key{KEY_BACKSPACE, {}}, 0)
	testing.expect_value(t, editor_text(&e), "aé")
	editor_key(&e, Key{KEY_BACKSPACE, {}}, 0)
	testing.expect_value(t, editor_text(&e), "a")
}

@(test)
enter_sends_shift_enter_does_not :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)

	editor_insert(&e, "hi")
	testing.expect_value(t, editor_key(&e, Key{KEY_ENTER, {.Shift}}, 0), Editor_Action.None)
	testing.expect_value(t, editor_text(&e), "hi\n")
	testing.expect_value(t, editor_key(&e, Key{KEY_ENTER, {}}, 0), Editor_Action.Submit)
}
