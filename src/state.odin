package aithing

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Where you were. Closing the window and opening it again should put back
// exactly what was on screen: the thread that was open, the project the grid
// was narrowed to, the card the cursor was on, how far down it was scrolled,
// the model, and both half-typed boxes.
//
// This is the same picture the reload writes when a rebuilt binary takes the
// process over, so there is one serializer and one restore, and a normal
// launch picks up where the last one stopped for the same reason a reload
// does. The reload's copy lives in the cache and is taken away as it is read
// — a run that crashed on the way up should not keep restoring the same
// draft — and the persistent one lives beside the archive and is rewritten
// whenever it changes.

@(private = "file")
STATE_VERSION :: "1"

App_State :: struct {
	session:      string,
	cwd:          string,
	project:      string,
	sel:          string,
	draft:        string, // the composer, inside the open thread
	capture:      string, // the box under the grid
	model:        Model,
	effort:       Effort,
	opened:       bool,
	scroll:       f32,
	ok:           bool,
}

// Everything this program remembers between runs is one file each in one
// directory: the archive, the model, the tags, the groups, the todo list and
// this. Six copies of this join is how they used to be found.
config_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	// AITHING_CONFIG points the lot somewhere else, which is how a test run
	// stays out of the way of the window someone is using — the same thing
	// AITHING_LOG does for the log.
	dir := os.get_env("AITHING_CONFIG", context.temp_allocator)
	if dir == "" {
		home := os.get_env("HOME", context.temp_allocator)
		dir, _ = filepath.join({home, ".config", "aithing"}, context.temp_allocator)
	}
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, name}, allocator)
	return path
}

// Everything worth putting back, as text. On the temp allocator: the caller
// either writes it out or compares it with what is already on disk.
state_text :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "version %s", STATE_VERSION)
	fmt.sbprintfln(&b, "session %s", app.chat.session_id)
	fmt.sbprintfln(&b, "model %s", model_short[app.model])
	fmt.sbprintfln(&b, "effort %s", effort_flag[app.effort])
	fmt.sbprintfln(&b, "cwd %s", app.cwd)
	fmt.sbprintfln(&b, "project %s", app.canvas.project)
	fmt.sbprintfln(&b, "sel %s", app.canvas.sel)
	fmt.sbprintfln(&b, "opened %d", app.page == .Thread ? 1 : 0)
	fmt.sbprintfln(&b, "scroll %.0f", app.canvas.scroll.target)
	fmt.sbprintfln(&b, "capture %s", escape_line(editor_text(&app.capture)))
	// The draft is last and unquoted, so a message with newlines in it needs
	// no escaping: everything past this line is the composer.
	fmt.sbprintln(&b, "draft")
	strings.write_string(&b, editor_text(&app.editor))
	return strings.to_string(b)
}

state_write :: proc(app: ^App, path: string) {
	_ = os.write_entire_file(path, transmute([]byte)state_text(app))
}

// Called on a slow tick and on the way out. The file is only rewritten when
// something in it actually changed, so a window sitting still writes nothing.
state_save :: proc(app: ^App) {
	text := state_text(app)
	if text == app.state_last do return
	delete(app.state_last)
	app.state_last = strings.clone(text)
	_ = os.write_entire_file(config_path("state"), transmute([]byte)text)
}

// Reads a state file. `take` removes it as it is read, which is what the
// reload wants and the persistent copy does not.
state_read :: proc(path: string, take := false, allocator := context.allocator) -> (s: App_State) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if take do os.remove(path)
	if rerr != nil do return

	rest := string(data)
	for {
		line, _, more := strings.partition(rest, "\n")
		rest = more
		key, _, value := strings.partition(line, " ")
		switch key {
		case "version":
			if value != STATE_VERSION do return // written under an older shape
		case "session":
			s.session = strings.clone(value, allocator)
		case "cwd":
			s.cwd = strings.clone(value, allocator)
		case "project":
			s.project = strings.clone(value, allocator)
		case "group":
			// Written by an older build, when a card could be opened out into
			// every thread of its task. Read and dropped, so those files still
			// restore.
		case "sel":
			s.sel = strings.clone(value, allocator)
		case "queue":
			// Written by an older build, when cards queued for one of four
			// turn slots. Read and dropped, so those files still restore.
		case "model":
			s.model, _ = model_parse(value)
		case "effort":
			s.effort, _ = effort_parse(value)
		case "opened":
			s.opened = value == "1"
		case "archive":
			// Written by an older build, when the grid had a strip with a
			// toggle on it. Read and dropped, so those files still restore.
		case "scroll":
			v, _ := strconv.parse_f64(value)
			s.scroll = f32(v)
		case "capture":
			s.capture = unescape_line(value, allocator)
		case "draft":
			s.draft = strings.clone(rest, allocator)
			s.ok = true
			return
		case:
			return // not a state file we wrote
		}
	}
}

state_free :: proc(s: ^App_State) {
	delete(s.session)
	delete(s.cwd)
	delete(s.project)
	delete(s.sel)
	delete(s.draft)
	delete(s.capture)
	s^ = {}
}

// Everything that does not need the session list: the rest of the restore is
// in main, once the first scan has landed and there are threads to open.
state_restore :: proc(app: ^App, s: App_State, model_set: bool, effort_set := false) {
	if !s.ok do return
	if !model_set do app.model = s.model
	if !effort_set do app.effort = s.effort
	if s.cwd != "" {
		delete(app.cwd)
		app.cwd = strings.clone(s.cwd)
	}
	delete(app.canvas.project)
	app.canvas.project = strings.clone(s.project)
	canvas_set_sel(app, s.sel)
	app.canvas.scroll.target = s.scroll
	app.canvas.scroll.offset = s.scroll
	editor_set_text(&app.editor, s.draft)
	editor_set_text(&app.capture, s.capture)
}

// A value that has to stay on one line. Only two characters can break the
// file, so only two are spelled out.
escape_line :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(s, "\n") && !strings.contains(s, "\\") do return s
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\n':
			strings.write_string(&b, "\\n")
		case '\\':
			strings.write_string(&b, "\\\\")
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

unescape_line :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
				i += 2
				continue
			case '\\':
				strings.write_byte(&b, '\\')
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}
