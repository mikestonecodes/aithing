package aithing

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"

// Claude Code keeps one JSONL file per session under
// ~/.claude/projects/<slug>/<uuid>.jsonl, appending a record per event. The
// sidebar is that directory, read as a mailbox.

Session :: struct {
	id:      string, // the uuid, which is what `claude --resume` wants
	path:    string,
	project: string, // the slug directory name
	cwd:     string, // the directory the session was started in
	title:   string,
	preview: string,
	mtime:   time.Time,
	size:    i64,
	guess:   string, // the kind this thread looks like: see tags.odin
	// A thread that was opened and abandoned: a prompt or two, no work done.
	// These are the majority of what is on disk and none of them are worth a
	// place on the map, so they are hidden the way an archived thread is.
	transient: bool,
	prompts: int,
	verify: Verify, // whether the work was ever checked: see below
}

// The state of a thread's work, guessed the way its kind is. The signal is a
// check-shaped command near the end of the file and what came back from it,
// so nothing has to be run and nothing has to be remembered: every scan works
// it out again from what is on disk.
Verify :: enum {
	None,     // nothing was run, so there is nothing to check
	Untested, // work was done and nothing ever ran it
	Failed,   // the last check came back an error
	Passed,   // the last check ran clean
}

claude_home :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	path, _ := filepath.join({home, ".claude", "projects"}, allocator)
	return path
}

// Every session on disk, newest first. Only the head and tail of each file are
// read: enough for the title and the last prompt.
//
// The files are read all at once, one job each across a pool the width of the
// machine. Sequentially this was the window's whole startup — a second and a
// half of nothing on screen at 1150 sessions, because the first frame cannot
// be drawn until the list it draws exists. Nothing here shares anything: each
// job reads one file and fills one slot of its own, and the only thing after
// them is the sort.
sessions_scan :: proc(allocator := context.allocator) -> []Session {
	root := claude_home(context.temp_allocator)
	out := make([dynamic]Session, allocator)

	// Not the temp allocator: reading a session's summary resets it between
	// records, and these are held across all of them.
	dirs, derr := os.read_all_directory_by_path(root, context.allocator)
	if derr != nil do return out[:]
	defer os.file_info_slice_delete(dirs, context.allocator)

	// Every directory's listing is held until the last job is done: a job
	// points at the File_Info it came from rather than copying the strings
	// out of it.
	listings := make([dynamic][]os.File_Info, context.allocator)
	defer {
		for l in listings do os.file_info_slice_delete(l, context.allocator)
		delete(listings)
	}
	jobs := make([dynamic]Read_Job, context.allocator)
	defer delete(jobs)

	for d in dirs {
		if d.type != .Directory do continue
		files, ferr := os.read_all_directory_by_path(d.fullpath, context.allocator)
		if ferr != nil do continue
		append(&listings, files)
		for f in files {
			if !strings.has_suffix(f.name, ".jsonl") do continue
			if f.size == 0 do continue
			append(&jobs, Read_Job{file = f, project = d.name, allocator = allocator})
		}
	}

	if len(jobs) > 0 {
		pool: thread.Pool
		thread.pool_init(&pool, context.allocator, min(len(jobs), os.get_processor_core_count()))
		defer thread.pool_destroy(&pool)
		thread.pool_start(&pool)
		// The jobs are added after the array has stopped growing, so the
		// pointers handed to the pool stay put.
		for &j in jobs do thread.pool_add_task(&pool, context.allocator, session_read_task, &j)
		thread.pool_finish(&pool)
	}

	for &j in jobs {
		if j.out.title == "" {
			// Nothing but metadata in it: not a session anyone can open, and
			// the strings read for it go back now rather than riding along.
			session_free(&j.out, allocator)
			continue
		}
		append(&out, j.out)
	}

	slice.sort_by(out[:], proc(a, b: Session) -> bool {
		return time.time_to_unix_nano(a.mtime) > time.time_to_unix_nano(b.mtime)
	})
	return out[:]
}

