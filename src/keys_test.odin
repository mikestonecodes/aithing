package aithing

import "core:os"
import "core:testing"

// The keymap parser reads what the compositor sends; getting a keycode row out
// of step there means every key in the window types the wrong character, so it
// is checked against a real keymap rather than by eye.

@(test)
keymap_reads_a_real_keymap :: proc(t: ^testing.T) {
	// Two real keymaps: one written with keysym names (`xkbcli compile-keymap`)
	// and one with hex keysyms and typed keys (what a compositor tends to
	// send, dumped with AITHING_KEYMAP=<path>).
	for path in ([?]string{"src/testdata/keymap.txt", "src/testdata/keymap-hex.txt"}) {
		check_keymap(t, path)
	}
}

@(private = "file")
check_keymap :: proc(t: ^testing.T, path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return // not on this machine; nothing to check
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

	// A keymap that parsed is the only authority: a keycode it does not
	// mention types nothing, rather than falling through to the US table and
	// typing whatever a US keyboard has in that position.
	testing.expect_value(t, keymap_char(&km, 250, false), rune(0))
	testing.expect(t, !keymap_repeats(&km, KEY_ESC), "escape should not repeat")
	testing.expect(t, keymap_repeats(&km, KEY_BACKSPACE), "backspace should repeat")
}

@(test)
keymap_without_a_keymap_falls_back :: proc(t: ^testing.T) {
	km: Keymap // nothing parsed: the built-in US table is all there is
	testing.expect_value(t, keymap_char(&km, KEY_A, false), 'a')
	testing.expect_value(t, keymap_char(&km, KEY_BACKSPACE, false), rune(0))
}
