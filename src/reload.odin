package aithing

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

// Auto reload. Dogfooding a window means editing it while it is open, and the
// slow part of that loop is not the build, it is getting back to where you
// were: the session, the scroll, the half-typed message. So a rebuilt binary
// takes over the running process instead of asking to be started again.
//
// The trigger is the binary's own mtime, checked twice a second — a stat is
// nothing next to a frame, and it means `./build.sh` from anywhere is the
// whole loop; nothing has to know the window is running. What survives the
// swap is written to the cache directory and picked back up by the new
// process, which is `exec`d over this one, so it inherits the terminal and
// keeps the same pid.

RELOAD_FLAG :: "--reloaded" // internal: this run is picking up from an older one

@(private = "file")
Reload :: struct {
	// Resolved once at startup. /proc/self/exe is not used later on: a linker
	// that replaces the file rather than rewriting it would leave that link
	// pointing at the deleted inode.
	path:      string,
	mtime:     i64, // what we started from
	pending:   i64, // a newer mtime, waiting to stop moving
	size:      i64, // of the pending build; a link in progress still grows
	next:      time.Time,
	enabled:   bool,
}

@(private = "file")
g_reload: Reload

RELOAD_POLL :: 500 * time.Millisecond

reload_init :: proc() {
	buf: [4096]byte
	n, err := linux.readlink("/proc/self/exe", buf[:])
	if err != nil || n <= 0 do return
	g_reload.path = strings.clone(string(buf[:n]))
	info, serr := os.stat(g_reload.path, context.temp_allocator)
	if serr != nil do return
	g_reload.mtime = info.modification_time._nsec
	g_reload.next = time.time_add(time.now(), RELOAD_POLL)
	g_reload.enabled = true
}

// True once a rebuilt binary has landed and stopped changing. Two stats have
// to agree before the swap: a build that is still being written out has a
// fresh mtime long before it has a working ELF header.
reload_ready :: proc() -> bool {
	if !g_reload.enabled do return false
	if time.since(g_reload.next) < 0 do return false
	g_reload.next = time.time_add(time.now(), RELOAD_POLL)

	info, err := os.stat(g_reload.path, context.temp_allocator)
	if err != nil do return false // mid-build the file can be gone entirely
	mtime := info.modification_time._nsec
	if mtime == g_reload.mtime do return false

	settled := mtime == g_reload.pending && info.size == g_reload.size
	g_reload.pending = mtime
	g_reload.size = info.size
	return settled
}

// Replaces this process with the new build. Only returns if the exec failed,
// in which case the old window carries on and says so.
reload_exec :: proc(app: ^App) {
	reload_save(app)
	// The composer and the session file are on disk; everything else is this
	// process, and exec throws all of it away at once.
	window_close(&app.win)

	args := []cstring{strings.clone_to_cstring(g_reload.path, context.temp_allocator), RELOAD_FLAG, nil}
	posix.execv(args[0], raw_data(args))

	g_reload.enabled = false
	app_status(app, "reload failed; restart by hand")
}

// --- what survives ----------------------------------------------------------

@(private = "file")
STATE :: "reload-state"

@(private = "file")
reload_save :: proc(app: ^App) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "session %s", app.chat.session_id)
	fmt.sbprintfln(&b, "model %s", model_flag[app.model])
	fmt.sbprintfln(&b, "cwd %s", app.cwd)
	// The draft is last and unquoted, so a message with newlines in it needs
	// no escaping: everything past this line is the composer.
	fmt.sbprintln(&b, "draft")
	strings.write_string(&b, editor_text(&app.editor))
	_ = os.write_entire_file(cache_path(STATE), transmute([]byte)strings.to_string(b))
}

Reload_State :: struct {
	session: string,
	model:   Model,
	cwd:     string,
	draft:   string,
	ok:      bool,
}

// Reads back what the previous process left, and takes the file with it: a
// reload that crashed on the way up should not keep restoring the same draft.
reload_restore :: proc(allocator := context.allocator) -> (s: Reload_State) {
	path := cache_path(STATE)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	os.remove(path)
	if rerr != nil do return

	rest := string(data)
	for {
		line, _, more := strings.partition(rest, "\n")
		rest = more
		key, _, value := strings.partition(line, " ")
		switch key {
		case "session":
			s.session = strings.clone(value, allocator)
		case "cwd":
			s.cwd = strings.clone(value, allocator)
		case "model":
			for m in Model do if model_flag[m] == value do s.model = m
		case "draft":
			s.draft = strings.clone(rest, allocator)
			s.ok = true
			return
		case:
			return // not a state file we wrote
		}
	}
}
