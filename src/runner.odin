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
	Msg_Start,
	Block_Start,
	Delta,
	Arg_Delta, // streaming tool input, shown as the tool's one-line summary
	Block_Stop,
	Tool_Result,
	Tool_Input, // the tool call's finished input, once it parses
	Verdict, // the agent's own word on whether the work is finished
	Limits, // how much of the plan's allowance is gone: see usage.odin
	Done,
	Failed,
}

Event :: struct {
	kind:       Ev_Kind,
	block_kind: Block_Kind,
	verdict:    Verdict,
	limits:     Limits,
	index:      int,
	// How big the request behind this message was, on `Msg_Start`: everything
	// the model was handed, the cached part included. See turns.odin.
	tokens:     int,
	text:       string, // owned by the event; the UI frees it after applying
	name:       string,
	id:         string,
	parent:     string, // the Task tool id, when this came from a subagent
}

// Which model the next turn runs on. The CLI takes the short aliases, and an
// empty string means "whatever the harness would have picked".
Model :: enum {
	Haiku,
	Sonnet,
	Opus,
	Fable,
}

// What goes on the CLI's --model: exact IDs, so "fable" can never drift to a
// different release than the one the picker shows.
model_flag := [Model]string {
	.Haiku  = "claude-haiku-4-5",
	.Sonnet = "claude-sonnet-5",
	.Opus   = "claude-opus-5",
	.Fable  = "claude-fable-5-1",
}

// The short name: what --model on our own command line and the saved choice
// use, and what older saves wrote.
model_short := [Model]string {
	.Haiku  = "haiku",
	.Sonnet = "sonnet",
	.Opus   = "opus",
	.Fable  = "fable",
}

model_label := [Model]string {
	.Haiku  = "Haiku 4.5",
	.Sonnet = "Sonnet 5",
	.Opus   = "Opus 5",
	.Fable  = "Fable 5.1",
}

MODEL_DEFAULT :: Model.Fable

// Accepts the short name or the full ID.
model_parse :: proc(name: string) -> (m: Model, ok: bool) {
	for c in Model do if model_short[c] == name || model_flag[c] == name do return c, true
	return MODEL_DEFAULT, false
}

// How hard the next turn thinks. The same choice the harness calls effort,
// and the same five words it takes on --effort, so nothing here has to map
// one vocabulary onto another.
Effort :: enum {
	Low,
	Medium,
	High,
	Xhigh,
	Max,
}

// What goes on the CLI's --effort, and what the saved choice and our own
// --effort read back.
effort_flag := [Effort]string {
	.Low    = "low",
	.Medium = "medium",
	.High   = "high",
	.Xhigh  = "xhigh",
	.Max    = "max",
}

effort_label := [Effort]string {
	.Low    = "Low",
	.Medium = "Medium",
	.High   = "High",
	.Xhigh  = "Xhigh",
	.Max    = "Max",
}

// Medium is what the harness itself would have picked, so a window that has
// never been told otherwise runs turns exactly as `claude` would.
EFFORT_DEFAULT :: Effort.Medium

effort_parse :: proc(name: string) -> (e: Effort, ok: bool) {
	for c in Effort do if effort_flag[c] == name do return c, true
	return EFFORT_DEFAULT, false
}

Runner :: struct {
	mu:      sync.Mutex,
	events:  [dynamic]Event,
	running: bool,
	failed:  bool,
	// The subtype of the last `result` record, empty when it said success.
	// The harness writes one of these every time it winds a turn up, and it
	// winds one up and carries on more often than it exits: an interrupted
	// turn gets a `result`, then a "continue from where you left off" and
	// another two minutes of work. Read at the end rather than acted on when
	// it arrives, because until the process is gone it is not the last one.
	result:  string,
	process: os.Process,
	worker:  ^thread.Thread,
	out_r:   ^os.File,
	err_path: string,
}

runner_busy :: proc(r: ^Runner) -> bool {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	return r.running
}

