package aithing

import "core:strings"

// What a shell command actually does.
//
// A shell call is not one kind of thing. `python3 - <<EOF ... EOF` that walks a
// file and puts one string in place of another is an edit; `sed -i s/a/b/` is
// an edit; `cat > f <<EOF` writes a file; `cat src/app.odin` is a read; `grep
// -n` is a search; and what is left over is a command. The agent reaches for
// python to add and remove lines at least as often as it reaches for the edit
// tool, and every one of those turns was a green terminal stone with the same
// panel a build gets — the move the path exists to show at a glance, drawn as
// the kind of move that says least.
//
// So a shell call is read here: what family it belongs to, which files it
// names, and the pairs of strings it swaps. Nothing here runs anything or
// looks at the disk — it reads the text of the command, which was going to be
// drawn anyway. Where it cannot tell, it says so by giving nothing back, and
// the panel falls back to the command and its output, which is where it
// started.

// How much of a command is read at each end to say what family it is in.
// `tool_style` asks that of every stone of the thread on every frame, and a
// heredoc can be any length at all — a scan of the whole of one, per stone,
// per frame, is the one thing here that would make the path slow.
SHELL_SNIFF :: 512
SHELL_FILES :: 6 // paths named in the panel, before it stops listing them
SHELL_SWAPS :: 6 // changes shown, before the rest is left to the file

// One string put in place of another: half of a `sed` script, or the two
// arguments of a python `replace`. `file` is the path it was done to — for a
// script that walks three files in a row, the one named last before the call,
// which is where the path was set for it.
Swap :: struct {
	old:  string,
	new:  string,
	file: string,
}

Shell :: struct {
	family: Icon, // Edit, Read, Find, or Run — what the call amounts to
	files:  []string, // the paths it names, in the order it names them
	swaps:  []Swap, // what it puts in place of what
	from:   int, // the line its output starts at, when that can be known
}

// The whole reading of one command. Asked once when a panel is built, so it
// parses properly rather than sniffing.
shell_read :: proc(cmd: string, allocator := context.temp_allocator) -> (sh: Shell) {
	context.allocator = allocator
	sh.family = shell_family(cmd)
	sh.from = shell_from(cmd)

	files := make([dynamic]string, context.allocator)
	swaps := make([dynamic]Swap, context.allocator)

	// A heredoc is either a program or a file. `cat > x <<EOF` means the body
	// is what x now says, which is the same news as a Write; anything else
	// fed a heredoc — python, mostly — means the body is a script, and the
	// script is where the strings being swapped live.
	body, head, has_body := heredoc(cmd)
	if has_body && redirects(head) {
		append(&swaps, Swap{"", body, ""})
	}
	script := has_body && !redirects(head) ? body : cmd
	shell_sed_swaps(cmd, &swaps)
	if has_body && !redirects(head) do python_swaps(script, &swaps)

	// The paths: out of the command line first, since that is where a shell
	// tool names its file, and then out of the script, which is where a
	// python one does.
	shell_paths(has_body ? head : cmd, &files)
	if has_body && !redirects(head) do shell_paths(script, &files)

	// A swap the script did not name a file for belongs to the file the
	// command line named, which is where a `sed -i` puts it.
	for &swap in swaps do if swap.file == "" && len(files) > 0 do swap.file = files[0]

	sh.files = files[:]
	sh.swaps = swaps[:]
	return
}

// Which family the call belongs to. Order matters: a command that writes is an
// edit whatever else it also does, and one that only reads is a read even when
// it reads with a tool that could have written.
@(private = "file")
shell_family :: proc(cmd: string) -> Icon {
	// The head of the command and its tail, rather than the first few
	// kilobytes of it: a shell redirect is on the first line and a python
	// script's `open(p, "w").write(s)` is on the last, and a script with
	// sixty lines of strings between the two used to fall off the end of the
	// window and come out as a plain command — the exact case this was
	// written for.
	if shell_writes(sniff_head(cmd)) || shell_writes(sniff_tail(cmd)) do return .Edit
	// Off the first word, not off anywhere in the line: `odin test src | tail
	// -3` ends in a read verb and is not a read of anything — it is the
	// suite, with the last three lines of what it said kept.
	switch first_word(cmd) {
	case "grep", "rg", "ag", "find", "fd":
		return .Find
	case "cat", "head", "tail", "less", "ls", "wc", "stat", "file", "bat":
		return .Read
	case "sed":
		return strings.contains(sniff_head(cmd), "-n") ? .Read : .Run
	}
	return .Run
}