// One file to read, and the session it turned into. `file` and `project` are
// borrowed from the directory listing the job was made from.
@(private = "file")
Read_Job :: struct {
	file:      os.File_Info,
	project:   string,
	allocator: runtime.Allocator,
	out:       Session,
}

@(private = "file")
session_read_task :: proc(t: thread.Task) {
	j := cast(^Read_Job)t.data
	j.out = Session {
		id      = strings.clone(strings.trim_suffix(j.file.name, ".jsonl"), j.allocator),
		path    = strings.clone(j.file.fullpath, j.allocator),
		project = strings.clone(j.project, j.allocator),
		mtime   = j.file.modification_time,
		size    = j.file.size,
	}
	session_read_summary(&j.out, j.allocator)
}

// Commands that count as checking the work. Only the command itself is read,
// so a thread that talks about tests is not one that ran them.
@(private = "file")
CHECK_WORDS :: [?]string{"test", "spec", "lint", "build", "check", "tsc", "mypy", "vet", "make "}

// Tools that change the work, and so put a passing check back out of date.
@(private = "file")
EDIT_TOOLS :: [?]string{`"name":"Edit"`, `"name":"Write"`, `"name":"MultiEdit"`, `"name":"NotebookEdit"`}

@(private = "file")
is_check_cmd :: proc(line: string) -> bool {
	i := strings.index(line, `"command":"`)
	if i < 0 do return false
	cmd := line[i + 11:]
	if j := strings.index_byte(cmd, '"'); j >= 0 do cmd = cmd[:j]
	if len(cmd) > 300 do cmd = cmd[:300]
	low := strings.to_lower(cmd, context.temp_allocator)
	for w in CHECK_WORDS do if strings.contains(low, w) do return true
	return false
}

@(private = "file")
HEAD_BYTES :: 64 * 1024
@(private = "file")
TAIL_BYTES :: 256 * 1024
// A thread this small that ran no tool and holds no more than a couple of
// prompts did not do anything: it is kept off the map. The size is also what
// makes the decision cheap — a file under it is read in full while deciding.
TRANSIENT_BYTES :: i64(100 * 1024)
TRANSIENT_PROMPTS :: 2

