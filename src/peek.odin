package aithing

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// What a stone opens into.
//
// Every panel used to be the same panel: the tool's argument on one line, then
// its result as however many lines of grey mono fitted. That is the same
// picture for a shell command, a file read, a web page and an edit — and the
// edit is the one that suffers most, because the two strings that say what
// changed were printed as one line of JSON, if they survived at all.
//
// So a panel is built out of rows, and which rows a call turns into is decided
// by the family it belongs to — the same families the stones are coloured by
// (`tool_style`), so a tool has one answer for what it looks like and not two.
// An edit is a diff, a command is a prompt and its output, a read is a
// numbered listing, a search is its matches, a plan is its boxes. Anything the
// harness grew since is its input, field by field, and what came back.
//
// Code inside a panel is code: its lines are folded rather than cut when they
// run past the edge, its numbers sit in a column of their own, and it is
// coloured by what its characters are — a comment back, a string and a number
// apart from the words. None of that knows a language; it does not have to.
// What it is for is that a screenful of output stops reading as one grey wall,
// which is what the output of a grep through a file of long lines was.
//
// The rows are derived, never stored: `peek_rows` rebuilds the list from the
// block every time it is asked, and both the measure (how tall the panel is,
// how far the wheel may go) and the drawing read that one list. They used to
// count the result's lines separately, one in `peek_layout` and one in
// `draw_peek`, which is two opinions about how tall a panel is.

PEEK_W :: f32(560) // the reading column: as wide as a panel of prose opens
PEEK_CODE_W :: f32(760) // and as wide as one full of code may grow
PEEK_MAX :: f32(470) // how tall an opened tile is allowed to get: the rest scrolls
PEEK_LINES :: 400 // the most rows a panel will ever lay out
PEEK_HEAD :: f32(32)
// A panel holding a picture is sized by the picture, not by the reading
// column: the most of the view it may take, across and down.
PEEK_PIC_W :: f32(0.62)
PEEK_PIC_H :: f32(0.72)

PEEK_PX :: f32(13) // mono, inside a panel: denser than the transcript's
PEEK_TX :: f32(13.5) // prose, inside a panel
PEEK_LH :: f32(19)
PEEK_GUT :: f32(38) // the line-number column
PEEK_SIGN :: f32(16) // the + / - column of a diff
DIFF_CTX :: 2 // lines either side of a change, for bearings
CODE_FOLDS :: 3 // how many times one line of code may be folded to fit
CODE_STEP :: 2 // characters a fold indents by, per bracket it is inside
ROW_CONT :: -1 // `num` on the rest of a line that was folded to fit
DIFF_MAX :: 220 // lines of one edit, before the rest is left to the file

// A row of an open panel. `num` is the line's number in the file it came from,
// which only a listing has, or ROW_CONT when the row is the rest of a line
// that would not fit on one; `col` is only ever set by the rows that carry a
// state of their own, and everything else takes its colour from its kind.
Row :: struct {
	kind: Row_Kind,
	text: string,
	num:  int,
	// How far in this row starts, in characters: what the line it was folded
	// off was indented by, plus the brackets it is still inside. Nought on a
	// row that is a whole line of the file.
	ind:  int,
	col:  Color,
}

Row_Kind :: enum {
	Head, // a label over a section, with a rule running off it
	Note, // prose, already wrapped to the panel
	Mono, // a line of code or output
	Cmd, // a line of the command that was run
	Add, // a line the edit puts in
	Del, // a line the edit takes out
	Same, // a line either side of the change, for bearings
	Skip, // where a run of unchanged lines was left out
	Path, // a file the tool found or touched
	Check, // one item of a plan, with its box
	Gap, // a blank line that means something
}

row_h :: proc(kind: Row_Kind) -> f32 {
	switch kind {
	case .Head:
		return 26
	case .Check:
		return 23
	case .Skip:
		return 17
	case .Gap:
		return 9
	case .Note, .Mono, .Cmd, .Add, .Del, .Same, .Path:
		return PEEK_LH
	}
	return PEEK_LH
}

// --- building the rows --------------------------------------------------------

// What this call turns into, in rows. `inner` is the width the panel has for
// text; what each kind of row does with it — how far in it starts, how much of
// it a fold leaves — is the row's own business.
peek_rows :: proc(app: ^App, b: ^Block, inner: f32) -> []Row {
	rows := &app.rows
	clear(rows)
	if b.kind != .Tool do return rows[:]

	// One parse for the whole panel. A call still being typed does not parse
	// at all, which is not a failure — there is simply nothing to take apart
	// yet, and the result section below still has whatever came back.
	input, err := json.parse_string(strings.to_string(b.input), .JSON, false, context.temp_allocator)
	if err != nil do input = nil

	_, icon := tool_style(b.name, strings.to_string(b.input))
	// A shell call is drawn from what the command does rather than from the
	// tool's name: the panel for `python3 - <<EOF ... EOF` that rewrites a
	// file is a diff, the same as the edit tool's, because that is what
	// happened. See shell.odin.
	from := 0
	if cmd := jstr(input, "command"); cmd != "" {
		from = rows_shell(app, input, cmd, inner)
	} else do switch icon {
	case .Edit:
		rows_edit(app, input, inner)
	case .Run:
		rows_run(app, input, inner)
	case .Read:
		rows_read(app, b, input, inner)
	case .Find:
		rows_find(app, b, input, inner)
	case .Web, .Agent:
		rows_prose(app, input, inner)
	case .Plan:
		rows_plan(app, input, inner)
	case .You, .Said, .Answer, .Error, .Image, .Tool:
		rows_any(app, input, inner)
	}
	rows_result(app, b, inner, icon, from)
	return rows[:]
}

// An edit, as a diff. Write has no old side and Edit has both; either way the
// two strings are one hunk by construction, so the matching run at each end is
// trimmed off and what is left is the change. It is not a longest-common-
// subsequence: walking the whole of both sides to discover what the tool
// already told us is slower and says the same thing.
@(private = "file")
rows_edit :: proc(app: ^App, input: json.Value, inner: f32) {
	old := jstr(input, "old_string")
	new := jstr(input, "new_string")
	if new == "" do new = jstr(input, "content")
	if new == "" do new = jstr(input, "new_source")
	if old == "" do old = jstr(input, "old_source")
	if old == "" && new == "" {
		rows_any(app, input, inner)
		return
	}

	a := split_lines(old)
	c := split_lines(new)
	head := 0
	for head < len(a) && head < len(c) && a[head] == c[head] do head += 1
	tail := 0
	for tail < len(a) - head && tail < len(c) - head && a[len(a) - 1 - tail] == c[len(c) - 1 - tail] {
		tail += 1
	}

	row_head(app, old == "" ? "written" : "changed")
	rows_diff(app, old, new, inner - PEEK_SIGN - 14)
}

