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

	// On a real keyboard the keymap agrees with the codes on the wire, so
	// resolving a code has to leave it alone.
	testing.expect_value(t, keymap_code(&km, KEY_ESC), u32(KEY_ESC))
	testing.expect_value(t, keymap_code(&km, KEY_C), u32(KEY_C))
	testing.expect_value(t, keymap_code(&km, KEY_INSERT), u32(KEY_INSERT))
}

// A keymap that is not a keyboard. `wtype` sends one of these every time a
// compositor binding types for you — niri's Mod+C is
// `spawn "wtype" "-M" "ctrl" "-k" "Insert"` — and it carries a single key,
// `<K1> = 9`, which arrives as evdev code 1. Code 1 on a US keyboard is
// Escape, so copy, paste and cut all came through as Escape and closed the
// thread. The keymap said Insert the whole time; nothing was reading it.
@(test)
keymap_reads_a_synthetic_keyboard :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path("src/testdata/keymap-wtype.txt", context.allocator)
	if err != nil do return
	defer delete(data)

	km, ok := keymap_parse(string(data))
	testing.expect(t, ok, "wtype's keymap should parse")
	defer keymap_destroy(&km)

	testing.expect_value(t, keymap_code(&km, 1), u32(KEY_INSERT))
	testing.expect(t, keymap_code(&km, 1) != KEY_ESC, "code 1 here is not escape")

	// The same keyboard typing a cut, which wtype sends as ctrl and the
	// letter x rather than as a key with a name. A letter has to be followed
	// to wherever the keymap put it for the same reason: on the wire it is
	// still code 1.
	cut, cut_ok := keymap_parse(
		`xkb_keymap {
xkb_keycodes "(unnamed)" { minimum = 8; maximum = 255; <K1> = 9; };
xkb_symbols "(unnamed)" { key <K1> {	[ 0x78 ] }; };
};`,
	)
	testing.expect(t, cut_ok, "a one-letter keymap should parse")
	defer keymap_destroy(&cut)
	testing.expect_value(t, keymap_code(&cut, 1), u32(KEY_X))
}

@(test)
keymap_without_a_keymap_falls_back :: proc(t: ^testing.T) {
	km: Keymap // nothing parsed: the built-in US table is all there is
	testing.expect_value(t, keymap_char(&km, KEY_A, false), 'a')
	testing.expect_value(t, keymap_char(&km, KEY_BACKSPACE, false), rune(0))
}
