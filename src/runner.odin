package aithing

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

// The whole point of this program: the harness is the real `claude` CLI, run
// in print mode with the JSON stream turned on. Nothing here reimplements any
// part of Claude Code — it starts a process, reads NDJSON off its stdout and
// turns each record into an event the UI applies to the transcript.
//
//   claude -p <prompt> --output-format stream-json --include-partial-messages
//          --verbose [--resume <id>] [--permission-mode <mode>]

Ev_Kind :: enum {
	Session, // the id to --resume next time
	Status,
	Msg_Start,
	Block_Start,
	Delta,
	Arg_Delta, // streaming tool input, shown as the tool's one-line summary
	Block_Stop,
	Tool_Result,
	Tool_Input, // the tool call's finished input, once it parses
	Done,
	Failed,
}

Event :: struct {
	kind:       Ev_Kind,
	block_kind: Block_Kind,
	index:      int,
	text:       string, // owned by the event; the UI frees it after applying
	name:       string,
	id:         string,
	parent:     string, // the Task tool id, when this came from a subagent
}

// Which model the next turn runs on. The CLI takes the short aliases, and an
// empty string means "whatever the harness would have picked".
Model :: enum {
	Default,
	Haiku,
	Sonnet,
	Opus,
}

model_flag := [Model]string {
	.Default = "",
	.Haiku   = "haiku",
	.Sonnet  = "sonnet",
	.Opus    = "opus",
}

model_label := [Model]string {
	.Default = "auto",
	.Haiku   = "haiku",
	.Sonnet  = "sonnet",
	.Opus    = "opus",
}

Runner :: struct {
	mu:      sync.Mutex,
	events:  [dynamic]Event,
	running: bool,
	failed:  bool,
	process: os.Process,
	worker:  ^thread.Thread,
	out_r:   ^os.File,
	err_path: string,
	cost:    f64,
}

runner_busy :: proc(r: ^Runner) -> bool {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	return r.running
}

// Starts a turn. `session_id` empty means a brand new session.
runner_start :: proc(
	r: ^Runner,
	cwd: string,
	session_id: string,
	prompt: string,
	model: string = "",
) -> bool {
	if runner_busy(r) do return false

	args := make([dynamic]string, context.allocator)
	append(&args, "claude", "-p", prompt)
	append(&args, "--output-format", "stream-json", "--include-partial-messages", "--verbose")
	if model != "" do append(&args, "--model", model)
	if session_id != "" do append(&args, "--resume", session_id)

	out_r, out_w, pipe_err := os.pipe()
	if pipe_err != nil {
		runner_fail(r, fmt.tprintf("cannot create a pipe: %v", pipe_err))
		return false
	}

	// stderr goes to a file rather than a second pipe: nothing reads it until
	// the process is gone, and a pipe nobody drains would eventually wedge.
	err_path := cache_path("last-stderr.log")
	err_file, err_open := os.open(err_path, {.Write, .Create, .Trunc})
	if err_open != nil do err_file = nil

	desc := os.Process_Desc {
		command     = args[:],
		working_dir = cwd,
		stdout      = out_w,
		stderr      = err_file,
	}
	process, start_err := os.process_start(desc)
	os.close(out_w) // the child owns the writing end now
	if err_file != nil do os.close(err_file)
	delete(args)

	if start_err != nil {
		os.close(out_r)
		runner_fail(r, fmt.tprintf("cannot run claude: %v", start_err))
		return false
	}

	sync.mutex_lock(&r.mu)
	r.running = true
	r.failed = false
	r.process = process
	r.out_r = out_r
	delete(r.err_path)
	r.err_path = strings.clone(err_path)
	sync.mutex_unlock(&r.mu)

	r.worker = thread.create_and_start_with_poly_data(r, runner_thread)
	return true
}