// The diff itself: what one string has that the other has not. Its own proc
// because an edit is not the only thing that makes one — a shell command that
// swaps a string for another has exactly the same news to give, and giving it
// twice in two shapes is how the two would come to disagree.
@(private = "file")
rows_diff :: proc(app: ^App, old, new: string, width: f32) {
	a := split_lines(old)
	c := split_lines(new)
	head := 0
	for head < len(a) && head < len(c) && a[head] == c[head] do head += 1
	tail := 0
	for tail < len(a) - head && tail < len(c) - head && a[len(a) - 1 - tail] == c[len(c) - 1 - tail] {
		tail += 1
	}
	// Two lines of what was already there, so a change has somewhere to sit.
	// The rest of a matching run is a count rather than a screenful of lines
	// that did not change.
	if head > DIFF_CTX do row_skip(app, head - DIFF_CTX)
	for i in max(head - DIFF_CTX, 0) ..< head do row_code(app, .Same, a[i], 0, width)
	n := 0
	for i in head ..< len(a) - tail {
		if n >= DIFF_MAX do break
		row_code(app, .Del, a[i], 0, width)
		n += 1
	}
	n = 0
	for i in head ..< len(c) - tail {
		if n >= DIFF_MAX do break
		row_code(app, .Add, c[i], 0, width)
		n += 1
	}
	end := len(a) - tail
	for i in end ..< min(end + DIFF_CTX, len(a)) do row_code(app, .Same, a[i], 0, width)
	if tail > DIFF_CTX do row_skip(app, tail - DIFF_CTX)
}

// A shell call, in the order the news comes: what it was for, what it changed,
// which files it named, and then the command itself — always the command,
// because it is what actually ran and the reading of it above is a reading.
// Gives back the line its output starts at, when that is knowable.
@(private = "file")
rows_shell :: proc(app: ^App, input: json.Value, cmd: string, inner: f32) -> int {
	sh := shell_read(cmd)
	if d := jstr(input, "description"); d != "" do row_wrap(app, d, inner, 3)
	// The files it named, minus the ones that head a diff of their own below:
	// a script that changes one file would otherwise list it and then repeat
	// it as the heading of the only hunk on the panel.
	listed := 0
	for f in sh.files {
		changed := false
		for swap in sh.swaps do if swap.file == f do changed = true
		if changed do continue
		if listed == 0 do row_head(app, sh.family == .Edit ? "files" : "read")
		append(&app.rows, Row{kind = .Path, text = f})
		listed += 1
	}
	// Each change under the name of the file it was made to, rather than all
	// of them under one `changed`: a script that walks three files in a row is
	// three diffs, and which file a hunk belongs to is the first thing to know
	// about it.
	for swap, i in sh.swaps {
		if i >= SHELL_SWAPS do break
		row_head(app, swap.file != "" ? swap.file : swap.old == "" ? "written" : "changed")
		rows_diff(app, swap.old, swap.new, inner - PEEK_SIGN - 14)
	}
	row_head(app, "command")
	rows_cmd(app, cmd, inner)
	return sh.from
}

// A command and what it printed.// A command and what it printed. The command comes first and in full — it is
// the one line of a shell tool worth reading twice — and the description the
// model wrote for it goes above, because that is what it is for.
@(private = "file")
rows_run :: proc(app: ^App, input: json.Value, inner: f32) {
	if d := jstr(input, "description"); d != "" do row_wrap(app, d, inner, 3)
	cmd := jstr(input, "command")
	if cmd == "" do cmd = jstr(input, "cmd")
	if cmd == "" {
		rows_any(app, input, inner)
		return
	}
	row_head(app, "command")
	rows_cmd(app, cmd, inner)
}

// The command, on the ground a terminal gives it. Only the first line carries
// the prompt: a heredoc is one command however many lines it is fed, and a
// chevron against every line of the script inside it says nine commands ran.
@(private = "file")
rows_cmd :: proc(app: ^App, cmd: string, inner: f32) {
	for l, i in split_lines(cmd) {
		if i >= 40 do break
		row_code(app, .Cmd, l, i == 0 ? 0 : ROW_CONT, inner - PEEK_SIGN - 14)
	}
}

// A file, as a listing. The harness numbers the lines it hands back — a
// number, an arrow, the line — so the numbers go in a column of their own and
// the code lines up beside them rather than being pushed along by how wide the
// numbers happened to be.
@(private = "file")
rows_read :: proc(app: ^App, b: ^Block, input: json.Value, inner: f32) {
	// Which part of the file was asked for, when it was not the whole of it.
	// The path itself is in the head; saying it twice is the panel repeating
	// itself before it has said anything.
	off, has_off := jobj(input, "offset")
	lim, has_lim := jobj(input, "limit")
	if !has_off && !has_lim do return
	// Prose rather than code, so it stands outside the column the numbered
	// lines below it are lined up in.
	from := has_off ? fmt.tprintf("from line %v", off) : "from the top"
	row_line(app, .Note, has_lim ? fmt.tprintf("%s, %v lines", from, lim) : from)
}

// What a search found. A grep prints `path:line:text` and a glob prints paths,
// and both read better as a list of places than as a wall of output — so a
// line that names a place is drawn as one.
@(private = "file")
rows_find :: proc(app: ^App, b: ^Block, input: json.Value, inner: f32) {
	for key in ([?]string{"path", "glob", "output_mode", "type"}) {
		if v := jstr(input, key); v != "" {
			row_line(app, .Mono, fmt.tprintf("%s: %s", key, v))
		}
	}
}

// A prompt, or a page. Prose either way, so it is wrapped and read rather
// than cut at the panel's edge like code.
@(private = "file")
rows_prose :: proc(app: ^App, input: json.Value, inner: f32) {
	if d := jstr(input, "description"); d != "" {
		row_head(app, "about")
		row_wrap(app, d, inner, 4)
	}
	for key in ([?]string{"url", "query", "prompt"}) {
		if v := jstr(input, key); v != "" {
			row_head(app, key)
			if key == "url" do row_line(app, .Mono, v)
			else do row_wrap(app, v, inner, 60)
		}
	}
}