// Titles are written as their own records (`custom-title` beats `ai-title`)
// and land near the end of the file; the opening user prompt is the fallback,
// and the working directory is on every message record.
// Not file-private, unlike the rest of the reading here: `sessions_test.odin`
// drives it against a file it wrote, which is the only way to pin what a tail
// full of tool calls is supposed to come out as.
session_read_summary :: proc(s: ^Session, allocator: runtime.Allocator) {
	f, err := os.open(s.path)
	if err != nil do return
	defer os.close(f)

	head := make([]byte, min(int(s.size), max(HEAD_BYTES, int(TRANSIENT_BYTES) + 1)))
	defer delete(head)
	n, _ := os.read_at(f, head, 0)

	// A file small enough to be a throwaway is read right through, so the
	// count of prompts and of work done is exact. Anything bigger is not a
	// throwaway whatever it holds, so once the two fields this came for are
	// in hand the rest of it is skipped.
	small := s.size <= TRANSIENT_BYTES
	worked := false
	head_lines := each_line(string(head[:max(n, 0)]))
	for line in iter_next(&head_lines) {
		// Reading a record costs a JSON parse; counting one does not, and
		// most of a file is records this only has to count.
		if !worked && strings.contains(line, "\"tool_use\"") do worked = true
		is_prompt := strings.contains(line, "\"type\":\"user\"") && !strings.contains(line, "\"tool_result\"")
		if is_prompt do s.prompts += 1
		if s.cwd == "" || (s.preview == "" && is_prompt) {
			v, perr := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
			if perr == nil {
				if s.cwd == "" {
					if cwd := jstr(v, "cwd"); cwd != "" do s.cwd = strings.clone(cwd, allocator)
				}
				if s.preview == "" && jstr(v, "type") == "user" {
					if msg, ok := jobj(v, "message"); ok {
						if txt := verdict_unwrap(content_first_text(msg)); txt != "" {
							s.preview = strings.clone(one_line(txt, 200), allocator)
						}
					}
				}
			}
			free_all(context.temp_allocator)
		}
		if !small && s.cwd != "" && s.preview != "" do break
	}
	// Nothing was run and barely anything was said: a thread that was opened
	// and abandoned, or a question asked and answered in one breath.
	s.transient = small && !worked && s.prompts <= TRANSIENT_PROMPTS

	tail_off := max(s.size - TAIL_BYTES, 0)
	tail := make([]byte, int(s.size - tail_off))
	defer delete(tail)
	tn, _ := os.read_at(f, tail, tail_off)

	// Titles are written as their own records — a custom one beats the model's
	// — and the last prompt is what the row shows underneath.
	ai_title, custom_title, last_prompt: string
	defer delete(ai_title, allocator)
	defer delete(custom_title, allocator)
	defer delete(last_prompt, allocator)

	// Read in order: a check that ran, the result that came straight back from
	// it, and any edit after it that puts the answer out of date. String
	// tests rather than a parse — most of the tail is records this only has
	// to walk past.
	checked, check_failed, pending := false, false, false
	tail_lines := each_line(string(tail[:max(tn, 0)]))
	for line in iter_next(&tail_lines) {
		// The bookkeeping records Claude Code writes — mode, summary, queue
		// operations, and the three that carry a title — say their type
		// first, so a few bytes off the front of the line is enough to know
		// whether the rest of it is worth searching. A message record does
		// not lead with its type and falls through to the marker tests
		// below; everything else is walked past for the price of a prefix.
		switch line_type(line) {
		case "":
			if strings.contains(line, `"tool_use"`) {
				worked = true
				if is_check_cmd(line) {
					pending = true
				} else {
					for t in EDIT_TOOLS do if strings.contains(line, t) {
						checked = false // the work moved on since the last check
						break
					}
				}
			} else if pending && strings.contains(line, `"tool_result"`) {
				checked = true
				check_failed = strings.contains(line, `"is_error":true`)
				pending = false
			}
			continue
		case "custom-title", "ai-title", "last-prompt":
		case:
			continue
		}
		// Only a title record gets as far as a parse. This loop used to
		// parse every line — a quarter of a megabyte of JSON per session,
		// times every session on disk, which was most of the time the window
		// spent before it could draw anything at all.
		v, perr := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
		if perr == nil {
			switch jstr(v, "type") {
			case "custom-title":
				delete(custom_title, allocator)
				custom_title = strings.clone(jstr(v, "customTitle"), allocator)
			case "ai-title":
				delete(ai_title, allocator)
				ai_title = strings.clone(jstr(v, "aiTitle"), allocator)
			case "last-prompt":
				delete(last_prompt, allocator)
				last_prompt = strings.clone(verdict_unwrap(jstr(v, "lastPrompt")), allocator)
			}
		}
		free_all(context.temp_allocator)
	}

	title := custom_title != "" ? custom_title : ai_title
	if title == "" do title = last_prompt
	if title == "" do title = s.preview
	if title != "" do s.title = strings.clone(one_line(title, 120), allocator)
	if last_prompt != "" {
		delete(s.preview, allocator)
		s.preview = strings.clone(one_line(last_prompt, 200), allocator)
	}
	if s.cwd == "" {
		fallback := slug_to_path(s.project, context.temp_allocator)
		s.cwd = strings.clone(fallback, allocator)
	}
	switch {
	case !worked:
		s.verify = .None
	case !checked:
		s.verify = .Untested
	case check_failed:
		s.verify = .Failed
	case:
		s.verify = .Passed
	}
	s.guess = tag_guess(s.preview != "" ? s.preview : s.title, allocator)
}