@(private = "file")
sniff_head :: proc(cmd: string) -> string {
	return len(cmd) > SHELL_SNIFF ? cmd[:SHELL_SNIFF] : cmd
}

@(private = "file")
sniff_tail :: proc(cmd: string) -> string {
	return len(cmd) > SHELL_SNIFF ? cmd[len(cmd) - SHELL_SNIFF:] : ""
}

// The command being run, without its path or its leading environment. Only
// the first one: what a pipeline ends with is not what it did.
@(private = "file")
first_word :: proc(cmd: string) -> string {
	i := 0
	for i < len(cmd) && (cmd[i] == ' ' || cmd[i] == '\n' || cmd[i] == '(') do i += 1
	start := i
	for i < len(cmd) && cmd[i] != ' ' && cmd[i] != '\n' do i += 1
	word := cmd[start:i]
	if slash := strings.last_index_byte(word, '/'); slash >= 0 do word = word[slash + 1:]
	return word
}

// Whether a command puts anything on disk.
//
// One pass over the text with a switch on the byte and the byte after it,
// rather than a search for each marker in turn: this is asked for every stone
// of the thread on every frame, and fifteen passes over four kilobytes, four
// hundred times, is the whole frame gone on deciding what colour the squares
// are. The second byte is checked before anything longer is compared, because
// a script is full of full stops and esses and every one of them was calling
// out to compare three whole words. Four hundred stones each holding a
// four-kilobyte heredoc — the worst thread this can be handed — cost 18 ms a
// rebuild that way and cost 3.3 ms this way, both in a test build; see
// shell_cost_test.odin, which measures a likelier mix of stones.
@(private = "file")
shell_writes :: proc(cmd: string) -> bool {
	i := 0
	for i < len(cmd) - 1 {
		c, d := cmd[i], cmd[i + 1]
		switch c {
		case '>':
			if redirect_at(cmd, i) do return true
		case '.':
			if d == 'w' && (at(cmd, i, ".write(") || at(cmd, i, ".writelines(")) do return true
		case 's':
			if d == 'e' && at(cmd, i, "sed -i") do return true
			if d == 'h' && at(cmd, i, "shutil.") do return true
		case 't':
			if d == 'e' && at(cmd, i, "tee ") do return true
			if d == 'o' && word_at(cmd, i, "touch") do return true
		case 'o':
			if d != 's' do break
			if at(cmd, i, "os.rename") || at(cmd, i, "os.remove") || at(cmd, i, "os.replace") do return true
		case 'c':
			if (d == 'p' && word_at(cmd, i, "cp")) || (d == 'h' && word_at(cmd, i, "chmod")) do return true
		case 'm':
			if (d == 'v' && word_at(cmd, i, "mv")) || (d == 'k' && word_at(cmd, i, "mkdir")) do return true
		case 'r':
			if d == 'm' && word_at(cmd, i, "rm") do return true
		case 'g':
			if d == 'i' && at(cmd, i, "git apply") do return true
		case 'p':
			if d == 'a' && at(cmd, i, "patch -") do return true
		}
		i += 1
	}
	return false
}

@(private = "file")
at :: proc(s: string, i: int, lit: string) -> bool {
	return strings.has_prefix(s[i:], lit)
}

// The same, but only when the word stands on its own: `cp` is a copy and
// `cpp` is not, and neither is the `rm` in `strings.trim_right_space`.
@(private = "file")
word_at :: proc(s: string, i: int, word: string) -> bool {
	if !at(s, i, word) do return false
	if i > 0 && !is_break(s[i - 1]) do return false
	end := i + len(word)
	return end >= len(s) || s[end] == ' ' || s[end] == '\n'
}