// A plan: its items with their boxes, ticked or not, in the colour of what
// they are doing. A list of things to do drawn as a paragraph of JSON is the
// one shape this program exists to be the opposite of.
@(private = "file")
rows_plan :: proc(app: ^App, input: json.Value, inner: f32) {
	todos, is_arr := jarr(input, "todos")
	if !is_arr {
		rows_any(app, input, inner)
		return
	}
	row_head(app, "plan")
	for item in todos {
		text := jstr(item, "content")
		if text == "" do text = jstr(item, "activeForm")
		if text == "" do continue
		// What the item is doing goes in `num`: nothing, in hand, done. The
		// box is drawn from it, so a plan says which one is being worked on
		// rather than only which ones are finished.
		col, doing := FAINT, 0
		switch jstr(item, "status") {
		case "completed":
			col, doing = GREEN, 2
		case "in_progress":
			col, doing = AMBER, 1
		}
		append(&app.rows, Row{kind = .Check, text = text, col = col, num = doing})
	}
}

// A tool this build has never heard of, said as it was called: every field of
// its input, in a fixed order, with the long ones wrapped. It used to be one
// line of half-escaped JSON, which is the same amount of information arranged
// so that none of it can be read.
@(private = "file")
rows_any :: proc(app: ^App, input: json.Value, inner: f32) {
	obj, is_obj := input.(json.Object)
	if !is_obj do return
	keys := make([dynamic]string, context.temp_allocator)
	for k in obj do append(&keys, k)
	// A map has no order of its own, and a panel whose fields moved about
	// between frames would be unreadable.
	slice.sort(keys[:])
	for k in keys {
		v := obj[k]
		switch t in v {
		case json.String:
			row_head(app, k)
			if strings.contains_rune(string(t), '\n') || f32(len(t)) * PEEK_PX * 0.55 > inner {
				row_wrap(app, string(t), inner, 24)
			} else {
				row_line(app, .Mono, string(t))
			}
		case json.Integer:
			row_line(app, .Mono, fmt.tprintf("%s: %d", k, t))
		case json.Float:
			row_line(app, .Mono, fmt.tprintf("%s: %v", k, t))
		case json.Boolean:
			row_line(app, .Mono, fmt.tprintf("%s: %v", k, t))
		case json.Null:
		case json.Array:
			row_line(app, .Mono, fmt.tprintf("%s: %d items", k, len(t)))
		case json.Object:
			row_line(app, .Mono, fmt.tprintf("%s: %d fields", k, len(t)))
		}
	}
}

// What came back. Every panel ends with it, and what it is called depends on
// what asked: a command prints output, everything else gets a result.
@(private = "file")
rows_result :: proc(app: ^App, b: ^Block, inner: f32, icon: Icon, from: int) {
	result := strings.trim_space(strings.to_string(b.result))
	if len(result) > RESULT_BYTES do result = result[:RESULT_BYTES]
	if result == "" {
		if b.running do row_head(app, "running")
		return
	}
	row_head(app, icon == .Run ? "output" : icon == .Read ? "file" : icon == .Find ? "matches" : "result")
	// A page and a subagent's report are prose; everything else is output,
	// and output is code — cut at the edge, not folded round it.
	if icon == .Web || icon == .Agent {
		row_wrap(app, result, inner, PEEK_LINES)
		return
	}
	// Whether this output is numbered is one answer for the whole of it, not
	// one per line: the numbers get a column, and a column that some lines
	// stood in and others did not would be a listing with a ragged edge. It
	// is also what the lines are folded against, so the fold and the column
	// agree about where the text starts.
	numbered := output_numbered(result)
	// A file printed by a command comes back with no numbers on it at all —
	// `cat` does not number and neither does `sed -n`. The command says where
	// it started reading, so the panel can count from there. It counts from
	// nowhere rather than from one when the command did not say: a listing
	// numbered from one when it began at line 120 is a hundred and nineteen
	// wrong answers.
	count := numbered ? 0 : from
	width := inner - (numbered || count > 0 ? PEEK_GUT : 0) - 14
	it := each_line(result)
	for l in iter_next(&it) {
		if len(app.rows) >= PEEK_LINES do break
		if icon == .Find && line_is_place(l) {
			num, rest, ok := placed_line(l)
			append(&app.rows, Row{kind = .Path, text = ok ? rest : l, num = ok ? num : 0})
			continue
		}
		if numbered {
			// `   126→` off a file, `1234:` off a grep: the number belongs in
			// the column and the arrow is scaffolding. It used to be lifted
			// out for a Read and left in the text for everything else, so the
			// output of a grep was a wall whose left-hand twelve characters
			// were the same digits in a different place on every line.
			if num, rest, ok := numbered_line(l); ok {
				row_code(app, .Mono, rest, num, width)
				continue
			}
		}
		if count > 0 {
			row_code(app, .Mono, l, count, width)
			count += 1
			continue
		}
		row_code(app, .Mono, l, 0, width)
	}
}

// --- the small pieces the builders are made of --------------------------------

@(private = "file")
row_head :: proc(app: ^App, label: string) {
	if len(app.rows) > 0 do append(&app.rows, Row{kind = .Gap})
	append(&app.rows, Row{kind = .Head, text = label})
}

@(private = "file")
row_line :: proc(app: ^App, kind: Row_Kind, text: string) {
	if len(app.rows) >= PEEK_LINES do return
	append(&app.rows, Row{kind = kind, text = text})
}

