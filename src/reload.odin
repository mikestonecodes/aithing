package aithing

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
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
	blocked:   string, // why the last ready binary was not taken, if it was not
	waiting:   bool, // a new build is sitting there, held up by the above
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

	// A binary newer than everything under src/ was built from this source,
	// so the first turn that finishes has nothing to build.
	if src := src_mtime(reload_repo()); src != 0 && g_reload.mtime >= src do g_build.built = src
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

// The one place the swap is decided, so there is one place to look when it
// does not happen. A binary can be sitting there ready for minutes while a
// turn runs, and from the outside that is indistinguishable from a reload
// that is simply broken — so every time the answer is "not yet", the reason
// goes in the log with it.
reload_swap :: proc(app: ^App) {
	if !reload_ready() do return

	why := ""
	switch {
	case reload_building():
		why = "a build is still running"
	case app_busy(app):
		why = "a turn is in flight"
	}
	if why != "" {
		// Only when it changes: this is asked twice a second.
		if why != g_reload.blocked {
			g_reload.waiting = true
			delete(g_reload.blocked)
			g_reload.blocked = strings.clone(why)
			reload_log(fmt.tprintf("new binary is waiting: %s", why))
		}
		return
	}
	reload_log("swapping")
	reload_exec(app)
}

// A rebuilt window is ready and waiting for the turn to end. Worth saying out
// loud: from the outside, a reload that is waiting and a reload that is
// broken look exactly the same, and this program is edited while it runs.
reload_waiting :: proc() -> bool {
	return g_reload.waiting
}

// The newest source file in the repo, one level down so shaders count. Zero
// when the directory cannot be read, which reads as "build anyway".
@(private = "file")
src_mtime :: proc(repo: string) -> i64 {
	dir, _ := filepath.join({repo, "src"}, context.temp_allocator)
	newest := i64(0)
	walk :: proc(path: string, newest: ^i64, descend: bool) {
		files, err := os.read_all_directory_by_path(path, context.temp_allocator)
		if err != nil do return
		for f in files {
			if f.type == .Directory {
				if descend do walk(f.fullpath, newest, false)
				continue
			}
			if t := f.modification_time._nsec; t > newest^ do newest^ = t
		}
	}
	walk(dir, &newest, true)
	return newest
}

// Whether the file on disk is something exec can actually take.
@(private = "file")
reload_runnable :: proc() -> bool {
	f, err := os.open(g_reload.path)
	if err != nil do return false
	defer os.close(f)
	magic: [4]byte
	n, rerr := os.read(f, magic[:])
	if rerr != nil || n < 4 do return false
	return magic == {0x7f, 'E', 'L', 'F'}
}

@(private = "file")
reload_log :: proc(msg: string) {
	f, err := os.open(cache_path("last-reload.log"), {.Write, .Create, .Append})
	if err != nil do return
	defer os.close(f)
	_, _ = os.write_string(f, fmt.tprintfln("%v  %s", time.now(), msg))
}

// Replaces this process with the new build. Only returns if the exec failed,
// in which case the old window carries on and says so.
reload_exec :: proc(app: ^App) {
	// Nothing is torn down for a binary that cannot be read: a build still
	// being written has a fresh mtime and a settled size well before it has
	// an ELF header, and the window would be closed for nothing.
	if !reload_runnable() {
		g_reload.pending = 0 // make it settle again before the next try
		reload_log("binary is not runnable yet")
		return
	}
	reload_save(app)
	// The composer and the session file are on disk; everything else is this
	// process, and exec throws all of it away at once.
	window_close(&app.win)

	args := []cstring{strings.clone_to_cstring(g_reload.path, context.temp_allocator), RELOAD_FLAG, nil}
	posix.execv(args[0], raw_data(args))

	// The window is already gone by here, so there is nothing to go back to.
	reload_log("exec failed")
	g_reload.enabled = false
	app_status(app, "reload failed; restart by hand")
}

// --- what survives ----------------------------------------------------------

@(private = "file")
STATE :: "reload-state"

// The picture is the same one a normal launch restores, so there is one
// serializer for both: see state.odin.
@(private = "file")
reload_save :: proc(app: ^App) {
	state_write(app, cache_path(STATE))
}

// Reads back what the previous process left, and takes the file with it: a
// reload that crashed on the way up should not keep restoring the same draft.
reload_restore :: proc(allocator := context.allocator) -> App_State {
	return state_read(cache_path(STATE), true, allocator)
}

