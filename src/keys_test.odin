package aithing

import "core:os"
import "core:testing"

// The keymap parser reads what the compositor sends; getting a keycode row out
// of step there means every key in the window types the wrong character, so it
// is checked against a real keymap rather than by eye.

@(test)
keymap_reads_a_real_keymap :: proc(t: ^testing.T) {
	// `xkbcli compile-keymap > testdata/keymap.txt` regenerates this.
	data, err := os.read_entire_file_from_path("src/testdata/keymap.txt", context.allocator)
	if err != nil do return // no dump on this machine; nothing to check
	defer delete(data)

	km, ok := keymap_parse(string(data))
	testing.expect(t, ok, "keymap should parse")
	defer keymap_destroy(&km)

	// evdev codes are the keymap's minus 8.
	testing.expect_value(t, keymap_char(&km, KEY_A, false), 'a')
	testing.expect_value(t, keymap_char(&km, KEY_A, true), 'A')
	testing.expect_value(t, keymap_char(&km, KEY_1, false), '1')
	testing.expect_value(t, keymap_char(&km, KEY_1, true), '!')
	testing.expect_value(t, keymap_char(&km, KEY_SPACE, false), ' ')

	// Keys that type nothing must type nothing: a backspace that inserts a
	// character is worse than a backspace that does not delete.
	testing.expect_value(t, keymap_char(&km, KEY_BACKSPACE, false), rune(0))
	testing.expect_value(t, keymap_char(&km, KEY_DELETE, false), rune(0))
	testing.expect_value(t, keymap_char(&km, KEY_ENTER, false), rune(0))
	testing.expect_value(t, keymap_char(&km, KEY_ESC, false), rune(0))
	testing.expect_value(t, keymap_char(&km, KEY_TAB, false), rune(0))
	testing.expect_value(t, keymap_char(&km, KEY_LEFT, false), rune(0))
}