// A line of code, as however many rows the panel is wide enough for. It used
// to be cut at the edge with an ellipsis, which for the output of a grep — one
// long line per match, the interesting half of it past the sixtieth character
// — threw away the part that was being looked for. It folds instead, at a
// space when there is one near the cut, and what is folded off carries
// ROW_CONT rather than a number of its own, so a listing's numbers still count
// lines of the file and not rows of the panel.
@(private = "file")
row_code :: proc(app: ^App, kind: Row_Kind, text: string, num: int, width: f32) {
	ui := &app.ui
	rest := tabbed(text)
	// What the line itself was indented by, so the parts of it that come
	// after the fold line up under it rather than under the panel's edge.
	lead := 0
	for lead < len(rest) && rest[lead] == ' ' do lead += 1
	n, ind, depth := num, 0, 0
	for _ in 0 ..< CODE_FOLDS {
		cut := code_fit(ui, rest, width - char_w(ui) * f32(ind))
		if cut >= len(rest) do break
		emit_code(app, kind, rest[:cut], n, ind)
		depth = code_depth(rest[:cut], depth)
		rest = rest[cut:]
		for len(rest) > 0 && rest[0] == ' ' do rest = rest[1:]
		n, ind = ROW_CONT, lead + CODE_STEP * depth
		if len(app.rows) >= PEEK_LINES do return
	}
	emit_code(app, kind, rest, n, ind)
}

@(private = "file")
emit_code :: proc(app: ^App, kind: Row_Kind, text: string, num, ind: int) {
	row_line(app, kind, text)
	if len(app.rows) == 0 do return
	r := &app.rows[len(app.rows) - 1]
	r.num, r.ind = num, ind
}

@(private = "file")
char_w :: proc(ui: ^UI) -> f32 {
	return font_width(&ui.mono, " ", PEEK_PX)
}

// How much of a line fits in `width`, in bytes. A fold lands after the last
// space when one is close to the edge and mid-word when there is none, which
// is what a path or a run of punctuation gets.
@(private = "file")
code_fit :: proc(ui: ^UI, text: string, width: f32) -> int {
	if width < 60 do return len(text)
	w := f32(0)
	i, joint, gap := 0, -1, -1
	for i < len(text) {
		end, kind := code_token(text, i)
		tw := font_width(&ui.mono, text[i:end], PEEK_PX)
		if w + tw > width && i > 0 {
			if joint > 0 do return joint
			if gap > 0 do return gap
			return i
		}
		// Where the code would come apart if it had been written over several
		// lines: after a brace, a semicolon, a comma, a pipe. Cutting there
		// and indenting what follows is the whole of the formatting this
		// does — it reads a dense one-liner back as the lines somebody would
		// have typed, without knowing one language from another, and without
		// touching a line that fits.
		if kind == .Punct && i > 0 && is_joint(text[i:end]) do joint = end
		if kind == .Plain && text[i] == ' ' do gap = end
		w += tw
		i = end
	}
	return len(text)
}

@(private = "file")
is_joint :: proc(run: string) -> bool {
	for i in 0 ..< len(run) {
		switch run[i] {
		case '{', '}', ';', ',', '|', '&', '(':
			return true
		}
	}
	return false
}

// How deep in brackets a piece of a line leaves off, so what follows it is
// indented by what it is inside. Read off the same token walk the colouring
// uses, so a brace in a string or behind a comment is not counted — which is
// what made the first go at this indent a shell line by the `{` in an awk
// program it was passing along.
@(private = "file")
code_depth :: proc(text: string, from: int) -> int {
	depth := from
	i := 0
	for i < len(text) {
		end, kind := code_token(text, i)
		if kind == .Punct {
			for c in text[i:end] {
				switch c {
				case '{', '(', '[':
					depth += 1
				case '}', ')', ']':
					depth -= 1
				}
			}
		}
		i = end
	}
	return max(depth, 0)
}

// Whether a block of output has its lines numbered — a file read back, or a
// grep that was asked for line numbers. Decided off the first few lines: a
// listing says so immediately, and a run of output that happens to have a
// number on its ninetieth line is not a listing.
@(private = "file")
output_numbered :: proc(result: string) -> bool {
	seen, hit := 0, 0
	it := each_line(result)
	for l in iter_next(&it) {
		if strings.trim_space(l) == "" do continue
		if _, _, ok := numbered_line(l); ok do hit += 1
		seen += 1
		if seen >= 4 do break
	}
	return seen > 0 && hit * 2 > seen
}

@(private = "file")
row_skip :: proc(app: ^App, lines: int) {
	append(&app.rows, Row{kind = .Skip, text = fmt.tprintf("%d unchanged", lines)})
}

// Prose, wrapped to the panel. Greedy, and a word longer than the line is left
// to be cut when it is drawn — a path or a URL broken across two lines is
// harder to read than one that runs off the edge.
@(private = "file")
row_wrap :: proc(app: ^App, text: string, width: f32, limit: int) {
	ui := &app.ui
	drawn := 0
	para := each_line(text)
	for line in iter_next(&para) {
		if drawn >= limit do break
		if strings.trim_space(line) == "" {
			append(&app.rows, Row{kind = .Gap})
			continue
		}
		start := 0
		last := -1
		w := f32(0)
		i := 0
		// A rune at a time, and back to where the cut was made rather than on
		// from where it was found: measuring on from `i` after cutting at the
		// space behind it charges the next line for none of the word it
		// begins with, and a line and a half of prose then runs off the edge.
		for i < len(line) {
			r, size := utf8.decode_rune_in_string(line[i:])
			if r == ' ' do last = i
			w += font_width(&ui.regular, line[i:i + size], PEEK_TX)
			if w > width && i > start {
				cut := last > start ? last : i
				row_line(app, .Note, line[start:cut])
				drawn += 1
				if drawn >= limit do break
				start = cut
				for start < len(line) && line[start] == ' ' do start += 1
				last = -1
				w = 0
				i = start
				continue
			}
			i += size
		}
		if start < len(line) && drawn < limit {
			row_line(app, .Note, line[start:])
			drawn += 1
		}
	}
}

@(private = "file")
split_lines :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if s == "" do return out[:]
	it := each_line(s)
	for l in iter_next(&it) do append(&out, l)
	return out[:]
}

// `   126→\tc := &app.canvas` — the shape the harness hands a file back in.
// The number belongs in a column of its own; the arrow is scaffolding.
@(private = "file")
numbered_line :: proc(line: string) -> (num: int, rest: string, ok: bool) {
	i := 0
	for i < len(line) && line[i] == ' ' do i += 1
	start := i
	for i < len(line) && line[i] >= '0' && line[i] <= '9' {
		num = num * 10 + int(line[i] - '0')
		i += 1
	}
	if i == start do return 0, line, false
	ARROW :: "→"
	switch {
	case strings.has_prefix(line[i:], ARROW):
		i += len(ARROW)
	case i < len(line) && (line[i] == '\t' || line[i] == ':' || line[i] == '|'):
		i += 1
	case:
		return 0, line, false
	}
	return num, line[i:], true
}

