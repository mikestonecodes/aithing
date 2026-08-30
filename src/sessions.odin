package aithing

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
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
}

claude_home :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	path, _ := filepath.join({home, ".claude", "projects"}, allocator)
	return path
}

// Every session on disk, newest first. Only the head and tail of each file are
// read: enough for the title and the last prompt, and cheap enough that a few
// hundred sessions still list instantly.
sessions_scan :: proc(allocator := context.allocator) -> []Session {
	root := claude_home(context.temp_allocator)
	out := make([dynamic]Session, allocator)

	// Not the temp allocator: reading a session's summary resets it between
	// records, and these are held across all of them.
	dirs, derr := os.read_all_directory_by_path(root, context.allocator)
	if derr != nil do return out[:]
	defer os.file_info_slice_delete(dirs, context.allocator)

	for d in dirs {
		if d.type != .Directory do continue
		files, ferr := os.read_all_directory_by_path(d.fullpath, context.allocator)
		if ferr != nil do continue
		defer os.file_info_slice_delete(files, context.allocator)

		for f in files {
			if !strings.has_suffix(f.name, ".jsonl") do continue
			if f.size == 0 do continue
			s := Session {
				id      = strings.clone(strings.trim_suffix(f.name, ".jsonl"), allocator),
				path    = strings.clone(f.fullpath, allocator),
				project = strings.clone(d.name, allocator),
				mtime   = f.modification_time,
				size    = f.size,
			}
			session_read_summary(&s, allocator)
			if s.title == "" do continue // nothing but metadata in it
			append(&out, s)
		}
	}

	slice.sort_by(out[:], proc(a, b: Session) -> bool {
		return time.time_to_unix_nano(a.mtime) > time.time_to_unix_nano(b.mtime)
	})
	return out[:]
}

@(private = "file")
HEAD_BYTES :: 64 * 1024
@(private = "file")
TAIL_BYTES :: 256 * 1024

// Titles are written as their own records (`custom-title` beats `ai-title`)
// and land near the end of the file; the opening user prompt is the fallback,
// and the working directory is on every message record.
@(private = "file")
session_read_summary :: proc(s: ^Session, allocator: runtime.Allocator) {
	f, err := os.open(s.path)
	if err != nil do return
	defer os.close(f)

	head := make([]byte, min(int(s.size), HEAD_BYTES))
	defer delete(head)
	n, _ := os.read_at(f, head, 0)

	head_lines := each_line(string(head[:max(n, 0)]))
	for line in iter_next(&head_lines) {
		v, perr := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
		if perr == nil {
			if s.cwd == "" {
				if cwd := jstr(v, "cwd"); cwd != "" do s.cwd = strings.clone(cwd, allocator)
			}
			if s.preview == "" && jstr(v, "type") == "user" {
				if msg, ok := jobj(v, "message"); ok {
					if txt := content_first_text(msg); txt != "" {
						s.preview = strings.clone(one_line(txt, 200), allocator)
					}
				}
			}
		}
		free_all(context.temp_allocator)
		if s.cwd != "" && s.preview != "" do break
	}

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

	tail_lines := each_line(string(tail[:max(tn, 0)]))
	for line in iter_next(&tail_lines) {
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
				last_prompt = strings.clone(jstr(v, "lastPrompt"), allocator)
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
	for ch, i in slug {
		if ch == '-' && i == 0 do continue
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
	return out
}

session_free :: proc(s: ^Session, allocator := context.allocator) {
	delete(s.id, allocator)
	delete(s.path, allocator)
	delete(s.project, allocator)
	delete(s.cwd, allocator)
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

	offset := max(s.size - LOAD_TAIL_BYTES, 0)
	data := make([]byte, int(s.size - offset))
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
			f64(s.size) / (1024 * 1024),
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
		strings.write_string(&chat_block(chat, ref).text, string(txt))
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
			strings.write_string(&chat_block(chat, ref).text, jstr(item, "text"))
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
			t := jstr(item, "text")
			if strings.trim_space(t) == "" do continue
			block = Block{kind = .Text}
			strings.write_string(&block.text, t)
		case "thinking":
			// Thinking is not always kept in the session file; an empty one
			// would just be a row that says "Thinking" and opens onto nothing.
			t := jstr(item, "thinking")
			if strings.trim_space(t) == "" do continue
			block = Block{kind = .Thinking}
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