// The `type` of a record, without parsing it — or "" for a message record,
// which puts its uuid first and so is not answered here.
@(private = "file")
line_type :: proc(line: string) -> string {
	PREFIX :: `{"type":"`
	if !strings.has_prefix(line, PREFIX) do return ""
	rest := line[len(PREFIX):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return rest[:end]
}

// Every thread of one task, read as one conversation. A task picked up three
// times is three files on disk and one piece of work in anyone's head, so the
// card for it opens as one transcript: the threads end to end, oldest first,
// with a rule between them saying where one stopped and the next began. What
// is typed underneath goes to the newest of them, which is the one still
// being worked on.
//
// `members` comes in oldest first. The chat takes the newest one's identity,
// so continuing it is continuing that thread and nothing here has to know the
// difference.
group_load :: proc(members: []Session) -> (chat: Chat, ok: bool) {
	if len(members) == 0 do return {}, false
	if len(members) == 1 do return session_load(&members[0])

	for &m, i in members {
		part, part_ok := session_load(&m)
		if !part_ok do continue

		// A rule, in the same voice the truncation notice uses.
		sys := chat_append(&chat, .System)
		ref := msg_append_block(&chat, sys, Block{kind = .Text})
		buf: [16]u8
		fmt.sbprintf(
			&chat_block(&chat, ref).text,
			"thread %d of %d  ·  %s  ·  %s",
			i + 1,
			len(members),
			relative_time(m.mtime, buf[:]),
			m.title,
		)

		// The messages move across whole: everything they own moves with
		// them, and the chat they came from is emptied rather than freed.
		for msg in part.msgs do append(&chat.msgs, msg)
		clear(&part.msgs)
		chat_destroy(&part)
		ok = true
	}
	if !ok do return {}, false

	newest := members[len(members) - 1]
	chat.session_id = strings.clone(newest.id)
	chat.cwd = strings.clone(newest.cwd)
	chat.title = strings.clone(newest.title)
	chat.path = strings.clone(newest.path)
	return chat, true
}

// Iterates the lines of `s` without allocating anything: each step yields a
// slice of the original bytes.
Line_Iter :: struct {
	rest: string,
}

each_line :: proc(s: string) -> Line_Iter {
	return Line_Iter{s}
}

iter_next :: proc(it: ^Line_Iter) -> (line: string, ok: bool) {
	if len(it.rest) == 0 do return "", false
	if idx := strings.index_byte(it.rest, '\n'); idx >= 0 {
		line = it.rest[:idx]
		it.rest = it.rest[idx + 1:]
	} else {
		line = it.rest
		it.rest = ""
	}
	return line, true
}

// The project directories are the cwd with every separator turned into a dash,
// which is not reversible — a path with a dash in it comes back wrong. It is
// only a fallback for sessions whose records carry no `cwd`.
slug_to_path :: proc(slug: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for ch in slug {
		strings.write_rune(&b, ch == '-' ? '/' : ch)
	}
	return strings.to_string(b)
}

session_clone :: proc(s: Session, allocator := context.allocator) -> Session {
	out := s
	out.id = strings.clone(s.id, allocator)
	out.path = strings.clone(s.path, allocator)
	out.project = strings.clone(s.project, allocator)
	out.cwd = strings.clone(s.cwd, allocator)
	out.title = strings.clone(s.title, allocator)
	out.preview = strings.clone(s.preview, allocator)
	out.guess = strings.clone(s.guess, allocator)
	return out
}

session_free :: proc(s: ^Session, allocator := context.allocator) {
	delete(s.id, allocator)
	delete(s.path, allocator)
	delete(s.project, allocator)
	delete(s.cwd, allocator)
	delete(s.guess, allocator)
	delete(s.title, allocator)
	delete(s.preview, allocator)
}

sessions_free :: proc(list: []Session, allocator := context.allocator) {
	for &s in list do session_free(&s, allocator)
	delete(list, allocator)
}

// --- reading a whole session ------------------------------------------------

// Parses the entire file into the same block structure the live runner builds.
// Tool results are folded into the tool call they answer, and a subagent's
// messages (which Claude Code marks as sidechains) are nested under the Task
// that spawned them rather than shown inline.
// Sessions can reach a hundred megabytes; only the tail is parsed, because
// nobody scrolls back through a hundred megabytes and blocking the window for
// seconds to prove otherwise is worse than saying so.
LOAD_TAIL_BYTES :: 8 << 20

session_load :: proc(s: ^Session) -> (chat: Chat, ok: bool) {
	f, ferr := os.open(s.path)
	if ferr != nil do return {}, false
	defer os.close(f)

	// How long the file is, asked of the file. `s.size` is the scan's opinion
	// of that, and the scan ran at most every ten seconds and not at all
	// while the thread on screen was streaming — so a thread being written
	// right now was read up to wherever it had got to when the sidebar last
	// looked, and everything after that was simply not there. Opening a card
	// that had been running for a while gave its opening prompt, a hole where
	// the work went, and then whatever the live stream had caught since:
	// the answer at the bottom with none of the steps that reached it.
	size, serr := os.file_size(f)
	if serr != nil do size = s.size

	offset := max(size - LOAD_TAIL_BYTES, 0)
	data := make([]byte, int(size - offset))
	defer delete(data)
	n, rerr := os.read_at(f, data, offset)
	if rerr != nil && n <= 0 do return {}, false
	body := string(data[:max(n, 0)])

	truncated := offset > 0
	if truncated {
		// Start at the first whole record.
		if idx := strings.index_byte(body, '\n'); idx >= 0 do body = body[idx + 1:]
	}

	chat.session_id = strings.clone(s.id)
	chat.cwd = strings.clone(s.cwd)
	chat.title = strings.clone(s.title)
	chat.path = strings.clone(s.path)

	if truncated {
		m := chat_append(&chat, .System)
		ref := msg_append_block(&chat, m, Block{kind = .Text})
		fmt.sbprintf(
			&chat_block(&chat, ref).text,
			"This session is %.0f MB; showing the last %d MB.",
			f64(size) / (1024 * 1024),
			LOAD_TAIL_BYTES / (1024 * 1024),
		)
	}

	last_task := NO_REF // the Task tool the current sidechain belongs to

	// One record at a time, freeing the parse as we go: a session this size
	// would otherwise leave a gigabyte of parsed JSON behind it.
	rest := body
	for len(rest) > 0 {
		line := rest
		if idx := strings.index_byte(rest, '\n'); idx >= 0 {
			line = rest[:idx]
			rest = rest[idx + 1:]
		} else {
			rest = ""
		}
		if len(line) < 2 do continue

		v, perr := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
		if perr != nil {
			free_all(context.temp_allocator)
			continue
		}

		kind := jstr(v, "type")
		sidechain := false
		if sv, has := jobj(v, "isSidechain"); has {
			b, is_bool := sv.(json.Boolean)
			sidechain = is_bool && bool(b)
		}

		switch kind {
		case "user":
			if msg, has := jobj(v, "message"); has {
				load_user_message(&chat, msg, sidechain, last_task)
			}
		case "assistant":
			if msg, has := jobj(v, "message"); has {
				task := load_assistant_message(&chat, msg, sidechain, last_task)
				if ref_valid(task) do last_task = task
			}
		}
		free_all(context.temp_allocator)
	}
	return chat, true
}

@(private = "file")
load_user_message :: proc(chat: ^Chat, msg: json.Value, sidechain: bool, task: Ref) {
	content, has := jobj(msg, "content")
	if !has do return

	// A plain string is a typed prompt; an array is tool results coming back.
	if txt, is_str := content.(json.String); is_str {
		if sidechain do return // the subagent's own prompt, already shown as the Task arg
		m := chat_append(chat, .User)
		ref := msg_append_block(chat, m, Block{kind = .Text})
		strings.write_string(&chat_block(chat, ref).text, verdict_unwrap(string(txt)))
		return
	}

	arr, is_arr := content.(json.Array)
	if !is_arr do return
	for item in arr {
		switch jstr(item, "type") {
		case "text":
			if sidechain do continue
			m := chat_append(chat, .User)
			ref := msg_append_block(chat, m, Block{kind = .Text})
			strings.write_string(&chat_block(chat, ref).text, verdict_unwrap(jstr(item, "text")))
		case "tool_result":
			target := chat_block(chat, chat_find_tool(chat, jstr(item, "tool_use_id")))
			if target == nil do continue
			target.running = false
			c, ok := jobj(item, "content")
			if !ok do continue
			write_result_content(target, c)
		}
	}
}

@(private = "file")
write_result_content :: proc(b: ^Block, content: json.Value) {
	if txt, is_str := content.(json.String); is_str {
		strings.write_string(&b.result, string(txt))
		return
	}
	if arr, is_arr := content.(json.Array); is_arr {
		for part in arr {
			if jstr(part, "type") == "text" {
				strings.write_string(&b.result, jstr(part, "text"))
			}
		}
	}
}

// Returns the Task block if this message started a subagent.
@(private = "file")
load_assistant_message :: proc(
	chat: ^Chat,
	msg: json.Value,
	sidechain: bool,
	task: Ref,
) -> Ref {
	content, has := jarr(msg, "content")
	if !has do return NO_REF

	new_task := NO_REF
	m := -1
	if !sidechain {
		last := chat_last(chat)
		if last >= 0 && chat.msgs[last].role == .Assistant {
			m = last
		} else {
			m = chat_append(chat, .Assistant)
		}
	}

	for item in content {
		block: Block
		switch jstr(item, "type") {
		case "text":
			t := verdict_unmark(jstr(item, "text"))
			if t == "" do continue
			block = Block{kind = .Text}
			strings.write_string(&block.text, t)
		case "tool_use":
			input, _ := jobj(item, "input")
			block = Block {
				kind    = .Tool,
				name    = strings.clone(jstr(item, "name")),
				tool_id = strings.clone(jstr(item, "id")),
				arg     = tool_summary(jstr(item, "name"), input),
			}
		case:
			continue
		}

		if sidechain {
			// Everything a subagent says hangs off the Task that started it.
			// A sidechain whose Task is not in the part of the file that was
			// read has nowhere to go; the block is already built, so it has to
			// be taken apart rather than dropped on the floor.
			owner := chat_block(chat, task)
			if owner == nil {
				block_destroy(&block)
				continue
			}
			append(&owner.sub, block)
		} else {
			ref := msg_append_block(chat, m, block)
			if block.kind == .Tool && block.name == "Task" do new_task = ref
		}
	}
	return new_task
}

// --- small string helpers ---------------------------------------------------

// What a thread looks like it is about, from the first thing asked of it: a
// bug, a question, a feature, a chore, an idea. Only used to search by, and
// only has to be right often enough to be worth typing.
tag_guess :: proc(text: string, allocator := context.allocator) -> string {
	if text == "" do return ""
	low := strings.to_lower(text, context.temp_allocator)
	Rule :: struct {
		kind:  string,
		words: []string,
	}
	rules := []Rule {
		{"bug", {"bug", "broken", "crash", "fix ", "fails", "failing", "error", "regression", "wrong", "doesn't work", "does not work", "not working", "hang", "freeze", "froze", "stuck", "leak", "weird", "janky", "glitch", "issue", "misaligned", "not centered", "too low", "too high", "off by"}},
		{"question", {"why ", "how do", "how does", "what is", "what does", "explain", "should i", "?"}},
		{"feature", {"add ", "implement", "support for", "build a", "build the", "create a", "make a", "new "}},
		{"chore", {"test ", "testing", "clean up", "cleanup", "refactor", "rename", "move the", "bump", "update the", "upgrade", "tidy", "remove the", "delete the"}},
		{"idea", {"what if", "idea", "maybe we", "could we", "brainstorm", "we should"}},
	}
	// First match in the text wins, so "fix the crash" beats a stray "add".
	best, at := "", len(low)
	for r in rules do for w in r.words {
		if i := strings.index(low, w); i >= 0 && i < at {
			best, at = r.kind, i
		}
	}
	return best == "" ? "" : strings.clone(best, allocator)
}

one_line :: proc(s: string, limit: int) -> string {
	out := strings.trim_space(s)
	if idx := strings.index_byte(out, '\n'); idx >= 0 do out = out[:idx]
	if len(out) > limit do out = out[:limit]
	return out
}

content_first_text :: proc(msg: json.Value) -> string {
	content, has := jobj(msg, "content")
	if !has do return ""
	if txt, is_str := content.(json.String); is_str do return string(txt)
	if arr, is_arr := content.(json.Array); is_arr {
		for item in arr {
			if jstr(item, "type") == "text" do return jstr(item, "text")
		}
	}
	return ""
}