// Whether a line of output names a place in the tree rather than being one
// more line of text that happens to have come back.
@(private = "file")
line_is_place :: proc(line: string) -> bool {
	if line == "" || len(line) > 300 do return false
	return strings.contains_rune(line, '/') && !strings.contains_rune(line, ' ')
}

// `src/canvas.odin:126` — the path and the line in it, apart.
@(private = "file")
placed_line :: proc(line: string) -> (num: int, rest: string, ok: bool) {
	at := strings.last_index_byte(line, ':')
	if at <= 0 || at == len(line) - 1 do return 0, line, false
	for i in at + 1 ..< len(line) {
		c := line[i]
		if c < '0' || c > '9' do return 0, line, false
		num = num * 10 + int(c - '0')
	}
	return num, line[:at], true
}

// --- what the pointer opens ---------------------------------------------------

// Where a stone's panel goes and how much it is holding: the one set of
// numbers the wheel, the frame and the text inside it all read.
Peek :: struct {
	ok:     bool,
	tall:   bool, // more than fits: the wheel has something to do
	tile:   Tile,
	stone:  Rect, // the stone, on screen
	box:    Rect, // the panel, on screen
	body_h: f32, // the content under the head, before any is cut off
	img_h:  f32,
	// The width the rows were folded against. Carried rather than worked out
	// again, because the panel's own width is decided from the rows and
	// folding them a second time against that answer would fold them
	// differently — the measure and the drawing have to be looking at the
	// same list.
	rows_w: f32,
	pic:    string, // the picture it is holding, if it is holding one
}

peek_layout :: proc(app: ^App, ref: Ref, view: Rect, top: f32) -> (p: Peek) {
	ui := &app.ui
	b := chat_block(&app.chat, ref)
	if b == nil do return
	found := false
	for t in app.snake do if t.ref == ref {
		p.tile = t
		found = true
		break
	}
	if !found do return

	avail := view.w - PAD * 2
	w := min(PEEK_W, avail)
	inner := w - 28

	// How tall it wants to be, which is the one number the frame and its
	// contents have to agree on. What does not fit under PEEK_MAX is not
	// thrown away any more: it scrolls, so a long result is read by turning
	// the wheel over the stone rather than opening the transcript elsewhere.
	// A picture is the exception, and it is why the width is worked out here
	// rather than fixed above: the panel used to be PEEK_W wide whatever it
	// held, which printed a screenshot the width of a reading column in the
	// middle of a 4K window — fine as a thumbnail, useless as the thing it
	// is a picture of. So a picture is fitted to the view, whole, and the
	// panel is whatever width that came out as.
	p.pic = block_picture(b)
	limit := PEEK_MAX
	if p.pic != "" {
		img := app_preview(app, p.pic)
		aspect := img.width > 0 && img.height > 0 ? f32(img.height) / f32(img.width) : 0.62
		max_w := min(avail, view.w * PEEK_PIC_W) - 28
		max_h := min(view.h - 20 - PEEK_HEAD - 14, view.h * PEEK_PIC_H)
		inner = max(min(max_w, max_h / aspect), 1)
		w = inner + 28
		p.img_h = inner * aspect
		p.body_h = p.img_h
		limit = p.img_h
	} else do switch b.kind {
	case .Image:
	case .Text, .Error:
		md_layout(ui, b, inner)
		p.body_h = b.height
	case .Tool:
		// A panel of prose is a reading column and stops there. A panel of
		// code is not reading matter: a line of it folded is a line cut in
		// two, and 560 pixels of mono is about sixty characters, which is
		// half of most lines this program has ever printed. So the rows are
		// folded against the widest a panel may be, and then the panel is
		// made as wide as the widest row that came out — a short command's
		// output still opens at the reading column, and a grep through a file
		// of long lines opens wide enough to read them.
		prose := p.tile.icon == .Web || p.tile.icon == .Agent
		p.rows_w = (prose ? min(PEEK_W, avail) : min(PEEK_CODE_W, avail)) - 28
		rows := peek_rows(app, b, p.rows_w)
		for row in rows do p.body_h += row_h(row.kind)
		if p.body_h == 0 do p.body_h = 22
		if !prose {
			gut := rows_gut(rows)
			widest := f32(0)
			for row in rows do widest = max(widest, row_width(ui, row, gut))
			// The row's own width and a little over: a panel exactly as wide
			// as its widest row has no slack in it, and the last word of that
			// row came out with an ellipsis after it because the sum of the
			// pieces landed a hair past the edge.
			w = clamp(widest + 34, min(PEEK_W, avail), min(PEEK_CODE_W, avail))
			inner = w - 28
		}
	}
	h := PEEK_HEAD + 14 + min(p.body_h, limit)
	p.tall = p.body_h > limit

	p.stone = Rect{p.tile.r.x, p.tile.r.y + top, p.tile.r.w, p.tile.r.h}
	x := clamp(p.stone.x + p.stone.w / 2 - w / 2, view.x + PAD, view.x + view.w - PAD - w)
	// Below the stone if there is room for it there, above it if there is not.
	y := p.stone.y + p.stone.h + 12
	if y + h > view.y + view.h - 8 do y = p.stone.y - h - 12
	y = clamp(y, view.y + 6, max(view.y + view.h - h - 6, view.y + 6))
	p.box = Rect{x, y, w, h}
	p.ok = true
	return
}