// A redirect that lands on a file: `> out.txt`, `2>> log`. Not the `2>&1` and
// the `>/dev/null` that half the commands in a transcript end with, and — the
// one that actually went wrong — not the `->` inside a python `print(p, '->',
// m)`, which is an arrow in a string and was read as a redirect. That one
// command listed a dozen files and changed none of them, and the stone for it
// wore a pencil.
//
// So both sides are checked. What is in front of a redirect is a space or a
// file descriptor; what follows it is where the output goes, which starts
// like a path and not like the rest of a quoted string.
@(private = "file")
redirect_at :: proc(cmd: string, at_: int) -> bool {
	if at_ > 0 {
		b := cmd[at_ - 1]
		switch {
		case b == ' ' || b == '\t' || b == '"' || b == '\'':
		case b >= '0' && b <= '9':
			// A descriptor, and only when it stands alone: `2>` redirects and
			// the `2` in `x2>` is the end of a name.
			if at_ > 1 && !is_break(cmd[at_ - 2]) do return false
		case:
			return false
		}
	}
	j := at_ + 1
	if j < len(cmd) && cmd[j] == '>' do j += 1
	for j < len(cmd) && cmd[j] == ' ' do j += 1
	if j >= len(cmd) do return false
	c := cmd[j]
	if c == '&' do return false
	if strings.has_prefix(cmd[j:], "/dev/null") do return false
	return c == '/' || c == '.' || c == '~' || c == '$' || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

@(private = "file")
redirects :: proc(cmd: string) -> bool {
	for i in 0 ..< len(cmd) do if cmd[i] == '>' && redirect_at(cmd, i) do return true
	return false
}

// The line the output starts at, for a command that prints part of a file.
// `sed -n '120,160p'` starts at 120; a whole file starts at one; and anything
// that cannot be told is nought, which means the panel numbers nothing rather
// than numbering it wrongly.
@(private = "file")
shell_from :: proc(cmd: string) -> int {
	if at := strings.index(cmd, "sed -n"); at >= 0 {
		i := at + 6
		for i < len(cmd) && !(cmd[i] >= '0' && cmd[i] <= '9') && cmd[i] != '\n' do i += 1
		n := 0
		digits := false
		for i < len(cmd) && cmd[i] >= '0' && cmd[i] <= '9' {
			n = n * 10 + int(cmd[i] - '0')
			i += 1
			digits = true
		}
		return digits ? n : 0
	}
	if word_in(cmd, "cat") || word_in(cmd, "head") do return 1
	return 0
}

// --- what it swaps ------------------------------------------------------------

// `sed -i 's/old/new/g'`, whatever the delimiter is. The script may be quoted
// or bare and may carry flags after it; what is wanted is the two halves.
@(private = "file")
shell_sed_swaps :: proc(cmd: string, out: ^[dynamic]Swap) {
	i := 0
	for i + 2 < len(cmd) {
		// An `s` that opens a script: at the start of a word, with a
		// delimiter after it. `commands` and `files` have esses in them too.
		if cmd[i] != 's' || !(i == 0 || cmd[i - 1] == ' ' || cmd[i - 1] == '\'' || cmd[i - 1] == '"') {
			i += 1
			continue
		}
		delim := cmd[i + 1]
		if delim != '/' && delim != '|' && delim != '#' && delim != ',' {
			i += 1
			continue
		}
		old, after, ok := sed_part(cmd, i + 2, delim)
		if !ok {
			i += 1
			continue
		}
		new, end, ok2 := sed_part(cmd, after, delim)
		if !ok2 {
			i += 1
			continue
		}
		if len(out) < SHELL_SWAPS {
			append(out, Swap{sed_text(old, delim), sed_text(new, delim), ""})
		}
		i = end
	}
}

@(private = "file")
sed_part :: proc(s: string, from: int, delim: u8) -> (text: string, end: int, ok: bool) {
	i := from
	for i < len(s) {
		if s[i] == '\\' {
			i += 2
			continue
		}
		if s[i] == '\n' do return "", from, false
		if s[i] == delim do return s[from:i], i + 1, true
		i += 1
	}
	return "", from, false
}

// A sed half as the text it stands for: the delimiter unescaped, and `\n` the
// newline it means rather than the two characters it is written as.
@(private = "file")
sed_text :: proc(s: string, delim: u8) -> string {
	b := strings.builder_make(context.allocator)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
			case 't':
				strings.write_byte(&b, '\t')
			case:
				strings.write_byte(&b, s[i + 1])
			}
			i += 2
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

// `s.replace(old, new)` in a python script, with either argument written out
// or named. Named is the common one: the two strings are long, so they are
// assigned above and the call is one line — which is why this resolves names
// against the assignments in the same script rather than only reading
// literals, and why the first go at it found nothing in a script that was
// plainly an edit.
@(private = "file")
python_swaps :: proc(script: string, out: ^[dynamic]Swap) {
	names := python_names(script)
	i := 0
	for {
		at := strings.index(script[i:], ".replace(")
		if at < 0 do break
		j := i + at + len(".replace(")
		old, after, ok := python_arg(script, j, names)
		if !ok {
			i = j
			continue
		}
		k := after
		for k < len(script) && (script[k] == ' ' || script[k] == ',') do k += 1
		new, end, ok2 := python_arg(script, k, names)
		if !ok2 {
			i = j
			continue
		}
		// Which file this one is being done to: the last path the script
		// named before it. A script that walks three files in a row sets the
		// path, reads, replaces and writes, three times over, and every one
		// of those changes belongs under the name it was set to.
		if len(out) < SHELL_SWAPS do append(out, Swap{old, new, last_path(script[:j])})
		i = end
	}
}

// Every `name = <string>` in the script. The two sides of a change are long,
// so they are assigned above and the call that uses them is one line — which
// is why the names are resolved rather than only literals read, and why the
// first go at this found nothing in a script that was plainly an edit. A name
// written twice keeps the last, which is what python reading top to bottom
// would do.
@(private = "file")
python_names :: proc(script: string) -> map[string]string {
	names := make(map[string]string, 8, context.allocator)
	i := 0
	for i < len(script) {
		if script[i] != '=' {
			i += 1
			continue
		}
		// A comparison is not an assignment, and neither is `+=`.
		if i + 1 < len(script) && script[i + 1] == '=' {
			i += 2
			continue
		}
		if i > 0 && (script[i - 1] == '!' || script[i - 1] == '<' || script[i - 1] == '>' || script[i - 1] == '=' || script[i - 1] == '+') {
			i += 1
			continue
		}
		name := strings.trim_space(script[line_start(script, i):i])
		j := i + 1
		for j < len(script) && script[j] == ' ' do j += 1
		text, end, ok := python_literal(script, j)
		// Only when the whole of the right-hand side is the string: `a = b +
		// c` is not a string this can hand back, and half of one is worse
		// than none.
		if ok && is_name(name) && line_ends_at(script, end) do names[name] = text
		i = ok ? max(end, i + 1) : i + 1
	}
	return names
}

@(private = "file")
line_start :: proc(s: string, at: int) -> int {
	i := at
	for i > 0 && s[i - 1] != '\n' do i -= 1
	return i
}

@(private = "file")
line_ends_at :: proc(s: string, i: int) -> bool {
	j := i
	for j < len(s) && (s[j] == ' ' || s[j] == '\r') do j += 1
	return j >= len(s) || s[j] == '\n' || s[j] == ';'
}

@(private = "file")
is_name :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') do continue
		return false
	}
	return len(s) > 0
}

