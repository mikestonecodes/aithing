package aithing

// The compositor hands us raw evdev keycodes and an xkb keymap on a file
// descriptor. Parsing that keymap is what libxkbcommon exists for, and pulling
// in a library for it would undo the point of the rest of this program, so the
// keycodes are translated here against a US layout instead.
//
// The consequence is that a non-US layout types US characters. Everything
// structural — the modifiers, the arrows, backspace, enter — is layout
// independent and works regardless.

KEY_ESC :: 1
KEY_1 :: 2
KEY_MINUS :: 12
KEY_EQUAL :: 13
KEY_BACKSPACE :: 14
KEY_TAB :: 15
KEY_Q :: 16
KEY_W :: 17
KEY_E :: 18
KEY_R :: 19
KEY_T :: 20
KEY_Y :: 21
KEY_U :: 22
KEY_I :: 23
KEY_O :: 24
KEY_P :: 25
KEY_ENTER :: 28
KEY_A :: 30
KEY_S :: 31
KEY_D :: 32
KEY_F :: 33
KEY_G :: 34
KEY_H :: 35
KEY_J :: 36
KEY_K :: 37
KEY_L :: 38
KEY_Z :: 44
KEY_X :: 45
KEY_C :: 46
KEY_V :: 47
KEY_B :: 48
KEY_N :: 49
KEY_M :: 50
KEY_SPACE :: 57
KEY_F1 :: 59
KEY_KPENTER :: 96
KEY_HOME :: 102
KEY_UP :: 103
KEY_PAGEUP :: 104
KEY_LEFT :: 105
KEY_RIGHT :: 106
KEY_END :: 107
KEY_DOWN :: 108
KEY_PAGEDOWN :: 109
KEY_DELETE :: 111

@(private = "file")
UNSHIFTED := [?]u8 {
	0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0, 0,
	'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0, 0,
	'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\',
	'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' ',
}

@(private = "file")
SHIFTED := [?]u8 {
	0, 0, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0, 0,
	'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0, 0,
	'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|',
	'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' ',
}

// The character a keycode types, or 0 if it types nothing (enter and tab are
// handled as keys, not as text, so the composer can act on them).
key_char :: proc "contextless" (code: u32, shift: bool) -> u8 {
	table := shift ? SHIFTED[:] : UNSHIFTED[:]
	if int(code) >= len(table) do return 0
	return table[code]
}

// Which keys should repeat while held. Text keys and the movement/deletion
// keys do; modifiers, escape and enter do not.
key_repeats :: proc "contextless" (code: u32) -> bool {
	switch code {
	case KEY_BACKSPACE, KEY_DELETE, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN,
	     KEY_PAGEUP, KEY_PAGEDOWN:
		return true
	}
	return key_char(code, false) != 0
}