// What a stone is holding, at reading size: the paragraph, the picture, the
// call and what it gave back. It opens beside the tile and is drawn last, over
// everything, so it is never the thing that gets cut off.
draw_peek :: proc(app: ^App, p: Peek) {
	ui := &app.ui
	b := chat_block(&app.chat, p.tile.ref)
	if b == nil do return
	tile := p.tile
	box := p.box
	inner := box.w - 28
	body := strings.trim_space(block_text(b))

	// It grows out of the stone it belongs to, on the spring the stone
	// ticks for it, and lands a shade too big. Only the drawing scales; the
	// panel takes no clicks, so nothing is hit anywhere but where it is.
	// Not while the thread itself is still zooming in — one zoom at a time.
	grow := clamp(ui.anim[ui_id_ptr(b) + 3].pos, 0, 1.3)
	zoomed := ui.zoom == 1
	if zoomed {
		sc := 0.82 + 0.18 * grow
		ax, ay := p.stone.x + p.stone.w / 2, p.stone.y + p.stone.h / 2
		ui_push_zoom(ui, sc, {ax * (1 - sc), ay * (1 - sc)})
	}
	defer if zoomed do ui_pop_zoom(ui)

	// The same ground the composer stands on: cut out of the window, so what
	// is behind it is the desktop rather than the path it is covering.
	ui_punch(ui, box, COMPOSER_BG, 10)
	// A wash of the stone's own colour over it, not a coat of it: at half
	// alpha the panel came out the colour of the tool and the text on it had
	// to fight the tint it was printed on.
	ui_rect(ui, box, color_alpha(tile.col, 0.14), 10)

	rows := b.kind == .Tool && p.pic == "" ? peek_rows(app, b, p.rows_w) : nil
	draw_peek_head(app, p, rows)

	// The text under the head scrolls, and the wheel reaches it from the
	// stone as well as from the panel, because the pointer resting on the
	// stone is what has the panel open. A panel for a different stone starts
	// at the top: the scroll is one number, and it belongs to whichever
	// panel is up, so the change of owner is what resets it.
	body_box := Rect{box.x, box.y + PEEK_HEAD, box.w, box.h - PEEK_HEAD - 8}
	if ui_changed(ui, ui_id("peek-of"), f32(ui_id_ptr(b) & 0xffff)) do app.peek = {}
	ui_begin_scroll(ui, body_box, &app.peek, p.body_h + 8, p.stone)
	iy := body_box.y - app.peek.offset
	ix := box.x + 14
	if p.pic != "" {
		ui_image(ui, {ix, iy, inner, p.img_h}, app_preview(app, p.pic).tex, 6)
	} else do switch b.kind {
	case .Image:
	case .Text, .Error:
		ui_hover_text(ui, box, body)
		col := b.kind == .Error ? RED : TEXT
		for l in b.lines {
			if iy > box.y + box.h do break
			iy += md_draw_line(ui, l, ix, iy, inner, col, MUTED)
		}
	case .Tool:
		ui_hover_text(ui, box, tool_hover(b))
		gut := rows_gut(rows)
		for row in rows {
			h := row_h(row.kind)
			if iy > box.y + box.h do break
			if iy + h >= body_box.y do draw_row(app, row, {ix, iy, inner, h}, box, gut)
			iy += h
		}
		if len(rows) == 0 {
			ui_text(ui, &ui.regular, "nothing back", {ix, iy}, 13, FAINT)
		}
	}
	ui_end_scroll(ui, body_box, &app.peek)
	// A shade over whichever edge has more past it, so a panel that has been
	// cut off does not read as the end of what it holds.
	if p.tall && app.peek.offset > 1 {
		ui_rect(ui, {box.x, body_box.y, box.w, 18}, color_alpha(COMPOSER_BG, 0.5), 0)
	}
	if p.tall && app.peek.offset < app.peek.content - body_box.h - 1 {
		ui_rect(ui, {box.x, box.y + box.h - 26, box.w, 18}, color_alpha(COMPOSER_BG, 0.5), 0)
	}
}

// The head: the stone's own mark again, the tool's name, what it was called
// with, and — for an edit — how much of the file it moved. The panel says what
// it belongs to so the path underneath does not have to carry the words.
@(private = "file")
draw_peek_head :: proc(app: ^App, p: Peek, rows: []Row) {
	ui := &app.ui
	box := p.box
	tile := p.tile
	draw_icon(ui, tile.icon, {box.x + 8, box.y + 6, 20, 20}, tile.col, COMPOSER_BG)
	x := box.x + 34
	x += ui_text(ui, &ui.mono, tile.name, {box.x + 34, box.y + 9}, 12.5, tile.col)

	// The counts sit at the right end of the head, where they are the first
	// thing read of an edit: how many lines it puts in and how many it takes
	// out, counted off the rows themselves rather than kept beside them.
	right := box.x + box.w - 12
	adds, dels := 0, 0
	for row in rows {
		// Lines of the file, not rows of the panel: a line too long to sit on
		// one row is folded onto two, and counting rows made an edit that put
		// eight lines in say it had put nine.
		if row.num == ROW_CONT do continue
		if row.kind == .Add do adds += 1
		if row.kind == .Del do dels += 1
	}
	if dels > 0 {
		text := fmt.tprintf("-%d", dels)
		right -= font_width(&ui.mono, text, 12)
		ui_text(ui, &ui.mono, text, {right, box.y + 9}, 12, RED)
		right -= 8
	}
	if adds > 0 {
		text := fmt.tprintf("+%d", adds)
		right -= font_width(&ui.mono, text, 12)
		ui_text(ui, &ui.mono, text, {right, box.y + 9}, 12, GREEN)
		right -= 8
	}

	// Whatever the call was about, beside the name and out of the way of the
	// counts. The block is the one copy of the input; this is worked out from
	// it every frame rather than kept on the block.
	//
	// Not when the panel below is already showing it: a command, a URL and a
	// subagent's prompt are the body of those panels, and the head printed the
	// first hundred characters of the same string directly above them.
	if arg := head_arg(&app.chat, tile, rows); arg != "" {
		buf: [512]u8
		room := right - x - 10
		if room > 40 {
			text := font_ellipsize(&ui.mono, one_line(arg, 300), 12, room, buf[:])
			ui_text(ui, &ui.mono, text, {x + 10, box.y + 9}, 12, color_alpha(MUTED, 0.9))
		}
	}
	ui_rect(ui, {box.x + 10, box.y + PEEK_HEAD - 5, box.w - 20, 1}, color_alpha(tile.col, 0.18), 0)
}

// What the head says a call was about, which is nothing when the panel below
// leads with the same string.
@(private = "file")
head_arg :: proc(chat: ^Chat, tile: Tile, rows: []Row) -> string {
	b := chat_block(chat, tile.ref)
	if b == nil do return ""
	// The command, the URL and a subagent's prompt are the body of those
	// panels: the head used to print the first hundred characters of the same
	// string directly above them. Asked of the rows rather than of the tool,
	// so a shell call that opens as a diff still keeps its command out of the
	// head — the command is down there under its own label.
	for row in rows do if row.kind == .Cmd do return ""
	if b.kind == .Tool {
		#partial switch tile.icon {
		case .Web, .Agent:
			return ""
		}
	}
	return block_arg(b)
}

