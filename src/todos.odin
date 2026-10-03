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
// So the card is the todo item, not the thread — and a card is a thread, one
// each. Everything typed into the box under the grid is split into an item per
// part, and every part gets its own conversation. It used to be one thread
// with every part riding on it, which meant a card could not be read, run or
// stopped without the four beside it coming along.
//
// Every item says where its work stands, which is the other half of what a
// grid is for: waiting, running, done, failed. The list is a file, and a card
// changed in another window is changed in this one on the next frame (see
// share.odin), so the grid is current whether the work was started here or
// not.
//
// A card can only leave the grid one way, and that is by being dismissed. The
// dismissal is written down (see `hidden`), because the two things that make
// cards — the stub every unread thread gets and the list the agent hands back
// — know nothing about what was ever on screen, and would both put a
// dismissed card straight back on the next scan.

// Where a piece of work stands. Only Open, Asked, Done and Failed are ever
// written down: they are what became of the work, and they outlive the
// process. Running is not the card's to remember — the turns are the only
// thing that knows it, and todo_display_state reads it off them. Storing it
// too meant two places had an opinion about a card that was plainly on screen
// doing something else.
//
// Asked is the ending that used to be reported as Done. A turn ends whether
// the work was finished or the agent stopped to ask which of two things you
// meant, and the process exits zero either way; see verdict.odin for how the
// two are told apart now.
//
// There was a Queued as well, for a card waiting on one of four turn slots.
// Cards do not wait any more, so nothing can be in that state; the number 4
// is Asked in a version 5 file and was Queued in a version 4 one, which is
// what todos_load reads the version for.
Todo_State :: enum {
	Open, // nothing has started it
	Running, // a turn is working on it: derived, never stored
	Done,
	Failed,
	Asked, // the turn ended without the work being finished
	// The work is in the project. Written by the landing and by nothing else,
	// which is what makes it a fact rather than an opinion: the one procedure
	// that merges a card's branch is the one procedure that says so. A card
	// that says complete and nothing more is a card whose work is still on a
	// branch of its own — which used to be indistinguishable from one that
	// had been merged, and was the whole of the confusion.
	//
	// Last in the enum on purpose: the state is written to the todos file as
	// its number, so anything added in the middle would silently rename every
	// card already on disk.
	Merged,
}

Todo :: struct {
	id:      string, // stable across launches; what everything else refers to
	session: string, // the thread it lives in, "" until one is started for it
	cwd:     string,
	text:    string,
	state:   Todo_State,
	at:      time.Time, // when it was last touched: the grid is newest first
	// Why it failed, or what it stopped to ask: the one sentence a headless
	// turn has to say for itself, kept until the card is asked to run again.
	// It is written down with the card because a card that says `needs you`
	// in one window says the question beside it in the other — it used to be
	// held by the window whose turn it was, so the window next to it had a
	// card asking for you and nothing on it saying what about.
	note:    string,
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
	next_id: int,
	// The file this list is, and what it was when this window last read or
	// wrote it: see share.odin. Empty for a list that lives only in memory,
	// which is what a test's is.
	path:    string,
	seen:    File_Stamp,
}

// Bumped when the shape of a row changes. A file the version does not match
// is not read, and is left where it is until the first save writes over it.
// 2 dropped the cards that used to be made out of every thread on the machine,
// 3 the two columns that only those cards ever filled in, and 4 the batch a
// card belonged to — a card is a thread now, so there is nothing to belong to.
// 5 gave the number 4 in the state column a new meaning, which is the only
// reason a version 4 file is still read: dropping every card anyone had
// written down to make room for one new state is not a trade worth making.
@(private = "file")
TODOS_VERSION :: "5"

// The list a window works from, bound to the file it is: everything changed
// from here on is written through to it (see todos_begin).
todos_load :: proc(t: ^Todos, path := "") {
	t.path = strings.clone(path != "" ? path : config_path("todos"))
	data, stamp, ok := file_read(t.path)
	if !ok do return
	t.seen = stamp
	todos_parse(t, string(data))
}

