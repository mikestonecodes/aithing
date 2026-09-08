package aithing

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// A thread is not a piece of work. One thread carries five different things —
// the bug that started it, the two follow-ups, the thing noticed halfway
// through — and a grid with one card per thread hides every one of them
// behind the first sentence anyone happened to type.
//
// So the card is the todo item, not the thread. Items come from two places:
// an agent reads each thread and says what is being worked on in it and where
// in the transcript that is (see agent.odin), and anything typed into the box
// under the grid is split into an item per part. Opening an item opens its
// thread at the message it is about.
//
// Every item says where its work stands, which is the other half of what a
// grid is for: waiting, queued, running, done, failed. A thread running in
// another window moves its items on the next scan, so the grid is current
// whether the work was started here or not.
//
// A card can only leave the grid one way, and that is by being dismissed. The
// dismissal is written down (see `hidden`), because the two things that make
// cards — the stub every unread thread gets and the list the agent hands back
// — know nothing about what was ever on screen, and would both put a
// dismissed card straight back on the next scan.

Todo_State :: enum {
	Open, // nothing has started it
	Running, // a turn is working on it
	Done,
	Failed,
	// Lined up behind the turn in flight. Last in the enum on purpose: the
	// file stores the number, and the four before it are already on disk.
	Queued,
}

Todo :: struct {
	id:      string, // stable across launches; what everything else refers to
	session: string, // the thread it lives in, "" until one is started for it
	cwd:     string,
	text:    string,
	state:   Todo_State,
	// The cards that go out together as one thread. A list typed into the box
	// is one piece of work said in several sentences, not several pieces of
	// work: it makes one thread, and every card cut out of it names that
	// thread here until the harness has named it for real. A card standing on
	// its own is its own batch, so this is never empty.
	batch:   string,
	at:      time.Time, // when it was last touched: the grid is newest first
}

Todos :: struct {
	list:    [dynamic]Todo,
	// Everything dismissed by hand, by the key it would come back under. This
	// is the only record that a card was ever on the grid, so it is the only
	// thing that can keep one off it.
	hidden:  map[string]bool,
	// How many items each thread has. Only a count, but asking the list that
	// question is the commonest thing anything does with it — once per thread
	// per scan — and walking a few hundred items to answer it a few hundred
	// times is a tenth of a second the window does not have.
	per_session: map[string]int,
	dirty:   bool,
	// Bumped by every change to `list`. Anything derived from the list —
	// app.todo_view, the canvas grid — carries the version it was built at
	// and rebuilds itself when they differ, so no index can outlive the list
	// it points into.
	ver:     int,
	next_id: int,
}

// Bumped when the shape of a row changes. A file the version does not match
// is not read, and is left where it is until the first save writes over it.
// 2 dropped the cards that used to be made out of every thread on the machine,
// 3 the two columns that only those cards ever filled in.
@(private = "file")
TODOS_VERSION :: "3"

// A version line, then one line per item, tab separated, and one `-` line per
// card dismissed by hand — which is shorter, and that is how it tells itself
// apart.
todos_load :: proc(t: ^Todos, path := "") {
	from := path != "" ? path : config_path("todos")
	data, err := os.read_entire_file_from_path(from, context.temp_allocator)
	if err != nil do return
	it := each_line(string(data))
	first, _ := iter_next(&it)
	if strings.trim_space(first) != TODOS_VERSION do return
	for line in iter_next(&it) {
		row := strings.trim_right_space(line)
		if row == "" do continue
		f := strings.split(row, "\t", context.temp_allocator)
		if len(f) >= 2 && f[0] == "-" {
			t.hidden[strings.clone(f[1])] = true
			continue
		}
		if len(f) < 7 do continue
		state, _ := strconv.parse_int(f[0])
		unix, _ := strconv.parse_i64(f[1])
		td := Todo {
			state   = Todo_State(clamp(state, 0, len(Todo_State) - 1)),
			at      = time.unix(unix, 0),
			id      = strings.clone(f[2]),
			session = strings.clone(f[3]),
			cwd     = strings.clone(f[4]),
			text    = unescape_line(f[6]),
		}
		td.batch = strings.clone(f[5] != "" ? f[5] : td.id)
		session_claim(t, td.session)
		// Nothing is running or queued at startup: both belong to a process
		// this launch does not have. A card left mid-turn by a quit or a
		// crash reads as waiting again, not as work in flight forever.
		if td.state == .Running || td.state == .Queued do td.state = .Open
		append(&t.list, td)
		// Ids are `n-<number>`; the counter has to clear everything on disk.
		if n, ok := strconv.parse_int(strings.trim_prefix(td.id, "n-")); ok && n >= t.next_id {
			t.next_id = n + 1
		}
	}
}

