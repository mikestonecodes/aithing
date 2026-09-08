package aithing

import "core:strconv"
import "core:strings"

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
KEY_SLASH :: 53
KEY_INSERT :: 110
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

// --- the compositor's own keymap --------------------------------------------
//
// The US table above is only the fallback. What the compositor actually sends
// is an xkb keymap on a file descriptor: text, with a section naming every
// key and a section giving the symbols on it. Translating it is what
// libxkbcommon is for, and linking that would undo the point of the rest of
// this program, so the two sections that matter are parsed here.
//
//   xkb_keycodes "..." {  <AD01> = 24;          ...  };
//   xkb_symbols  "..." {  key <AD01> { [ q, Q ] };   };
//
// Keycodes in the keymap are the evdev code plus 8, the way X numbered them.

Keymap :: struct {
	levels: map[u32][2]rune, // evdev code -> unshifted, shifted
	codes:  map[u32]u32, // evdev code -> the key it actually is
	parsed: bool, // once this holds, the keymap is the only authority
}

keymap_parse :: proc(text: string) -> (km: Keymap, ok: bool) {
	names := make(map[string]u32, 256, context.temp_allocator)
	defer delete(names)

	// Section one: <NAME> = CODE;
	codes := section(text, "xkb_keycodes")
	rest := codes
	for {
		open := strings.index_byte(rest, '<')
		if open < 0 do break
		close := strings.index_byte(rest[open:], '>')
		if close < 0 do break
		name := rest[open + 1:open + close]
		rest = rest[open + close + 1:]

		eq := strings.index_byte(rest, '=')
		semi := strings.index_byte(rest, ';')
		if eq < 0 || semi < 0 || eq > semi do continue
		value := strings.trim_space(rest[eq + 1:semi])
		if code, parsed := strconv.parse_int(value); parsed && code >= 8 {
			names[name] = u32(code - 8)
		}
		rest = rest[semi + 1:]
	}
	if len(names) == 0 do return {}, false

	// Section two: key <NAME> { ... [ level1, level2, ... ] ... };
	syms := section(text, "xkb_symbols")
	rest = syms
	for {
		idx := strings.index(rest, "key <")
		if idx < 0 do break
		rest = rest[idx + 5:]
		close := strings.index_byte(rest, '>')
		if close < 0 do break
		name := rest[:close]
		rest = rest[close + 1:]

		// The key's body ends at the first `};`; take the last bracketed list
		// inside it, which for a multi-group key is the one for group 1.
		end := strings.index(rest, "};")
		if end < 0 do break
		body := rest[:end]
		rest = rest[end + 2:]

		list, found := symbol_list(body)
		if !found do continue

		code, has := names[name]
		if !has do continue

		pair: [2]rune
		first: string
		level := 0
		for part in strings.split_iterator(&list, ",") {
			if level >= 2 do break
			sym := strings.trim_space(part)
			if level == 0 do first = sym
			pair[level] = keysym_rune(sym)
			level += 1
		}
		// Keys that type nothing are recorded too, as a pair of zeroes. That
		// is the whole point: the keymap has to be able to say "this key types
		// nothing", or a Delete sitting on a keycode that a US keyboard uses
		// for a digit falls through and types the digit.
		km.levels[code] = pair

		// And what the key *is*, which is a different question from what it
		// types and until now was answered by a different authority: the
		// switches on KEY_ESC and friends read the raw evdev code straight
		// off the wire. See `keymap_code`.
		if canon, named := keysym_key(first); named {
			km.codes[code] = canon
		} else if canon, letter := letter_code(pair[0]); letter {
			km.codes[code] = canon
		}
	}
	km.parsed = len(km.levels) > 0
	return km, km.parsed
}

keymap_destroy :: proc(km: ^Keymap) {
	delete(km.levels)
	delete(km.codes)
	km^ = {}
}

// The character a key types. A keymap that parsed is the only authority —
// including about which keys type nothing at all. The US table is used only
// when there is no keymap to go on.
keymap_char :: proc(km: ^Keymap, code: u32, shift: bool) -> rune {
	if km.parsed {
		pair := km.levels[code] or_else [2]rune{}
		r := shift ? pair[1] : pair[0]
		if r == 0 && shift do r = pair[0]
		return r
	}
	return rune(key_char(code, shift))
}

