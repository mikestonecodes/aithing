package aithing

import "core:encoding/json"
import "core:strings"

// What a conversation looks like once it has been read out of a session file
// or streamed off a running `claude -p`. Both paths build the same shape, so
// the UI never has to know whether it is looking at history or at something
// arriving a token at a time.

Role :: enum {
	User,
	Assistant,
	System,
}

Block_Kind :: enum {
	Text, // prose from either side
	Thinking, // extended thinking, folded away by default
	Tool, // a tool call, with its result folded into the same block
	Image, // an attachment the user pasted
	Error,
}

Block :: struct {
	kind:      Block_Kind,
	text:      strings.Builder, // grows as deltas arrive
	name:      string, // tool name
	arg:       string, // one-line summary of the tool input
	arg_json:  strings.Builder, // partial input JSON, while streaming
	result:    strings.Builder,
	tool_id:   string,
	running:   bool,
	expanded:  bool,
	sub:       [dynamic]Block, // a subagent's own blocks, for Task calls
	image:     Attachment,

	// Wrapped-line cache. Laying out a long transcript every frame is the one
	// thing that would make this UI slow, so each block remembers the lines it
	// produced and the width they were produced for.
	lines:     [dynamic]Line,
	wrap_w:    f32,
	wrap_len:  int,
	height:    f32,
}

Line :: struct {
	text:   string, // a slice of the block's text; never freed on its own
	style:  Line_Style,
	indent: f32,
}

Line_Style :: enum {
	Body,
	Bold,
	Heading,
	Code,
	Bullet,
	Quote,
}

Msg :: struct {
	role:   Role,
	blocks: [dynamic]Block,
	agent:  string, // non-empty when this is a subagent's transcript
	// Typed, shown, but not sent yet: it is waiting behind a running turn.
	// Drawn dimmed and labelled, because a message that has gone out and one
	// that is still waiting are otherwise the same bubble.
	queued: bool,
}

Chat :: struct {
	msgs:       [dynamic]Msg,
	session_id: string,
	cwd:        string,
	title:      string,
	path:       string,
}

block_text :: proc(b: ^Block) -> string {
	return strings.to_string(b.text)
}

// Blocks live in dynamic arrays that grow as the answer arrives, so nothing
// holds a `^Block` across an append. A block is addressed by where it sits
// instead: which message, which block, and — for a subagent's own output —
// which block of that Task's nested list.
Ref :: struct {
	msg:   int,
	block: int,
	sub:   int, // -1 for a block that is not inside a Task
}

NO_REF :: Ref{-1, -1, -1}

ref_valid :: proc(r: Ref) -> bool {
	return r.msg >= 0 && r.block >= 0
}

chat_block :: proc(c: ^Chat, r: Ref) -> ^Block {
	if r.msg < 0 || r.msg >= len(c.msgs) do return nil
	m := &c.msgs[r.msg]
	if r.block < 0 || r.block >= len(m.blocks) do return nil
	b := &m.blocks[r.block]
	if r.sub < 0 do return b
	if r.sub >= len(b.sub) do return nil
	return &b.sub[r.sub]
}

msg_append_block :: proc(c: ^Chat, msg: int, b: Block) -> Ref {
	append(&c.msgs[msg].blocks, b)
	return Ref{msg, len(c.msgs[msg].blocks) - 1, -1}
}

chat_append :: proc(c: ^Chat, role: Role) -> int {
	append(&c.msgs, Msg{role = role})
	return len(c.msgs) - 1
}

chat_last :: proc(c: ^Chat) -> int {
	return len(c.msgs) - 1
}

// Where the tool call with this id lives, subagent output included.
chat_find_tool :: proc(c: ^Chat, id: string) -> Ref {
	if id == "" do return NO_REF
	#reverse for &m, mi in c.msgs {
		#reverse for &b, bi in m.blocks {
			if b.kind == .Tool && b.tool_id == id do return Ref{mi, bi, -1}
			#reverse for &s, si in b.sub {
				if s.kind == .Tool && s.tool_id == id do return Ref{mi, bi, si}
			}
		}
	}
	return NO_REF
}

block_destroy :: proc(b: ^Block) {
	strings.builder_destroy(&b.text)
	strings.builder_destroy(&b.arg_json)
	strings.builder_destroy(&b.result)
	delete(b.name)
	delete(b.arg)
	delete(b.tool_id)
	delete(b.lines)
	for &s in b.sub do block_destroy(&s)
	delete(b.sub)
	attachment_destroy(&b.image)
}

chat_destroy :: proc(c: ^Chat) {
	for &m in c.msgs {
		for &b in m.blocks do block_destroy(&b)
		delete(m.blocks)
		delete(m.agent)
	}
	delete(c.msgs)
	delete(c.session_id)
	delete(c.cwd)
	delete(c.title)
	delete(c.path)
	c^ = {}
}

// --- JSON helpers -----------------------------------------------------------
// core:encoding/json gives back a tagged union; these keep the call sites from
// drowning in type assertions.

jobj :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	o, ok := v.(json.Object)
	if !ok do return nil, false
	val, has := o[key]
	return val, has
}

jstr :: proc(v: json.Value, key: string) -> string {
	val, ok := jobj(v, key)
	if !ok do return ""
	s, is_str := val.(json.String)
	if !is_str do return ""
	return string(s)
}

jarr :: proc(v: json.Value, key: string) -> (json.Array, bool) {
	val, ok := jobj(v, key)
	if !ok do return nil, false
	a, is_arr := val.(json.Array)
	return a, is_arr
}

jstring_of :: proc(v: json.Value) -> string {
	s, ok := v.(json.String)
	if !ok do return ""
	return string(s)
}

// A tool call's most interesting argument, for the one-line summary next to
// the tool name: the command for Bash, the path for a file tool, and so on.
tool_summary :: proc(name: string, input: json.Value, allocator := context.allocator) -> string {
	for key in ([?]string{"command", "file_path", "path", "pattern", "prompt", "url", "query", "description", "skill"}) {
		if s := jstr(input, key); s != "" {
			line := s
			if idx := strings.index_byte(line, '\n'); idx >= 0 do line = line[:idx]
			return strings.clone(line, allocator)
		}
	}
	return strings.clone("", allocator)
}