// Stops the turn. The process gets a chance to exit on its own; the reader
// thread notices the closed pipe and finishes.
runner_stop :: proc(r: ^Runner) {
	sync.mutex_lock(&r.mu)
	running := r.running
	process := r.process
	sync.mutex_unlock(&r.mu)
	if !running do return
	_ = os.process_kill(process)
}

@(private = "file")
runner_fail :: proc(r: ^Runner, msg: string) {
	runner_emit(r, Event{kind = .Failed, text = strings.clone(msg)})
	sync.mutex_lock(&r.mu)
	r.running = false
	r.failed = true
	sync.mutex_unlock(&r.mu)
}

@(private = "file")
runner_emit :: proc(r: ^Runner, ev: Event) {
	sync.mutex_lock(&r.mu)
	append(&r.events, ev)
	sync.mutex_unlock(&r.mu)
}

// Hands the UI everything that arrived since the last call. The caller owns
// the returned slice and the strings inside it.
runner_drain :: proc(r: ^Runner, allocator := context.allocator) -> []Event {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	if len(r.events) == 0 do return nil
	out := make([]Event, len(r.events), allocator)
	copy(out, r.events[:])
	clear(&r.events)
	return out
}

@(private = "file")
runner_thread :: proc(r: ^Runner) {
	buf: [64 * 1024]byte
	pending := strings.builder_make()
	defer strings.builder_destroy(&pending)

	for {
		n, err := os.read(r.out_r, buf[:])
		if err != nil || n <= 0 do break
		strings.write_bytes(&pending, buf[:n])

		// NDJSON: complete lines only, whatever is left waits for more bytes.
		text := strings.to_string(pending)
		start := 0
		for {
			idx := strings.index_byte(text[start:], '\n')
			if idx < 0 do break
			line := text[start:start + idx]
			start += idx + 1
			if len(strings.trim_space(line)) > 0 do runner_line(r, line)
		}
		if start > 0 {
			rest := strings.clone(text[start:], context.temp_allocator)
			strings.builder_reset(&pending)
			strings.write_string(&pending, rest)
		}
		free_all(context.temp_allocator)
	}

	os.close(r.out_r)

	sync.mutex_lock(&r.mu)
	process := r.process
	err_path := strings.clone(r.err_path, context.temp_allocator)
	sync.mutex_unlock(&r.mu)

	state, _ := os.process_wait(process)

	if state.exit_code != 0 {
		msg := fmt.tprintf("claude exited with %d", state.exit_code)
		if data, ok := os.read_entire_file_from_path(err_path, context.temp_allocator); ok == nil {
			trimmed := strings.trim_space(string(data))
			if trimmed != "" do msg = fmt.tprintf("%s\n%s", msg, one_line(trimmed, 400))
		}
		runner_emit(r, Event{kind = .Failed, text = strings.clone(msg)})
	}

	sync.mutex_lock(&r.mu)
	r.running = false
	sync.mutex_unlock(&r.mu)
	runner_emit(r, Event{kind = .Done})
	free_all(context.temp_allocator)
}