// Which key a keycode is, which is not the same question as what it types and
// must not be answered by a second authority.
//
// It used to be: `keymap_char` asked the compositor's keymap, while every
// shortcut compared the raw evdev code against the US table at the top of this
// file. That agrees right up until something hands the window a keymap that is
// not a keyboard. `wtype` does — it is how a compositor binding types for you,
// as in niri's
//
//     Mod+C { spawn "wtype" "-M" "ctrl" "-k" "Insert"; }
//
// and it sends a one-key keymap, `<K1> = 9` carrying Insert, so the key
// arrives as evdev code 1. Code 1 in the US table is Escape. Pressing copy
// closed the thread, and so did paste, and so did cut.
//
// Every keycode enters the program through here, once, at the window. A key
// the keymap does not name keeps the code it came in with, which is what a
// real keyboard's keymap agrees with anyway.
keymap_code :: proc(km: ^Keymap, code: u32) -> u32 {
	if !km.parsed do return code
	return km.codes[code] or_else code
}

// The keys that are keys rather than characters, by keysym. Compositors send
// keysyms either by name or as hex, so both forms are here on one row.
@(private = "file")
STRUCTURAL := [?]struct {
	name:  string,
	value: u64,
	code:  u32,
} {
	{"Escape", 0xff1b, KEY_ESC},
	{"Return", 0xff0d, KEY_ENTER},
	{"KP_Enter", 0xff8d, KEY_KPENTER},
	{"BackSpace", 0xff08, KEY_BACKSPACE},
	{"Tab", 0xff09, KEY_TAB},
	{"Insert", 0xff63, KEY_INSERT},
	{"Delete", 0xffff, KEY_DELETE},
	{"Home", 0xff50, KEY_HOME},
	{"Left", 0xff51, KEY_LEFT},
	{"Up", 0xff52, KEY_UP},
	{"Right", 0xff53, KEY_RIGHT},
	{"Down", 0xff54, KEY_DOWN},
	{"Page_Up", 0xff55, KEY_PAGEUP},
	{"Page_Down", 0xff56, KEY_PAGEDOWN},
	{"End", 0xff57, KEY_END},
}

@(private = "file")
keysym_key :: proc(sym: string) -> (code: u32, ok: bool) {
	value: u64
	if strings.has_prefix(sym, "0x") {
		v, parsed := strconv.parse_u64_of_base(sym[2:], 16)
		if !parsed do return 0, false
		value = v
	}
	for s in STRUCTURAL {
		hit := value != 0 ? s.value == value : s.name == sym
		if hit do return s.code, true
	}
	return 0, false
}

// The keycode a letter sits on for the purposes of a shortcut. Ctrl+N is the
// key labelled n: on a US keyboard that is the code it arrived on, and on
// anything else — a Dvorak layout, or wtype's scratch keymap typing a cut as
// ctrl and the letter x — the label is the only thing that means anything.
@(private = "file")
letter_code :: proc(r: rune) -> (code: u32, ok: bool) {
	if r < 'a' || r > 'z' do return 0, false
	for c, i in UNSHIFTED do if rune(c) == r do return u32(i), true
	return 0, false
}

// Whether a held key should repeat: anything that types, plus the editing keys.
keymap_repeats :: proc(km: ^Keymap, code: u32) -> bool {
	switch code {
	case KEY_BACKSPACE, KEY_DELETE, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN,
	     KEY_PAGEUP, KEY_PAGEDOWN:
		return true
	}
	return keymap_char(km, code, false) != 0
}

// The bracketed symbol list out of a key's body. A key is written either as
//
//     key <AD01> { [ 0x71, 0x51 ] };
//
// or, when it needs a type, as
//
//     key <BKSP> { type= "CTRL+ALT", symbols[1]= [ 0xff08, ... ] };
//
// so the first `[` in the body is not necessarily the list: in the second form
// it is the `[1]` of `symbols[1]`, whose contents read as the character `1` —
// which is how a backspace ends up typing a digit. The list is the bracket
// that follows a `=` or the opening `{`.
@(private = "file")
symbol_list :: proc(body: string) -> (list: string, ok: bool) {
	for i in 0 ..< len(body) {
		if body[i] != '[' do continue
		j := i - 1
		for j >= 0 && (body[j] == ' ' || body[j] == '\t' || body[j] == '\n') do j -= 1
		if j < 0 do continue
		if body[j] != '=' && body[j] != '{' do continue
		shut := strings.index_byte(body[i:], ']')
		if shut < 0 do return "", false
		return body[i + 1:i + shut], true
	}
	return "", false
}