todos_save :: proc(t: ^Todos, path := "") {
	if !t.dirty do return
	t.dirty = false
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, TODOS_VERSION)
	strings.write_byte(&b, '\n')
	for td in t.list {
		fmt.sbprintfln(
			&b,
			"%d\t%d\t%s\t%s\t%s\t%s\t%s",
			int(td.state),
			time.to_unix_seconds(td.at),
			td.id,
			td.session,
			td.cwd,
			td.batch,
			escape_line(one_word_line(td.text)),
		)
	}
	for key in t.hidden do fmt.sbprintfln(&b, "-\t%s", key)
	to := path != "" ? path : config_path("todos")
	_ = os.write_entire_file(to, transmute([]byte)strings.to_string(b))
}

// A tab is what the file splits on, so an item never carries one.
@(private = "file")
one_word_line :: proc(text: string) -> string {
	if !strings.contains(text, "\t") do return text
	out, _ := strings.replace_all(text, "\t", " ", context.temp_allocator)
	return out
}

// The two places a card's thread is counted. Every add and every drop goes
// through them, so `per_session` cannot drift from the list.
@(private = "file")
session_claim :: proc(t: ^Todos, session: string) {
	if session == "" do return
	if n, has := t.per_session[session]; has do t.per_session[session] = n + 1
	else do t.per_session[strings.clone(session)] = 1
}

@(private = "file")
session_release :: proc(t: ^Todos, session: string) {
	if session == "" do return
	n, has := t.per_session[session]
	if !has do return
	if n > 1 {
		t.per_session[session] = n - 1
		return
	}
	if key, _ := delete_key(&t.per_session, session); key != "" do delete(key)
}

// Takes one item out of the list. Every removal goes through here.
@(private = "file")
todo_drop :: proc(t: ^Todos, at: int) {
	session_release(t, t.list[at].session)
	todo_free(&t.list[at])
	ordered_remove(&t.list, at)
}

todos_destroy :: proc(t: ^Todos) {
	for &td in t.list do todo_free(&td)
	delete(t.list)
	for key in t.hidden do delete(key)
	delete(t.hidden)
	for id in t.per_session do delete(id)
	delete(t.per_session)
}

@(private = "file")
todo_free :: proc(td: ^Todo) {
	delete(td.id)
	delete(td.session)
	delete(td.cwd)
	delete(td.batch)
	delete(td.text)
}

todos_find :: proc(t: ^Todos, id: string) -> int {
	for td, i in t.list do if td.id == id do return i
	return -1
}

// Adds an item and hands back its id, which is what the caller holds on to:
// the list is re-sorted and rebuilt underneath, so an index is only good for
// the frame it was taken in.
todos_add :: proc(t: ^Todos, text, session, cwd: string, state := Todo_State.Open, batch := "") -> string {
	id := fmt.aprintf("n-%d", t.next_id)
	t.next_id += 1
	append(
		&t.list,
		Todo {
			id = id,
			session = strings.clone(session),
			cwd = strings.clone(cwd),
			text = strings.clone(strings.trim_space(text)),
			state = state,
			at = time.now(),
			batch = strings.clone(batch != "" ? batch : id),
		},
	)
	session_claim(t, session)
	t.dirty = true
	t.ver += 1
	return id
}

// --- dismissing ---------------------------------------------------------------

// Drops an item without a word. This is for an item whose thread is no longer
// on disk: it did not go because anyone said so, and it must not be recorded
// as dismissed — the same thread turning up again should get its cards back.
todos_remove :: proc(t: ^Todos, id: string) {
	at := todos_find(t, id)
	if at < 0 do return
	todo_drop(t, at)
	t.dirty = true
	t.ver += 1
}

// The x on a card. The card goes and stays gone: the key it would come back
// under is written down, and anything that makes cards reads that first.
todos_dismiss :: proc(t: ^Todos, id: string) {
	at := todos_find(t, id)
	if at < 0 do return
	key := todo_key(t.list[at])
	if key not_in t.hidden do t.hidden[strings.clone(key)] = true
	todo_drop(t, at)
	t.dirty = true
	t.ver += 1
}

todos_dismissed :: proc(t: ^Todos, key: string) -> bool {
	return key in t.hidden
}

// What a card is remembered by once it is gone: its thread and its wording,
// or its own id while it has no thread to be told apart by.
todo_key :: proc(td: Todo, allocator := context.temp_allocator) -> string {
	if td.session == "" do return typed_key(td.id, allocator)
	return item_key(td.session, td.text, allocator)
}

// An item is its thread and its wording, folded down so that two phrasings of
// the same thing are the same item.
item_key :: proc(session, text: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"i\x1f", session, "\x1f", todo_fold(text)}, allocator)
}

typed_key :: proc(id: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"n\x1f", id}, allocator)
}

// The wording alone, folded: what the grid matches on when it folds the same
// piece of work carried in several threads down to one card.
todo_fold_key :: proc(text: string) -> string {
	return item_key("", text)
}