// One NDJSON record. The shapes here are the CLI's stream-json output: a
// `system`/`init` record with the session id, the raw Anthropic streaming
// events under `stream_event`, whole `assistant`/`user` messages, and a
// `result` record at the end.
@(private = "file")
runner_line :: proc(r: ^Runner, line: string) {
	v, err := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
	if err != nil do return

	parent := jstr(v, "parent_tool_use_id")

	switch jstr(v, "type") {
	case "system":
		switch jstr(v, "subtype") {
		case "init":
			runner_emit(r, Event{kind = .Session, id = strings.clone(jstr(v, "session_id"))})
		case "status":
			runner_emit(r, Event{kind = .Status, text = strings.clone(jstr(v, "status"))})
		}

	case "stream_event":
		ev, has := jobj(v, "event")
		if !has do return
		index := jint(ev, "index")
		switch jstr(ev, "type") {
		case "message_start":
			runner_emit(r, Event{kind = .Msg_Start, parent = strings.clone(parent)})
		case "content_block_start":
			cb, ok := jobj(ev, "content_block")
			if !ok do return
			out := Event {
				kind   = .Block_Start,
				index  = index,
				parent = strings.clone(parent),
			}
			switch jstr(cb, "type") {
			case "text":
				out.block_kind = .Text
			case "thinking":
				out.block_kind = .Thinking
			case "tool_use":
				out.block_kind = .Tool
				out.name = strings.clone(jstr(cb, "name"))
				out.id = strings.clone(jstr(cb, "id"))
			case:
				delete(out.parent)
				return
			}
			runner_emit(r, out)
		case "content_block_delta":
			d, ok := jobj(ev, "delta")
			if !ok do return
			switch jstr(d, "type") {
			case "text_delta":
				runner_emit(r, Event{kind = .Delta, index = index, text = strings.clone(jstr(d, "text")), parent = strings.clone(parent)})
			case "thinking_delta":
				runner_emit(r, Event{kind = .Delta, index = index, text = strings.clone(jstr(d, "thinking")), parent = strings.clone(parent)})
			case "input_json_delta":
				runner_emit(r, Event{kind = .Arg_Delta, index = index, text = strings.clone(jstr(d, "partial_json")), parent = strings.clone(parent)})
			}
		case "content_block_stop":
			runner_emit(r, Event{kind = .Block_Stop, index = index, parent = strings.clone(parent)})
		}

	case "assistant":
		// The finished message. The text was already streamed; what is worth
		// taking from it is each tool call's parsed input, which is nicer than
		// the half-escaped JSON the deltas carry.
		msg, has := jobj(v, "message")
		if !has do return
		content, is_arr := jarr(msg, "content")
		if !is_arr do return
		for item in content {
			if jstr(item, "type") != "tool_use" do continue
			input, _ := jobj(item, "input")
			name := jstr(item, "name")
			runner_emit(r, Event{
				kind = .Tool_Input,
				id   = strings.clone(jstr(item, "id")),
				name = strings.clone(name),
				text = tool_summary(name, input),
			})
		}

	case "user":
		msg, has := jobj(v, "message")
		if !has do return
		content, is_arr := jarr(msg, "content")
		if !is_arr do return
		for item in content {
			if jstr(item, "type") != "tool_result" do continue
			b := strings.builder_make()
			if c, ok := jobj(item, "content"); ok {
				if txt, is_str := c.(json.String); is_str {
					strings.write_string(&b, string(txt))
				} else if parts, is_parts := c.(json.Array); is_parts {
					for part in parts {
						if jstr(part, "type") == "text" do strings.write_string(&b, jstr(part, "text"))
					}
				}
			}
			runner_emit(r, Event{
				kind = .Tool_Result,
				id   = strings.clone(jstr(item, "tool_use_id")),
				text = strings.to_string(b),
			})
		}

	case "result":
		if cost, ok := jobj(v, "total_cost_usd"); ok {
			if f, is_f := cost.(json.Float); is_f {
				sync.mutex_lock(&r.mu)
				r.cost += f64(f)
				sync.mutex_unlock(&r.mu)
			}
		}
		if jstr(v, "subtype") != "success" && jstr(v, "subtype") != "" {
			runner_emit(r, Event{kind = .Failed, text = strings.clone(jstr(v, "subtype"))})
		}
	}
}

jint :: proc(v: json.Value, key: string) -> int {
	val, ok := jobj(v, key)
	if !ok do return 0
	#partial switch n in val {
	case json.Integer:
		return int(n)
	case json.Float:
		return int(n)
	}
	return 0
}

event_destroy :: proc(e: ^Event) {
	delete(e.text)
	delete(e.name)
	delete(e.id)
	delete(e.parent)
}

runner_destroy :: proc(r: ^Runner) {
	runner_stop(r)
	if r.worker != nil do thread.destroy(r.worker)
	for &e in r.events do event_destroy(&e)
	delete(r.events)
	delete(r.err_path)
}