// A version line, then one line per item, tab separated, one `-` line per
// card dismissed by hand, and a `next` line. The note is a seventh column, so
// a build from before notes were written down reads the first six and passes
// over it, and the `next` line is too short to be a card to the same build.
@(private = "file")
todos_parse :: proc(t: ^Todos, data: string) {
	it := each_line(data)
	first, _ := iter_next(&it)
	version := strings.trim_space(first)
	if version != TODOS_VERSION && version != "4" do return
	for line in iter_next(&it) {
		row := strings.trim_right_space(line)
		if row == "" do continue
		f := strings.split(row, "\t", context.temp_allocator)
		if len(f) >= 2 && f[0] == "-" {
			if f[1] not_in t.hidden do t.hidden[strings.clone(f[1])] = true
			continue
		}
		if len(f) >= 2 && f[0] == "next" {
			if n, ok := strconv.parse_int(f[1]); ok do t.next_id = max(t.next_id, n)
			continue
		}
		if len(f) < 6 do continue
		state, _ := strconv.parse_int(f[0])
		// 4 is Asked here and was Queued there, and a card that was queued
		// when a window last quit was a card nothing had started.
		if version == "4" && state == int(Todo_State.Asked) do state = int(Todo_State.Open)
		unix, _ := strconv.parse_i64(f[1])
		td := Todo {
			state   = Todo_State(clamp(state, 0, len(Todo_State) - 1)),
			at      = time.unix(unix, 0),
			id      = f[2],
			session = f[3],
			cwd     = f[4],
			text    = unescape_line(f[5], context.temp_allocator),
			note    = len(f) >= 7 ? unescape_line(f[6], context.temp_allocator) : "",
		}
		// Files written before it became derived still have the number in
		// them, as do the ones written while there was a queue — and neither
		// means anything without the process that was running at the time.
		if td.state == .Running do td.state = .Open
		todo_put(t, td)
	}
}

// The whole file, as text.
@(private = "file")
todos_text :: proc(t: ^Todos) -> []byte {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, TODOS_VERSION)
	strings.write_byte(&b, '\n')
	for td in t.list {
		fmt.sbprintf(
			&b,
			"%d\t%d\t%s\t%s\t%s\t%s",
			int(td.state),
			time.to_unix_seconds(td.at),
			td.id,
			td.session,
			td.cwd,
			escape_line(one_word_line(td.text)),
		)
		if td.note != "" do fmt.sbprintf(&b, "\t%s", escape_line(one_word_line(td.note)))
		strings.write_byte(&b, '\n')
	}
	for key in t.hidden do fmt.sbprintfln(&b, "-\t%s", key)
	// The counter, and not only the cards it numbered. Read back off the cards
	// alone, the newest card dismissed was a number free to hand out again —
	// and with two windows open, one that had just been dismissed in the other
	// went straight back out to a card that found the first one's worktree
	// still standing and started work in it.
	fmt.sbprintfln(&b, "next\t%d", t.next_id)
	return transmute([]byte)strings.to_string(b)
}

// This window's copy, caught up with the file when another window has written
// it since this one last looked. Once a frame and before anything walks the
// list: replacing it frees every string a caller could be holding, so it is
// done where nobody is holding one. A stat when nothing has moved.
todos_sync :: proc(t: ^Todos) -> bool {
	if t.path == "" || file_stamp(t.path) == t.seen do return false
	fresh: Todos
	data, stamp, ok := file_read(t.path)
	if ok do todos_parse(&fresh, string(data))
	fresh.seen = stamp
	fresh.next_id = max(fresh.next_id, t.next_id)
	fresh.path, t.path = t.path, ""
	todos_destroy(t)
	t^ = fresh
	return true
}

// What a change is made against: this window's copy, and — when another
// window has written the file since this one last read it — the file as that
// window left it. Every change is made to both, under the lock, so neither
// window's change can write over the other's.
//
// This window's copy is not swapped for the file's here, though it is the
// file's that is right. The callers are walking the list as they change it —
// landing every finished card, settling every card of a thread — and swapping
// it would free what they are halfway along. todos_sync swaps it at the top of
// the next frame, which leaves one frame short of the other window's change
// and nothing else.
@(private = "file")
Todos_Edit :: struct {
	lock:   ^os.File,
	behind: bool,
	disk:   Todos,
}

@(private = "file")
todos_begin :: proc(t: ^Todos) -> (e: Todos_Edit) {
	if t.path == "" do return
	e.lock = file_lock(t.path)
	if file_stamp(t.path) == t.seen do return
	e.behind = true
	if data, _, ok := file_read(t.path); ok do todos_parse(&e.disk, string(data))
	// A number the other window has handed out is not this one's to hand out
	// again: two cards with one number are two agents in one worktree.
	t.next_id = max(t.next_id, e.disk.next_id)
	return
}