// One row, in the shape its kind asks for. `r` is where the text goes; `box`
// is the panel, because the rows that carry a colour of their own — a line put
// in, a line taken out — are washed across the whole of it, which is what makes
// a diff read as a diff rather than as text with green in it.
@(private = "file")
draw_row :: proc(app: ^App, row: Row, r: Rect, box: Rect, gut: f32) {
	ui := &app.ui
	buf: [1024]u8
	mono := &ui.mono

	switch row.kind {
	case .Gap:

	case .Head:
		y := r.y + 8
		w := ui_text(ui, &ui.bold, row.text, {r.x, y}, 11, color_alpha(MUTED, 0.95))
		line := r.x + w + 8
		ui_rect(ui, {line, y + 6, max(box.x + box.w - 14 - line, 0), 1}, color_alpha(BORDER, 0.7), 0)

	case .Note:
		ui_text(ui, &ui.regular, row.text, {r.x, r.y + 2}, PEEK_TX, color_mix(TEXT, MUTED, 0.25))

	case .Mono:
		x := r.x
		if row.num > 0 {
			num := fmt.tprintf("%d", row.num)
			ui_text(ui, mono, num, {x + gut - 8 - font_width(mono, num, PEEK_PX), r.y + 2}, PEEK_PX, color_alpha(FAINT, 0.9))
		}
		x += gut + fold_in(ui, row)
		draw_code(ui, row.text, x, r.y + 2, box.x + box.w - 14, color_mix(CODE_TEXT, MUTED, 0.3), MUTED, 0)

	case .Cmd:
		// A shell line, on the ground a terminal gives it, with the prompt
		// drawn rather than typed: a `$` in the text would be a character the
		// command does not have, and copying the panel would hand it back.
		ui_rect(ui, {box.x + 10, r.y, box.w - 20, r.h}, color_alpha(CODE_BG, 0.5), 0)
		if row.num != ROW_CONT {
			ui_line(ui, {r.x + 4, r.y + 5}, {r.x + 10, r.y + r.h / 2}, 2, color_alpha(GREEN, 0.9))
			ui_line(ui, {r.x + 10, r.y + r.h / 2}, {r.x + 4, r.y + r.h - 5}, 2, color_alpha(GREEN, 0.9))
		}
		x := r.x + PEEK_SIGN + 4 + fold_in(ui, row)
		draw_code(ui, row.text, x, r.y + 2, box.x + box.w - 14, color_mix(TEXT, CODE_TEXT, 0.4), MUTED, 0)

	case .Add, .Del:
		put := row.kind == .Add
		tint := put ? GREEN : RED
		ui_rect(ui, {box.x + 10, r.y, box.w - 20, r.h}, color_alpha(tint, 0.13), 0)
		ui_rect(ui, {box.x + 10, r.y, 2, r.h}, color_alpha(tint, 0.85), 0)
		if row.num != ROW_CONT do ui_text(ui, mono, put ? "+" : "-", {r.x + 4, r.y + 2}, PEEK_PX, tint)
		x := r.x + PEEK_SIGN + fold_in(ui, row)
		// The colours a line is made of, pulled a third of the way towards
		// the side of the diff it is on: a comment in a line that went in is
		// still a comment, and the row still reads green from across the
		// window.
		draw_code(ui, row.text, x, r.y + 2, box.x + box.w - 14, color_mix(TEXT, tint, 0.3), tint, 0.32)

	case .Same:
		x := r.x + PEEK_SIGN + fold_in(ui, row)
		draw_code(ui, row.text, x, r.y + 2, box.x + box.w - 14, color_alpha(FAINT, 0.95), FAINT, 0.5)

	case .Skip:
		// A rule with the count sitting on it, which is the whole of what a
		// stretch of unchanged file is worth on screen.
		y := r.y + r.h / 2
		w := font_width(&ui.regular, row.text, 10.5)
		ui_rect(ui, {box.x + 10, y, box.w - 20, 1}, color_alpha(BORDER, 0.6), 0)
		ui_rect(ui, {r.x + PEEK_SIGN - 4, r.y + 1, w + 12, r.h - 2}, COMPOSER_BG, 3)
		ui_text(ui, &ui.regular, row.text, {r.x + PEEK_SIGN + 2, r.y + 2}, 10.5, color_alpha(FAINT, 0.9))

	case .Path:
		ui_circle(ui, {r.x + 5, r.y + r.h / 2}, 2, color_alpha(TILE_FIND, 0.8))
		x := r.x + PEEK_SIGN
		room := box.x + box.w - 14 - x
		num := row.num > 0 ? fmt.tprintf(":%d", row.num) : ""
		if num != "" do room -= font_width(mono, num, PEEK_PX) + 2
		text := font_ellipsize(mono, row.text, PEEK_PX, room, buf[:])
		w := ui_text(ui, mono, text, {x, r.y + 2}, PEEK_PX, color_mix(TEXT, MUTED, 0.2))
		if num != "" do ui_text(ui, mono, num, {x + w, r.y + 2}, PEEK_PX, FAINT)

	case .Check:
		// The box, and the tick inside it when the item is done: the same
		// mark a card carries, at the size a line of a list can hold.
		bx := r.x + 2
		by := r.y + r.h / 2 - 6
		ui_rect(ui, {bx, by, 13, 13}, color_alpha(row.col, row.num > 0 ? 0.9 : 0.3), 3)
		switch row.num {
		case 2:
			ui_line(ui, {bx + 3, by + 6.5}, {bx + 5.5, by + 9.5}, 1.8, COMPOSER_BG)
			ui_line(ui, {bx + 5.5, by + 9.5}, {bx + 10, by + 3.5}, 1.8, COMPOSER_BG)
		case 1:
			// In hand: the box is filled and something is sitting in the
			// middle of it. A ring at this size read as an empty box, which
			// is the one thing it must not look like.
			ui_rect(ui, {bx + 2, by + 2, 9, 9}, COMPOSER_BG, 2)
			ui_rect(ui, {bx + 4, by + 4, 5, 5}, row.col, 1.5)
		case:
			ui_rect(ui, {bx + 1.5, by + 1.5, 10, 10}, COMPOSER_BG, 2)
		}
		x := r.x + 22
		text := font_ellipsize(&ui.regular, row.text, PEEK_TX, box.x + box.w - 14 - x, buf[:])
		dim := row.num == 2 ? color_alpha(MUTED, 0.9) : color_mix(TEXT, MUTED, 0.2)
		ui_text(ui, &ui.regular, text, {x, r.y + 3}, PEEK_TX, dim)
	}
}