// Letters and digits, lowercased, single spaces between them: everything two
// wordings of the same item agree on.
@(private = "file")
todo_fold :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	gap := false
	for i in 0 ..< len(text) {
		c := text[i]
		switch {
		case c >= 'A' && c <= 'Z':
			c += 'a' - 'A'
			fallthrough
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'):
			if gap && strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
			gap = false
			strings.write_byte(&b, c)
		case:
			gap = true
		}
	}
	return strings.to_string(b)
}

// Whether a thread has any cards of its own.
todos_has :: proc(t: ^Todos, session: string) -> bool {
	return session in t.per_session
}

// Where a card comes in the order they were made. Ids are `n-<number>`, and
// that number never changes, which is what lets the grid put a card down once
// and leave it there.
todo_seq :: proc(td: Todo) -> int {
	n, _ := strconv.parse_int(strings.trim_prefix(td.id, "n-"))
	return n
}

// --- batches -------------------------------------------------------------------

// Every card that goes out as one thread, by index. On the temp allocator:
// the list moves, so this is good for as long as nothing touches it.
todos_batch :: proc(t: ^Todos, batch: string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	if batch == "" do return out[:]
	for td, i in t.list do if td.batch == batch do append(&out, i)
	return out[:]
}

// The batch got its thread: every card cut out of the same typed list points
// at it, because they are all being worked on in the one conversation.
todos_batch_session :: proc(t: ^Todos, batch, session, cwd: string) {
	if batch == "" || session == "" do return
	for &td in t.list {
		if td.batch != batch || td.session == session do continue
		session_release(t, td.session)
		delete(td.session)
		td.session = strings.clone(session)
		session_claim(t, session)
		if td.cwd == "" {
			delete(td.cwd)
			td.cwd = strings.clone(cwd)
		}
	}
	t.dirty = true
	t.ver += 1
}

// Where the whole batch stands: one thread finishing is every card on it
// finishing, because there was one turn and it is over.
todos_batch_state :: proc(t: ^Todos, batch: string, state: Todo_State) {
	if batch == "" do return
	for &td in t.list {
		if td.batch != batch || td.state == state do continue
		td.state = state
		td.at = time.now()
		t.dirty = true
		t.ver += 1
	}
}

// Everything an item can be found by.
todo_matches :: proc(td: Todo, query: string) -> bool {
	text := strings.to_lower(td.text, context.temp_allocator)
	cwd := strings.to_lower(td.cwd, context.temp_allocator)
	return strings.contains(text, query) || strings.contains(cwd, query)
}

// --- typing a list ----------------------------------------------------------

// What was typed, cut into parts, before any model has seen it. A line each,
// a bullet each, a sentence each: the split anyone would make by hand, done
// on the spot so the cards appear as Enter is pressed. The agent refines the
// wording afterwards (see agent.odin) — this is what stands in the meantime,
// and what stands if no model answers.
todos_split :: proc(text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	body := text
	for raw in strings.split_lines_iterator(&body) {
		line := strings.trim_space(raw)
		line = strings.trim_left(line, "-*• \t")
		// `1.` and `2)` at the head of a line are a list too.
		digits := 0
		for digits < len(line) && line[digits] >= '0' && line[digits] <= '9' do digits += 1
		if digits > 0 && digits < len(line) && (line[digits] == '.' || line[digits] == ')') {
			line = strings.trim_space(line[digits + 1:])
		}
		if line == "" do continue
		// One long line with sentences in it is a list as well.
		rest := line
		for rest != "" {
			cut := -1
			for i in 0 ..< len(rest) {
				if rest[i] != '.' && rest[i] != ';' do continue
				if i + 1 < len(rest) && rest[i + 1] != ' ' do continue
				cut = i
				break
			}
			if cut < 0 {
				append(&out, strings.trim_space(rest))
				break
			}
			piece := strings.trim_space(rest[:cut])
			if piece != "" do append(&out, piece)
			rest = strings.trim_space(rest[cut + 1:])
		}
	}
	if len(out) == 0 {
		trimmed := strings.trim_space(text)
		if trimmed != "" do append(&out, trimmed)
	}
	return out[:]
}

// --- how it reads -----------------------------------------------------------

todo_state_label :: proc(state: Todo_State) -> string {
	switch state {
	case .Queued:
		return "queued"
	case .Running:
		return "processing"
	case .Done:
		return "complete"
	case .Failed:
		return "failed"
	case .Open:
		return "waiting"
	}
	return ""
}

todo_state_color :: proc(state: Todo_State) -> Color {
	switch state {
	case .Queued:
		return ACCENT_DIM
	case .Running:
		return ACCENT
	case .Done:
		return GREEN
	case .Failed:
		return RED
	case .Open:
		return MUTED
	}
	return MUTED
}