// `mine` and `theirs` are whether the change did anything to this window's
// copy and to the file's. The stamp is only taken when what was written is
// this window's copy: after writing the file's, this window is still behind,
// and todos_sync has to know that.
@(private = "file")
todos_commit :: proc(t: ^Todos, e: ^Todos_Edit, mine, theirs: bool) {
	defer file_unlock(e.lock)
	defer todos_destroy(&e.disk)
	if t.path == "" do return
	if !e.behind {
		if mine do t.seen, _ = file_replace(t.path, todos_text(t))
		return
	}
	if theirs do _, _ = file_replace(t.path, todos_text(&e.disk))
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
	delete(t.path)
}

@(private = "file")
todo_free :: proc(td: ^Todo) {
	delete(td.id)
	delete(td.session)
	delete(td.cwd)
	delete(td.text)
	delete(td.note)
}

todos_find :: proc(t: ^Todos, id: string) -> int {
	for td, i in t.list do if td.id == id do return i
	return -1
}

// Adds an item and hands back its id, which is what the caller holds on to:
// the list is re-sorted and rebuilt underneath, so an index is only good for
// the frame it was taken in.
todos_add :: proc(t: ^Todos, text, session, cwd: string, state := Todo_State.Open) -> string {
	e := todos_begin(t)
	td := Todo {
		id      = fmt.tprintf("n-%d", t.next_id),
		session = session,
		cwd     = cwd,
		text    = strings.trim_space(text),
		state   = state,
		at      = time.now(),
	}
	todo_put(t, td)
	if e.behind do todo_put(&e.disk, td)
	todos_commit(t, &e, true, e.behind)
	return t.list[len(t.list) - 1].id
}

// One card into a list, copied, and the counter moved past its number. Ids
// are `n-<number>`, and the counter has to clear every one of them.
@(private = "file")
todo_put :: proc(t: ^Todos, td: Todo) {
	append(
		&t.list,
		Todo {
			id = strings.clone(td.id),
			session = strings.clone(td.session),
			cwd = strings.clone(td.cwd),
			text = strings.clone(td.text),
			note = strings.clone(td.note),
			state = td.state,
			at = td.at,
		},
	)
	session_claim(t, td.session)
	t.next_id = max(t.next_id, todo_seq(td) + 1)
}

// --- dismissing ---------------------------------------------------------------

// Drops an item without a word. This is for an item whose thread is no longer
// on disk: it did not go because anyone said so, and it must not be recorded
// as dismissed — the same thread turning up again should get its cards back.
todos_remove :: proc(t: ^Todos, id: string) {
	// The caller's id is often the card's own, which the drop frees.
	id := strings.clone(id, context.temp_allocator)
	e := todos_begin(t)
	theirs := e.behind && todo_take(&e.disk, id, "")
	mine := todo_take(t, id, "")
	todos_commit(t, &e, mine, theirs)
}

// The x on a card. The card goes and stays gone: the key it would come back
// under is written down, and anything that makes cards reads that first.
todos_dismiss :: proc(t: ^Todos, id: string) {
	id := strings.clone(id, context.temp_allocator)
	at := todos_find(t, id)
	if at < 0 do return
	key := todo_key(t.list[at])
	e := todos_begin(t)
	theirs := e.behind && todo_take(&e.disk, id, key)
	mine := todo_take(t, id, key)
	todos_commit(t, &e, mine, theirs)
}

