package aithing

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"

// The whole point of this program: the harness is the real `claude` CLI, run
// in print mode with the JSON stream turned on. Nothing here reimplements any
// part of Claude Code — it starts a process, reads NDJSON off its stdout and
// turns each record into an event the UI applies to the transcript.
//
//   claude -p <prompt> --output-format stream-json --include-partial-messages
//          --verbose --chrome [--resume <id>] [--model <id>] [--effort <level>]

Ev_Kind :: enum {
	Session, // the id to --resume next time
	Msg_Start,
	Block_Start,
	Delta,
	Arg_Delta, // a slice of the tool's input JSON, as the model types it
	Block_Stop,
	Tool_Result,
	Tool_Input, // the tool call's whole input, once it parses
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
	// Written before this window was watching: see Runner.replay_to.
	replay:     bool,
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
	.Opus   = "claude-opus-5-5",
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
	.Opus   = "Opus 5.5",
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

// A turn outlives the window that started it. Closing the window used to kill
// every `claude` it had running: on the way out it stopped them by hand, and
// had it not, each one's stdout was a pipe into this process and the next
// write after the window went would have been a SIGPIPE. Work you had set
// going stopped the moment you closed the lid on it.
//
// So a turn is a directory, not a pipe. The harness writes its stream to
// `out` and its stderr to `err`, and runs under a shell that writes the exit
// code to `exit` once it is gone — the one thing that cannot be had from a
// process this window is no longer the parent of. The whole lot runs under
// `setsid`, out of this window's session and process group, so neither a
// terminal closing nor a Ctrl-C reaches it. The reader tails `out`, and the
// window that opens next finds the directory still there and tails it again
// from the top (see turns_adopt).
//
// The window holding a run holds an flock on `lock`, which is how a second
// window open at the same time knows not to adopt it too and land the same
// card twice. The kernel lets go of it when the window dies, however it dies.
RUN_SCRIPT :: `"$@"; echo $? >"$0/exit.tmp" && mv "$0/exit.tmp" "$0/exit"`

// How long the reader waits at the end of `out` before looking again. A pipe
// woke it the moment there was more; a file cannot, and a tenth of this is
// below anything a person reading along can tell apart.
RUN_POLL :: 25 * time.Millisecond

Runner :: struct {
	mu:        sync.Mutex,
	events:    [dynamic]Event,
	running:   bool,
	failed:    bool,
	// The subtype of the last `result` record, empty when it said success.
	// The harness writes one of these every time it winds a turn up, and it
	// winds one up and carries on more often than it exits: an interrupted
	// turn gets a `result`, then a "continue from where you left off" and
	// another two minutes of work. Read at the end rather than acted on when
	// it arrives, because until the process is gone it is not the last one.
	result:    string,
	// The shell under `setsid`: its pid is its process group, which is what
	// a stop kills, so the tools the harness started go with it.
	pid:       int,
	// Only a run this window started is its child, and only a child can be
	// waited for. One adopted from a window since closed belongs to init.
	process:   os.Process,
	owned:     bool,
	dir:       string,
	lock:      ^os.File,
	worker:    ^thread.Thread,
	// The window is going and the process is not: the reader stops without
	// saying the turn ended, because it has not.
	detach:    bool,
	// How much of `out` was already written when this window adopted the
	// run. Those records happened while nobody was watching; they are read
	// for what they say about the turn, and marked so the transcript does not
	// draw them a second time over the thread it has just read off disk.
	replay_to: i64,
	replaying: bool,
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
// plan. It is killed as soon as it has answered, so it is never adopted and
// has one directory it reuses rather than a new one per launch.
PROBE_SLOT :: -1

// Starts a turn. `session_id` empty means a brand new session. `slot` goes
// into the name of the run's directory, which only has to be unique.
runner_start :: proc(
	r: ^Runner,
	cwd: string,
	session_id: string,
	prompt: string,
	model: string = "",
	effort: string = "",
	slot := 0,
) -> bool {
	probe := slot == PROBE_SLOT
	dir := cache_path(probe ? "probe" : fmt.tprintf("runs/%d-%d", time.now()._nsec, slot))
	return runner_start_in(r, dir, cwd, session_id, prompt, model, effort, probe)
}

// The same, in a directory the caller names. Only the tests name one: the
// cache is shared by every test in the suite, and one of them clears it.
runner_start_in :: proc(r: ^Runner, dir, cwd, session_id, prompt, model, effort: string, probe := false) -> bool {
	if runner_busy(r) do return false
	runner_detach(r)
	runner_unlock(r)

	if err := os.make_directory_all(dir); err != nil {
		runner_fail(r, fmt.tprintf("cannot make %s: %v", dir, err))
		return false
	}
	lock: ^os.File
	if !probe {
		lock = run_lock(dir)
		if lock == nil {
			runner_fail(r, fmt.tprintf("cannot lock %s", dir))
			_ = os.remove_all(dir)
			return false
		}
	}
	_ = os.remove(run_file(dir, "exit"))

	args := make([dynamic]string, context.temp_allocator)
	append(&args, "setsid", "sh", "-c", RUN_SCRIPT, dir)
	append(&args, "claude", "-p", prompt)
	append(&args, "--output-format", "stream-json", "--include-partial-messages", "--verbose")
	if model != "" do append(&args, "--model", model)
	if effort != "" do append(&args, "--effort", effort)
	if session_id != "" do append(&args, "--resume", session_id)
	// The browser tools: without this a card cannot open a page to look at
	// what it built. The CLI only offers them when asked, whatever the
	// settings say. The probe only says "hi", so it goes without them.
	if !probe do append(&args, "--chrome")

	out, out_err := os.open(run_file(dir, "out"), {.Write, .Create, .Trunc})
	if out_err != nil {
		if lock != nil do os.close(lock)
		runner_fail(r, fmt.tprintf("cannot write %s: %v", dir, out_err))
		return false
	}
	// stderr goes to a file of its own: nothing reads it until the process is
	// gone, and then only to say why it failed.
	err_file, err_open := os.open(run_file(dir, "err"), {.Write, .Create, .Trunc})
	if err_open != nil do err_file = nil

	desc := os.Process_Desc {
		command     = args[:],
		working_dir = cwd,
		stdout      = out,
		stderr      = err_file,
	}
	process, start_err := os.process_start(desc)
	os.close(out)
	if err_file != nil do os.close(err_file)

	if start_err != nil {
		if lock != nil do os.close(lock)
		if !probe do _ = os.remove_all(dir)
		runner_fail(r, fmt.tprintf("cannot run claude: %v", start_err))
		return false
	}
	// For the window that adopts this run if this one closes first. `setsid`
	// execs in place when its caller does not lead a process group, which a
	// freshly forked child never does, so this is the shell's pid.
	_ = os.write_entire_file(run_file(dir, "pid"), fmt.tprintf("%d", process.pid))

	sync.mutex_lock(&r.mu)
	r.running = true
	r.failed = false
	delete(r.result)
	r.result = ""
	r.process = process
	r.pid = process.pid
	r.owned = true
	delete(r.dir)
	r.dir = strings.clone(dir)
	r.lock = lock
	r.detach = false
	r.replay_to = 0
	r.replaying = false
	sync.mutex_unlock(&r.mu)

	r.worker = thread.create_and_start_with_poly_data(r, runner_thread)
	return true
}

// Picks up a run a window since closed left going, or left finished and not
// yet read. False when another window already holds it.
runner_adopt :: proc(r: ^Runner, dir: string, pid: int) -> bool {
	lock := run_lock(dir)
	if lock == nil do return false
	size: i64
	if info, err := os.stat(run_file(dir, "out"), context.temp_allocator); err == nil do size = info.size

	sync.mutex_lock(&r.mu)
	r.running = true
	r.pid = pid
	r.owned = false
	r.dir = strings.clone(dir)
	r.lock = lock
	r.replay_to = size
	r.replaying = size > 0
	sync.mutex_unlock(&r.mu)

	r.worker = thread.create_and_start_with_poly_data(r, runner_thread)
	return true
}

// The directory's name for one of the files in it.
run_file :: proc(dir, name: string) -> string {
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

// Close-on-exec, as everything os.open makes is: a lock the harness inherited
// would be held by the process the lock is about, and never let go.
@(private = "file")
run_lock :: proc(dir: string) -> ^os.File {
	f, err := os.open(run_file(dir, "lock"), {.Write, .Create})
	if err != nil do return nil
	if linux.flock(linux.Fd(os.fd(f)), {.EX, .NB}) != .NONE {
		os.close(f)
		return nil
	}
	return f
}

// Whether the shell behind a run is still there. A child of this window is
// asked only whether it has exited: its pid cannot be anybody else's until it
// has been waited for, and for the first moment after the fork its command
// line is still this window's, which read as a run that had gone before it
// began. Anything else is also asked by its command line, because a run left
// over from before a reboot names a pid that may well be some other process
// by now, and killing that one on a stop would be a great deal worse than a
// turn read as gone.
@(private = "file")
run_alive :: proc(pid: int, dir: string, owned: bool) -> bool {
	if pid <= 0 do return false
	stat, err := os.read_entire_file_from_path(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil do return false
	// The state is the field after the name, and the name is in parentheses
	// and may hold anything, so it is found from the last one.
	if at := strings.last_index_byte(string(stat), ')'); at < 0 || at + 2 >= len(stat) || stat[at + 2] == 'Z' do return false
	if owned do return true
	data, cmd_err := os.read_entire_file_from_path(fmt.tprintf("/proc/%d/cmdline", pid), context.temp_allocator)
	if cmd_err != nil do return false
	return strings.contains(string(data), dir)
}

// The exit code the shell wrote down, if it has.
@(private = "file")
run_exit :: proc(dir: string) -> (code: int, ok: bool) {
	data, err := os.read_entire_file_from_path(run_file(dir, "exit"), context.temp_allocator)
	if err != nil do return 0, false
	return strconv.parse_int(strings.trim_space(string(data)))
}

// Stops the turn: the whole process group, the harness and whatever it has
// running. The reader sees the shell gone and finishes.
runner_stop :: proc(r: ^Runner) {
	sync.mutex_lock(&r.mu)
	running := r.running
	pid := r.pid
	owned := r.owned
	dir := strings.clone(r.dir, context.temp_allocator)
	sync.mutex_unlock(&r.mu)
	if !running do return
	// A running flag with no process behind it can only come of a bug, but
	// the pid it carries is 0, and killing 0 is killing this whole process
	// group — the window, and every turn in it.
	if !run_alive(pid, dir, owned) do return
	_ = linux.kill(linux.Pid(-pid), .SIGKILL)
	// And the pid on its own, for a child stopped before `setsid` has made
	// it a group: there is no group -pid yet.
	_ = linux.kill(linux.Pid(pid), .SIGKILL)
}

// Lets go of the run without stopping it: the reader goes, the process stays.
runner_detach :: proc(r: ^Runner) {
	sync.mutex_lock(&r.mu)
	r.detach = true
	sync.mutex_unlock(&r.mu)
	if r.worker != nil do thread.destroy(r.worker)
	r.worker = nil
}

@(private = "file")
runner_unlock :: proc(r: ^Runner) {
	if r.lock != nil do os.close(r.lock)
	r.lock = nil
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
	ev := ev
	sync.mutex_lock(&r.mu)
	ev.replay = r.replaying
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

	sync.mutex_lock(&r.mu)
	dir := strings.clone(r.dir)
	pid := r.pid
	owned := r.owned
	replay_to := r.replay_to
	sync.mutex_unlock(&r.mu)
	defer delete(dir)

	f, open_err := os.open(run_file(dir, "out"))
	if open_err != nil {
		runner_fail(r, fmt.tprintf("cannot read %s: %v", dir, open_err))
		runner_emit(r, Event{kind = .Done})
		return
	}

	// The file offset `pending` starts at, so each line knows whether it was
	// written before this window adopted the run.
	at: i64
	code, exited := 0, false
	for {
		sync.mutex_lock(&r.mu)
		detach := r.detach
		sync.mutex_unlock(&r.mu)
		if detach {
			os.close(f)
			return
		}

		// Asked before the read, not after: `exit` is written once the
		// harness has closed its stdout, so a read that comes up empty after
		// it has been seen really is the end.
		code, exited = run_exit(dir)
		over := exited || !run_alive(pid, dir, owned)
		if over && !exited do code, exited = run_exit(dir) // wrote it as it went

		n, err := os.read(f, buf[:])
		if err != nil && err != .EOF do break
		if n <= 0 {
			if over do break
			time.sleep(RUN_POLL)
			continue
		}
		strings.write_bytes(&pending, buf[:n])

		// NDJSON: complete lines only, whatever is left waits for more bytes.
		text := strings.to_string(pending)
		start := 0
		for {
			idx := strings.index_byte(text[start:], '\n')
			if idx < 0 do break
			line := text[start:start + idx]
			start += idx + 1
			r.replaying = at + i64(start) <= replay_to
			if len(strings.trim_space(line)) > 0 do runner_line(r, line)
		}
		if start > 0 {
			at += i64(start)
			rest := strings.clone(text[start:], context.temp_allocator)
			strings.builder_reset(&pending)
			strings.write_string(&pending, rest)
		}
		free_all(context.temp_allocator)
	}

	os.close(f)
	// A child that has gone is a zombie until it is waited for.
	if owned do _, _ = os.process_wait(r.process)

	sync.mutex_lock(&r.mu)
	// The stream is over, so this is the last `result` there will be.
	result := strings.clone(r.result, context.temp_allocator)
	sync.mutex_unlock(&r.mu)

	// One ending, and the process is what says so. The exit code first,
	// because it is the harness's own verdict on the whole run; the last
	// `result` after it, for a harness that reports an error and still exits
	// zero. No code at all is a shell killed before it could write one: a
	// stop, or a machine that went down under it.
	if !exited || code != 0 {
		msg := exited ? fmt.tprintf("claude exited with %d", code) : "claude went away without exiting"
		if result != "" do msg = fmt.tprintf("%s (%s)", msg, result)
		if data, ok := os.read_entire_file_from_path(run_file(dir, "err"), context.temp_allocator); ok == nil {
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
		// taking from it is each tool call's input, whole and well-formed,
		// which is nicer than the deltas cut wherever the bytes arrived. It
		// used to be reduced to a one-line summary here, which is the panel
		// deciding what it can show a year before it is drawn: an edit's two
		// strings never made it past this line, so no panel could ever show a
		// diff. It goes on whole and whoever draws it takes what it needs.
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
			opt := json.Marshal_Options{}
			body := strings.builder_make(context.temp_allocator)
			_ = json.unparse_to_builder(&body, input, &opt)
			runner_emit(r, Event{
				kind = .Tool_Input,
				id   = strings.clone(jstr(item, "id")),
				name = strings.clone(name),
				text = strings.clone(strings.to_string(body)),
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

// Never stops the process: a window closing leaves its turns running, and the
// next one picks them up. The directory goes only once the turn is over and
// everything it said has been read, because until then it is the only record
// of how the turn ended.
runner_destroy :: proc(r: ^Runner) {
	runner_detach(r)
	if r.dir != "" && !r.running && len(r.events) == 0 do _ = os.remove_all(r.dir)
	runner_unlock(r)
	for &e in r.events do event_destroy(&e)
	delete(r.events)
	delete(r.dir)
	delete(r.result)
}