// One argument of a call: a string as written, or a name standing for one.
@(private = "file")
python_arg :: proc(
	s: string,
	from: int,
	names: map[string]string,
) -> (text: string, end: int, ok: bool) {
	i := from
	for i < len(s) && s[i] == ' ' do i += 1
	if i >= len(s) do return "", from, false
	if s[i] == '\'' || s[i] == '"' do return python_literal(s, i)
	j := i
	for j < len(s) && (s[j] == '_' || (s[j] >= 'a' && s[j] <= 'z') || (s[j] >= 'A' && s[j] <= 'Z') || (s[j] >= '0' && s[j] <= '9')) {
		j += 1
	}
	if j == i do return "", from, false
	found, has := names[s[i:j]]
	if !has do return "", from, false
	return found, j, true
}

// A python string, triple-quoted or not, as the text it stands for. Raw
// strings are not told apart: the difference is a backslash-n printed rather
// than a line broken, and a panel that showed the escape instead of the line
// would be showing the script rather than the change.
@(private = "file")
python_literal :: proc(s: string, at: int) -> (text: string, end: int, ok: bool) {
	i := at
	// A prefix — r, b, f — belongs to the string that follows it.
	for i < len(s) && (s[i] == 'r' || s[i] == 'b' || s[i] == 'f' || s[i] == 'R' || s[i] == 'B' || s[i] == 'F') do i += 1
	if i >= len(s) || (s[i] != '\'' && s[i] != '"') do return "", at, false
	q := s[i]
	quote := s[i:i + 1]
	if i + 2 < len(s) && s[i + 1] == q && s[i + 2] == q do quote = s[i:i + 3]
	i += len(quote)
	start := i
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 2
			continue
		}
		if strings.has_prefix(s[i:], quote) {
			return unescape(s[start:i]), i + len(quote), true
		}
		i += 1
	}
	return "", at, false
}