// A card out of a list, and the key that keeps it out when there is one.
@(private = "file")
todo_take :: proc(t: ^Todos, id, hide: string) -> bool {
	changed := false
	if hide != "" && hide not_in t.hidden {
		t.hidden[strings.clone(hide)] = true
		changed = true
	}
	if at := todos_find(t, id); at >= 0 {
		todo_drop(t, at)
		changed = true
	}
	return changed
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

// --- the thread a card gets ---------------------------------------------------

// The card got its thread. A card is one conversation, so this is one card,
// and it is written down the moment the harness names the session.
todo_set_session :: proc(t: ^Todos, id, session, cwd: string) {
	if session == "" do return
	e := todos_begin(t)
	theirs := e.behind && todo_name(&e.disk, id, session, cwd)
	mine := todo_name(t, id, session, cwd)
	todos_commit(t, &e, mine, theirs)
}

@(private = "file")
todo_name :: proc(t: ^Todos, id, session, cwd: string) -> bool {
	at := todos_find(t, id)
	if at < 0 do return false
	td := &t.list[at]
	changed := false
	if td.session != session {
		session_release(t, td.session)
		delete(td.session)
		td.session = strings.clone(session)
		session_claim(t, session)
		changed = true
	}
	if td.cwd == "" && cwd != "" {
		delete(td.cwd)
		td.cwd = strings.clone(cwd)
		changed = true
	}
	return changed
}

// Marks what became of a card. Only the settled states go through here:
// running is read off the process that is doing the work.
todo_set_state :: proc(t: ^Todos, id: string, state: Todo_State) {
	assert(state != .Running)
	now := time.now()
	e := todos_begin(t)
	theirs := e.behind && todo_mark(&e.disk, id, state, now)
	mine := todo_mark(t, id, state, now)
	todos_commit(t, &e, mine, theirs)
}

@(private = "file")
todo_mark :: proc(t: ^Todos, id: string, state: Todo_State, now: time.Time) -> bool {
	at := todos_find(t, id)
	if at < 0 || t.list[at].state == state do return false
	t.list[at].state = state
	t.list[at].at = now
	return true
}

// Says why, on the card, or "" to take what it said away.
todo_set_note :: proc(t: ^Todos, id, note: string) {
	e := todos_begin(t)
	theirs := e.behind && todo_annotate(&e.disk, id, note)
	mine := todo_annotate(t, id, note)
	todos_commit(t, &e, mine, theirs)
}

@(private = "file")
todo_annotate :: proc(t: ^Todos, id, note: string) -> bool {
	at := todos_find(t, id)
	if at < 0 || t.list[at].note == note do return false
	delete(t.list[at].note)
	t.list[at].note = strings.clone(note)
	return true
}

// Everything an item can be found by.
todo_matches :: proc(td: Todo, query: string) -> bool {
	return contains_fold(td.text, query) || contains_fold(td.cwd, query)
}

// --- typing a list ----------------------------------------------------------

// What was typed, cut into parts: a `*` or a `;;;` is where one part ends and
// the next begins, and nothing else is. One part is one card and one
// conversation.
//
// The cut used to be read out of the writing — a line, a bullet, a number, a
// full stop — and that got the ordinary case backwards. A job described in
// two sentences, or in a paragraph with a line break in it, came back as four
// cards and four threads, and there was no way to say the sentence belonged
// with the one before it: the box looked like it had misheard every time
// anyone wrote more than a few words. So the cut is something nobody types by
// accident, and everything else stays in the part it was written in.
//
// There are two of them because one character to reach for is not always the
// one to hand: `;;;` is three taps of a key that is already under a finger,
// where a `*` is a shifted reach. They cut the same, and text that wants a
// literal star in it still cannot have one either way.
//
// The spaces and newlines around a cut are only there to break the text up on
// screen, so they come off and nothing has to be typed a particular way.
todos_split :: proc(text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for {
		cut, width := todos_cut(rest)
		if cut < 0 do break
		piece := strings.trim_space(rest[:cut])
		if piece != "" do append(&out, piece)
		rest = rest[cut + width:]
	}
	if last := strings.trim_space(rest); last != "" do append(&out, last)
	return out[:]
}

// Where the first cut in `rest` is and how many bytes of it to step over, or
// -1 if there is none. A run of more than three semicolons is one cut, not a
// cut and a stray semicolon starting the next part.
todos_cut :: proc(rest: string) -> (at: int, width: int) {
	star := strings.index_byte(rest, '*')
	semi := strings.index(rest, ";;;")
	if semi >= 0 && (star < 0 || semi < star) {
		width = 3
		for semi + width < len(rest) && rest[semi + width] == ';' do width += 1
		return semi, width
	}
	if star >= 0 do return star, 1
	return -1, 0
}

// --- how it reads -----------------------------------------------------------

todo_state_label :: proc(state: Todo_State) -> string {
	switch state {
	case .Running:
		return "processing"
	case .Done:
		return "complete"
	case .Merged:
		return "merged"
	case .Failed:
		return "failed"
	case .Asked:
		return "needs you"
	case .Open:
		return "waiting"
	}
	return ""
}

todo_state_color :: proc(state: Todo_State) -> Color {
	switch state {
	case .Running:
		return BLUE
	case .Merged:
		// Landed, and nothing about it wants a person: the green is left
		// as a tint on grey so a row of merged cards is a quiet row. At
		// full strength every finished card shone as hard as a card that
		// had stopped to ask, and the eye went to the one thing that was
		// over.
		return color_mix(GREEN, FAINT, 0.7)
	case .Done:
		// Finished, but still on a branch of its own — greener than merged
		// because the work is not where anyone else can see it yet, and
		// someone still has to move it.
		return color_mix(GREEN, MUTED, 0.5)
	case .Failed:
		return RED
	case .Asked:
		return ACCENT
	case .Open:
		return MUTED
	}
	return MUTED
}