// No process and nothing left to read from the one that has gone. The turn is
// over for good, whether or not it ever said so.
runner_settled :: proc(r: ^Runner) -> bool {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	return !r.running && len(r.events) == 0
}

// The one run that is not a turn: the probe that asks what is left of the
// plan, which needs a stderr file of its own rather than turn zero's.
PROBE_SLOT :: -1

// Starts a turn. `session_id` empty means a brand new session.
// `slot` only names the file this turn's stderr goes to. Turns run several at
// a time and they all used to write one `last-stderr.log`, each truncating it
// as it started — so the reason a turn failed was as likely to be another
// turn's stderr, or nothing at all.
runner_start :: proc(
	r: ^Runner,
	cwd: string,
	session_id: string,
	prompt: string,
	model: string = "",
	effort: string = "",
	slot := 0,
) -> bool {
	if runner_busy(r) do return false

	args := make([dynamic]string, context.allocator)
	append(&args, "claude", "-p", prompt)
	append(&args, "--output-format", "stream-json", "--include-partial-messages", "--verbose")
	if model != "" do append(&args, "--model", model)
	if effort != "" do append(&args, "--effort", effort)
	if session_id != "" do append(&args, "--resume", session_id)

	out_r, out_w, pipe_err := os.pipe()
	if pipe_err != nil {
		runner_fail(r, fmt.tprintf("cannot create a pipe: %v", pipe_err))
		return false
	}

	// stderr goes to a file rather than a second pipe: nothing reads it until
	// the process is gone, and a pipe nobody drains would eventually wedge.
	err_path := cache_path(slot == PROBE_SLOT ? "probe-stderr.log" : fmt.tprintf("turn-%d-stderr.log", slot))
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
	delete(r.result)
	r.result = ""
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
	// A running flag with no process behind it can only come of a bug, but
	// the pid it carries is 0, and killing 0 is killing this whole process
	// group — the window, and every turn in it.
	if process.pid <= 0 do return
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
	// The stream is over, so this is the last `result` there will be.
	result := strings.clone(r.result, context.temp_allocator)
	sync.mutex_unlock(&r.mu)

	state, _ := os.process_wait(process)

	// One ending, and the process is what says so. The exit code first,
	// because it is the harness's own verdict on the whole run; the last
	// `result` after it, for a harness that reports an error and still exits
	// zero.
	if state.exit_code != 0 {
		msg := fmt.tprintf("claude exited with %d", state.exit_code)
		if result != "" do msg = fmt.tprintf("%s (%s)", msg, result)
		if data, ok := os.read_entire_file_from_path(err_path, context.temp_allocator); ok == nil {
			trimmed := strings.trim_space(string(data))
			if trimmed != "" do msg = fmt.tprintf("%s\n%s", msg, one_line(trimmed, 400))
		}
		runner_emit(r, Event{kind = .Failed, text = strings.clone(msg)})
	} else if result != "" {
		runner_emit(r, Event{kind = .Failed, text = strings.clone(result)})
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
		// Only `init` is worth anything here. The harness also reports its
		// own progress through a request — `requesting` and friends — and
		// that was fed straight to the status line, so the bottom-left of the
		// grid sat there reading "requesting" over a wall of cards that
		// already say what they are doing. It also overwrote the lines the
		// window writes for itself, the ones nobody is around to see twice:
		// a failed build, a push that was refused.
		switch jstr(v, "subtype") {
		case "init":
			runner_emit(r, Event{kind = .Session, id = strings.clone(jstr(v, "session_id"))})
		}

	case "stream_event":
		ev, has := jobj(v, "event")
		if !has do return
		index := jint(ev, "index")
		switch jstr(ev, "type") {
		case "message_start":
			// The size of the context, off the harness's own reckoning rather
			// than anything counted here. It is on the first record of every
			// message and it is the whole of what was sent: the fresh part,
			// the part written into the cache and the part read back out of
			// it. Read as one number because it is one question — how much
			// the model was given — and splitting it into cached and not is
			// a question about the bill, which this window does not answer.
			runner_emit(r, Event{kind = .Msg_Start, tokens = msg_tokens(ev), parent = strings.clone(parent)})
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
		say := strings.builder_make(context.temp_allocator)
		for item in content {
			if jstr(item, "type") == "text" {
				strings.write_string(&say, jstr(item, "text"))
				continue
			}
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
		// Off the finished message rather than the deltas: the marker is one
		// line and the deltas cut it wherever the bytes happened to arrive.
		// Only the agent's own messages, never a subagent's — a Task that
		// reports itself done has finished a piece of the work, not the card.
		if parent == "" {
			text := strings.to_string(say)
			if v := verdict_read(text); v != .None {
				runner_emit(r, Event{kind = .Verdict, verdict = v, text = verdict_say(text, context.allocator)})
			}
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

	case "rate_limit_event":
		// The account's own answer, not this turn's: what is left of the five
		// hour window and of the week, which is what `/usage` reports. Any
		// turn's stream carries it, so the newest reading is the whole of it
		// — and it goes out as an event rather than being kept here, because
		// a runner is thrown away with its slot and this outlives every turn.
		info, ok := jobj(v, "rate_limit_info")
		if !ok do return
		windows, has_windows := jobj(info, "unifiedWindows")
		if !has_windows do return
		lim: Limits
		if w, has := jobj(windows, "five_hour"); has {
			lim.session = {util = f32(jnum(w, "utilization")), resets = i64(jint(w, "resetsAt"))}
		}
		if w, has := jobj(windows, "seven_day"); has {
			lim.week = {util = f32(jnum(w, "utilization")), resets = i64(jint(w, "resetsAt"))}
		}
		// Fable's own week, under the name the harness gives it. It is only on
		// the record when the turn reading it is running on Fable — the other
		// models are not charged against it and are not told about it — which
		// is why the reading is merged window by window rather than assigned.
		if w, has := jobj(windows, "seven_day_overage_included"); has {
			lim.fable = {util = f32(jnum(w, "utilization")), resets = i64(jint(w, "resetsAt"))}
		}
		runner_emit(r, Event{kind = .Limits, limits = lim})

	case "result":
		// `total_cost_usd` and the token counts are on this record and are
		// read by nobody: on a subscription the price is never charged, and
		// what the corner says is what is left of the windows. See usage.odin.
		// Written down, not reported. A turn that says `error_during_execution`
		// and then picks itself back up and finishes is a turn that finished
		// — and reporting the first of those ended the card two minutes
		// before the process it was watching had done the work, red, while
		// the thread it came from went on to say the build and the tests
		// passed.
		sub := jstr(v, "subtype")
		sync.mutex_lock(&r.mu)
		delete(r.result)
		r.result = strings.clone(sub == "success" ? "" : sub)
		sync.mutex_unlock(&r.mu)
	}
}

// What the model was handed for one message, off the `usage` on its
// `message_start`. Zero when the record carries no usage at all, which reads
// on screen as nothing rather than as an empty context.
@(private = "file")
msg_tokens :: proc(ev: json.Value) -> int {
	msg, has := jobj(ev, "message")
	if !has do return 0
	u, has_usage := jobj(msg, "usage")
	if !has_usage do return 0
	return jint(u, "input_tokens") + jint(u, "cache_creation_input_tokens") + jint(u, "cache_read_input_tokens")
}

// A number that may have come back as either shape, as a float. The
// utilizations are fractions and arrive as floats; a zero one arrives as an
// integer.
jnum :: proc(v: json.Value, key: string) -> f64 {
	val, ok := jobj(v, key)
	if !ok do return 0
	#partial switch n in val {
	case json.Float:
		return f64(n)
	case json.Integer:
		return f64(n)
	}
	return 0
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
	delete(r.result)
}