@(private = "file")
unescape :: proc(s: string) -> string {
	if !strings.contains_rune(s, '\\') do return s
	b := strings.builder_make(context.allocator)
	i := 0
	for i < len(s) {
		if s[i] != '\\' || i + 1 >= len(s) {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		switch s[i + 1] {
		case 'n':
			strings.write_byte(&b, '\n')
		case 't':
			strings.write_byte(&b, '\t')
		case 'r':
		case:
			strings.write_byte(&b, s[i + 1])
		}
		i += 2
	}
	return strings.to_string(b)
}

// --- the heredoc, and the paths -----------------------------------------------

// The body of the first heredoc in the command, and the line that opened it.
// `<<EOF`, `<<'EOF'`, `<<-EOF`: the tag ends the body when it is alone on a
// line, which is the rule the shell itself uses.
@(private = "file")
heredoc :: proc(cmd: string) -> (body: string, head: string, ok: bool) {
	at := strings.index(cmd, "<<")
	if at < 0 do return "", cmd, false
	i := at + 2
	if i < len(cmd) && cmd[i] == '-' do i += 1
	for i < len(cmd) && cmd[i] == ' ' do i += 1
	quote: u8 = 0
	if i < len(cmd) && (cmd[i] == '\'' || cmd[i] == '"') {
		quote = cmd[i]
		i += 1
	}
	start := i
	for i < len(cmd) && cmd[i] != '\n' && cmd[i] != quote && cmd[i] != ' ' do i += 1
	tag := cmd[start:i]
	if tag == "" do return "", cmd, false
	nl := strings.index_byte(cmd[i:], '\n')
	if nl < 0 do return "", cmd, false
	from := i + nl + 1
	rest := cmd[from:]
	end := len(rest)
	line_at := 0
	for line_at < len(rest) {
		line_end := strings.index_byte(rest[line_at:], '\n')
		line := line_end < 0 ? rest[line_at:] : rest[line_at:line_at + line_end]
		if strings.trim_space(line) == tag {
			end = line_at
			break
		}
		if line_end < 0 do break
		line_at += line_end + 1
	}
	return strings.trim_right_space(rest[:end]), cmd[:at], true
}

// The paths a piece of shell or python names. A path is a word with a slash in
// it, or a plain file name with an extension — and never a flag, a URL, or a
// pattern being searched for.
@(private = "file")
shell_paths :: proc(text: string, out: ^[dynamic]string) {
	i := 0
	for i < len(text) {
		if is_break(text[i]) {
			i += 1
			continue
		}
		start := i
		for i < len(text) && !is_break(text[i]) do i += 1
		word := text[start:i]
		if !path_like(word) do continue
		seen := false
		for p in out do if p == word do seen = true
		if !seen && len(out) < SHELL_FILES do append(out, word)
	}
}

// The last file named in a piece of script, which is the one anything after
// it is being done to.
@(private = "file")
last_path :: proc(text: string) -> string {
	found := ""
	i := 0
	for i < len(text) {
		if is_break(text[i]) {
			i += 1
			continue
		}
		start := i
		for i < len(text) && !is_break(text[i]) do i += 1
		if path_like(text[start:i]) do found = text[start:i]
	}
	return found
}

@(private = "file")
is_break :: proc(c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\t' || c == '\'' || c == '"' || c == '(' || c == ')' || c == ',' || c == ';' || c == '|' || c == '`'
}

// Whether a word names a file. A word with a slash in it does when what
// follows the last slash has an extension on it — which is what keeps the two
// halves of `s/old/new/` out of the list of files a sed command touched. A
// word without a slash does only when its extension is one this has heard of:
// `re.sub` and `s.replace` are the shape of a file name and are not one, and a
// panel that listed them as files the turn had touched would be lying about
// the one thing it is there to say.
@(private = "file")
path_like :: proc(word: string) -> bool {
	if len(word) < 3 || len(word) > 200 do return false
	if word[0] == '-' || strings.contains(word, "://") || strings.contains(word, "*") do return false
	if strings.contains(word, "=") || strings.contains(word, "..") do return false
	slash := strings.last_index_byte(word, '/')
	name := word[slash + 1:]
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 || dot >= len(name) - 1 do return false
	ext := name[dot + 1:]
	if slash >= 0 do return len(ext) <= 8
	for known in ([?]string{"odin", "md", "txt", "json", "jsonl", "sh", "py", "rs", "c", "h", "hpp", "cpp", "go", "js", "ts", "tsx", "toml", "yml", "yaml", "glsl", "vert", "frag", "log", "csv", "html", "css", "png", "lock"}) {
		if ext == known do return true
	}
	return false
}

// Whether a word appears in the command as a word of its own: `cat` is a read
// and `concat` is not, and the difference is the character either side of it.
@(private = "file")
word_in :: proc(cmd, word: string) -> bool {
	i := 0
	for {
		at := strings.index(cmd[i:], word)
		if at < 0 do return false
		j := i + at
		before := j == 0 || cmd[j - 1] == ' ' || cmd[j - 1] == '|' || cmd[j - 1] == ';' || cmd[j - 1] == '\n' || cmd[j - 1] == '('
		end := j + len(word)
		after := end >= len(cmd) || cmd[end] == ' ' || cmd[end] == '\n'
		if before && after do return true
		i = j + 1
	}
}

// What family a call is in, off the raw input of the block rather than off a
// parse of it: `tool_style` asks this for every stone of the thread on every
// frame, and json.parse_string of a Write's input — a whole file — four
// hundred times a frame is not something to do for the colour of a square.
shell_icon :: proc(input: string) -> Icon {
	return shell_family(shell_command_of(input))
}

// The command out of a tool call's input, as it is written in the JSON. Not
// unescaped, and not measured to its closing quote: what this is read for are
// markers — `> `, `sed -i`, `.write(` — an escape hides none of them, and
// walking a four-kilobyte value to find where it ends is the walk this was
// meant to avoid. The tail of the input is the tail of the command plus a
// brace or two, which no marker is.
@(private = "file")
shell_command_of :: proc(input: string) -> string {
	// The key is at the front: the input is written out with its fields in
	// order, and nothing sorts before `command` that a shell call carries.
	head := input
	if len(head) > 200 do head = head[:200]
	at_ := strings.index(head, "\"command\"")
	if at_ < 0 do return ""
	i := at_ + 9
	for i < len(head) && head[i] != '"' do i += 1
	if i >= len(head) do return ""
	return input[i + 1:]
}