// The body of `xkb_<name> "..." { ... }`.
@(private = "file")
section :: proc(text: string, name: string) -> string {
	start := strings.index(text, name)
	if start < 0 do return ""
	body := text[start:]
	open := strings.index_byte(body, '{')
	if open < 0 do return ""
	return body[open + 1:]
}

// Keysym names to characters. Single-character names are themselves; the rest
// are the handful of names xkb gives to punctuation, plus the `UXXXX` form.
@(private = "file")
keysym_rune :: proc(sym: string) -> rune {
	if sym == "" || sym == "NoSymbol" do return 0
	if len(sym) == 1 do return rune(sym[0])

	if sym[0] == 'U' && len(sym) >= 5 {
		if v, ok := strconv.parse_u64_of_base(sym[1:], 16); ok do return rune(v)
	}
	if strings.has_prefix(sym, "0x") {
		if v, ok := strconv.parse_u64_of_base(sym[2:], 16); ok {
			// Unicode keysyms are 0x01000000 + codepoint.
			if v > 0x0100_0000 do return rune(v - 0x0100_0000)
			if v < 0x100 do return rune(v)
		}
	}

	switch sym {
	case "space":        return ' '
	case "exclam":       return '!'
	case "quotedbl":     return '"'
	case "numbersign":   return '#'
	case "dollar":       return '$'
	case "percent":      return '%'
	case "ampersand":    return '&'
	case "apostrophe", "quoteright": return '\''
	case "parenleft":    return '('
	case "parenright":   return ')'
	case "asterisk":     return '*'
	case "plus":         return '+'
	case "comma":        return ','
	case "minus":        return '-'
	case "period":       return '.'
	case "slash":        return '/'
	case "colon":        return ':'
	case "semicolon":    return ';'
	case "less":         return '<'
	case "equal":        return '='
	case "greater":      return '>'
	case "question":     return '?'
	case "at":           return '@'
	case "bracketleft":  return '['
	case "backslash":    return '\\'
	case "bracketright": return ']'
	case "asciicircum":  return '^'
	case "underscore":   return '_'
	case "grave", "quoteleft": return '`'
	case "braceleft":    return '{'
	case "bar":          return '|'
	case "braceright":   return '}'
	case "asciitilde":   return '~'
	case "nobreakspace": return ' '
	case "exclamdown":   return '¡'
	case "cent":         return '¢'
	case "sterling":     return '£'
	case "yen":          return '¥'
	case "section":      return '§'
	case "diaeresis":    return '¨'
	case "guillemotleft":  return '«'
	case "guillemotright": return '»'
	case "degree":       return '°'
	case "plusminus":    return '±'
	case "acute":        return '´'
	case "mu":           return 'µ'
	case "questiondown": return '¿'
	case "multiply":     return '×'
	case "division":     return '÷'
	case "ssharp":       return 'ß'
	case "adiaeresis":   return 'ä'
	case "Adiaeresis":   return 'Ä'
	case "odiaeresis":   return 'ö'
	case "Odiaeresis":   return 'Ö'
	case "udiaeresis":   return 'ü'
	case "Udiaeresis":   return 'Ü'
	case "aring":        return 'å'
	case "Aring":        return 'Å'
	case "ae":           return 'æ'
	case "AE":           return 'Æ'
	case "oslash":       return 'ø'
	case "Oslash":       return 'Ø'
	case "ccedilla":     return 'ç'
	case "Ccedilla":     return 'Ç'
	case "ntilde":       return 'ñ'
	case "Ntilde":       return 'Ñ'
	case "aacute":       return 'á'
	case "eacute":       return 'é'
	case "iacute":       return 'í'
	case "oacute":       return 'ó'
	case "uacute":       return 'ú'
	case "agrave":       return 'à'
	case "egrave":       return 'è'
	case "ugrave":       return 'ù'
	case "acircumflex":  return 'â'
	case "ecircumflex":  return 'ê'
	case "ocircumflex":  return 'ô'
	case "EuroSign":     return '€'
	}
	// Dead keys, function keys, modifiers: nothing to type.
	return 0
}