// The numbers get a column of their own only when there are numbers: output
// that has none used to be pushed along by a gutter standing empty beside it,
// which reads as an indent nobody typed. One answer for the panel, read by the
// measure and by the drawing.
@(private = "file")
rows_gut :: proc(rows: []Row) -> f32 {
	for row in rows do if row.num > 0 && row.kind == .Mono do return PEEK_GUT
	return 0
}

// How wide a row wants the panel to be: where its text starts, plus the text.
@(private = "file")
row_width :: proc(ui: ^UI, row: Row, gut: f32) -> f32 {
	switch row.kind {
	case .Head, .Gap, .Skip:
		return 0 // a label with a rule after it fits whatever it is given
	case .Mono:
		return gut + fold_in(ui, row) + font_width(&ui.mono, tabbed(row.text), PEEK_PX)
	case .Cmd:
		return PEEK_SIGN + 4 + fold_in(ui, row) + font_width(&ui.mono, tabbed(row.text), PEEK_PX)
	case .Add, .Del, .Same:
		return PEEK_SIGN + fold_in(ui, row) + font_width(&ui.mono, tabbed(row.text), PEEK_PX)
	case .Path:
		return PEEK_SIGN + font_width(&ui.mono, row.text, PEEK_PX) + 30
	case .Note:
		return font_width(&ui.regular, row.text, PEEK_TX)
	case .Check:
		return 22 + font_width(&ui.regular, row.text, PEEK_TX)
	}
	return 0
}

// How far in the rest of a folded line starts: enough to see that it is the
// same line carried over, and not so far that a fold looks like an indent
// somebody typed.
@(private = "file")
fold_in :: proc(ui: ^UI, row: Row) -> f32 {
	if row.num != ROW_CONT do return 0
	return 14 + char_w(ui) * f32(row.ind)
}

// Code, coloured by what its characters are: comments back out of the way,
// strings and numbers apart from the words, punctuation quieter than either.
// It is not a parser and knows no language — a run of digits is a number in
// all of them — and it does not need to be. The point is that a panel of
// output stops being a wall of one grey.
//
// `wash` is a colour every token is pulled towards and `amount` how far, which
// is how a diff keeps its green and red while the code inside it keeps its
// own.
@(private = "file")
draw_code :: proc(ui: ^UI, text: string, x, y, max_x: f32, base, wash: Color, amount: f32) {
	line := tabbed(text)
	pen := x
	i := 0
	for i < len(line) {
		end, kind := code_token(line, i)
		col := base
		switch kind {
		case .Comment:
			col = color_alpha(FAINT, 0.95)
		case .Str:
			col = color_mix(TILE_READ, base, 0.3)
		case .Num:
			col = AMBER
		case .Punct:
			col = color_mix(base, MUTED, 0.55)
		case .Plain:
		}
		if amount > 0 do col = color_mix(col, wash, amount)
		run := line[i:end]
		w := font_width(&ui.mono, run, PEEK_PX)
		// The cut, when the rest will not fit: an ellipsis where the words
		// stop, so a folded line that is still too long says so.
		if pen + w > max_x {
			buf: [256]u8
			room := max_x - pen
			ui_text(ui, &ui.mono, font_ellipsize(&ui.mono, run, PEEK_PX, room, buf[:]), {pen, y}, PEEK_PX, col)
			return
		}
		ui_text(ui, &ui.mono, run, {pen, y}, PEEK_PX, col)
		pen += w
		i = end
	}
}

Code_Tok :: enum {
	Plain,
	Comment,
	Str,
	Num,
	Punct,
}

// One run of a line that is all the same thing, starting at `i`. A quote that
// never closes before the end of the line is not a string — it is an
// apostrophe in a sentence somebody printed, and taking it for a string used
// to colour the whole of the rest of the line.
@(private = "file")
code_token :: proc(s: string, i: int) -> (end: int, kind: Code_Tok) {
	ident :: proc(c: u8) -> bool {
		return c == '_' || c >= 128 || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
	}
	c := s[i]
	switch {
	case c == '/' && i + 1 < len(s) && s[i + 1] == '/':
		return len(s), .Comment
	case c == '#' && (i == 0 || s[i - 1] == ' ') && i + 1 < len(s) && s[i + 1] == ' ':
		return len(s), .Comment
	case c == '"' || c == '`' || c == '\'':
		j := i + 1
		for j < len(s) {
			if s[j] == '\\' && c != '`' {
				j += 2
				continue
			}
			if s[j] == c do return j + 1, .Str
			j += 1
		}
		return i + 1, .Plain
	case c >= '0' && c <= '9':
		j := i
		for j < len(s) && (ident(s[j]) || s[j] == '.') do j += 1
		return j, .Num
	case ident(c):
		j := i
		for j < len(s) && ident(s[j]) do j += 1
		return j, .Plain
	case c == ' ':
		j := i
		for j < len(s) && s[j] == ' ' do j += 1
		return j, .Plain
	}
	j := i
	for j < len(s) && !ident(s[j]) && s[j] != ' ' && s[j] != '"' && s[j] != '`' do j += 1
	return max(j, i + 1), .Punct
}

// Tabs, as the width a listing is laid out in. The atlas has no tab in it, so
// a line that arrived with one used to draw the character after it right on
// top of the character before.
@(private = "file")
tabbed :: proc(line: string) -> string {
	if !strings.contains_rune(line, '\t') do return line
	out := strings.builder_make(context.temp_allocator)
	for c in line {
		if c == '\t' do strings.write_string(&out, "    ")
		else do strings.write_rune(&out, c)
	}
	return strings.to_string(out)
}

// A tool call in words, for a copy taken off the stone: what came back, or
// failing that what was asked.
tool_hover :: proc(b: ^Block) -> string {
	if result := strings.trim_space(strings.to_string(b.result)); result != "" do return result
	if arg := block_arg(b); arg != "" do return arg
	return b.name
}