// --- dogfooding -------------------------------------------------------------
//
// `dev.sh` rebuilds on every change under src/, which is the loop when the
// window was started from a terminal. Started from the desktop file there is
// no dev.sh, so a turn that changes this window's own source changes nothing
// anyone can see — the one thing this program is for.
//
// So the window builds itself. A turn that finishes in the repo the running
// binary came from runs `build.sh` there, and the watcher above does the
// rest: the new binary lands, stops changing, and execs over this process
// with the session and the draft intact. Ask for a change and it is in front
// of you a few seconds later, in the same place you were.

@(private = "file")
Build :: struct {
	worker:  ^thread.Thread,
	running: bool,
	ready:   bool,
	ok:      bool,
	mu:      sync.Mutex,
	// The newest thing under src/ as of the last build that worked, and as of
	// the one under way. A turn that read the code without changing it does
	// not need a build, and the seconds it would take are seconds the reload
	// spends waiting instead of swapping.
	built:   i64,
	pending: i64,
}

@(private = "file")
g_build: Build

// The repo this binary was built from: the directory it sits in, which is
// where build.sh is. Empty when the binary could not be resolved at startup.
@(private = "file")
reload_repo :: proc() -> string {
	if !g_reload.enabled do return ""
	context.allocator = context.temp_allocator
	return filepath.dir(g_reload.path)
}

// True when `cwd` is this window's own source: the one case where a finished
// turn is worth a build.
reload_is_own :: proc(cwd: string) -> bool {
	repo := reload_repo()
	return repo != "" && cwd == repo
}

// Starts a build of this window, if a turn just changed it. Nothing blocks:
// build.sh takes a few seconds and the window goes on drawing through them.
reload_build :: proc(app: ^App, cwd: string) {
	if !reload_is_own(cwd) do return
	sync.mutex_lock(&g_build.mu)
	already := g_build.running
	sync.mutex_unlock(&g_build.mu)
	if already do return

	repo := reload_repo()
	script, _ := filepath.join({repo, "build.sh"}, context.temp_allocator)
	if !os.exists(script) do return

	stamp := src_mtime(repo)
	if stamp != 0 && stamp <= g_build.built {
		reload_log("turn changed nothing under src")
		return
	}
	g_build.pending = stamp
	build_reap()

	sync.mutex_lock(&g_build.mu)
	g_build.running = true
	g_build.ready = false
	sync.mutex_unlock(&g_build.mu)
	app_status(app, "building...")

	g_build.worker = thread.create_and_start_with_poly_data(
		strings.clone(script),
		proc(script: string) {
			defer delete(script)
			// Everything it says goes to a file, the way the harness's stderr
			// does: the window has nowhere to put a build log, and after a
			// failure it is the only thing worth reading.
			context.allocator = context.temp_allocator
			dir := filepath.dir(script)
			log, lerr := os.open(cache_path("last-build.log"), {.Write, .Create, .Trunc})
			desc := os.Process_Desc {
				command     = {script},
				working_dir = dir,
				stdout      = lerr == nil ? log : nil,
				stderr      = lerr == nil ? log : nil,
			}
			ok := false
			if p, err := os.process_start(desc); err == nil {
				state, _ := os.process_wait(p)
				ok = state.exited && state.exit_code == 0
			}
			if lerr == nil do os.close(log)

			sync.mutex_lock(&g_build.mu)
			g_build.ok = ok
			g_build.ready = true
			g_build.running = false
			sync.mutex_unlock(&g_build.mu)
		},
	)
}

@(private = "file")
build_reap :: proc() {
	if g_build.worker != nil && thread.is_done(g_build.worker) {
		thread.destroy(g_build.worker)
		g_build.worker = nil
	}
}

// Called once a frame. A build that worked says nothing — the new binary is
// about to take the process over, which is louder than any message. One that
// failed is the only thing worth interrupting for.
reload_build_poll :: proc(app: ^App) -> bool {
	build_reap()
	sync.mutex_lock(&g_build.mu)
	ready, ok := g_build.ready, g_build.ok
	g_build.ready = false
	sync.mutex_unlock(&g_build.mu)
	if !ready do return false
	// Only a build that worked counts: one that failed has to be tried again
	// on the next turn, even if nothing changed in between.
	if ok do g_build.built = g_build.pending
	app_status(app, ok ? "built" : "build failed; see last-build.log")
	reload_log(ok ? "built" : "build failed")
	return true
}

// Whether a build is under way. The reload holds off while it is: a binary
// half written out is not one to exec.
reload_building :: proc() -> bool {
	sync.mutex_lock(&g_build.mu)
	defer sync.mutex_unlock(&g_build.mu)
	return g_build.running
}
