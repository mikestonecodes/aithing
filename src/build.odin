package aithing

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"

// Dogfooding a window means editing it while it is open, and a card that
// changes this program's own source changes nothing anyone can see until
// somebody goes and builds it. So the window builds itself: work that lands
// in the repository this binary came from builds it there.
//
// The trigger is the landing, not the turn. A card works in a checkout of its
// own (see worktree.odin), so the source it edits is not the source this
// binary was built from — building when its turn ended would have built the
// same unchanged tree over and over. The moment that stops being true is the
// moment its branch goes into the project, which is the one thing that starts
// a build here.
//
// It stops at the build. There was a swap on the end of this — a watcher on
// the binary's own mtime, and an `exec` over the running process once it
// settled, so the new window came up on the same session with the same
// half-typed message. It is gone: a window that replaces itself while you are
// reading a transcript in it is a window that took something away from you to
// give you something you had not asked for yet. The build lands, the status
// line says so, and the next launch is the new one.

@(private = "file")
Build :: struct {
	worker:  ^thread.Thread,
	mu:      sync.Mutex,
	running: bool,
	ready:   bool,
	ok:      bool,
	// Where this binary sits, which is the root of the repo it was built
	// from. Resolved once at startup: /proc/self/exe is not read later
	// because a linker that replaces the file rather than rewriting it
	// leaves that link pointing at the deleted inode.
	repo:    string,
	// The newest thing under src/ as of the last build that worked, and as of
	// the one under way. A card that read the code without changing it does
	// not need a build.
	built:   i64,
	pending: i64,
}

@(private = "file")
g_build: Build

build_init :: proc() {
	buf: [4096]byte
	n, err := linux.readlink("/proc/self/exe", buf[:])
	if err != nil || n <= 0 do return
	// filepath.dir allocates from the context, and the only copy worth keeping
	// is ours: the scratch one it makes on the way is the temp allocator's to
	// drop.
	dir: string
	{
		context.allocator = context.temp_allocator
		dir = filepath.dir(string(buf[:n]))
	}
	g_build.repo = strings.clone(dir)
	// A binary newer than everything under src/ was built from this source,
	// so the first card that lands has nothing to build.
	info, serr := os.stat(string(buf[:n]), context.temp_allocator)
	if serr != nil do return
	if src := src_mtime(g_build.repo); src != 0 && info.modification_time._nsec >= src {
		g_build.built = src
	}
}

build_destroy :: proc() {
	build_reap()
	delete(g_build.repo)
}

// True when a project is this window's own source: the one case where work
// landing is worth a build.
build_is_own :: proc(project: string) -> bool {
	return g_build.repo != "" && project == g_build.repo
}

// Starts a build of this window, if what just landed was this window. Nothing
// blocks: the compiler takes a few seconds and the window goes on drawing
// through them, turns and all.
//
// The compiler, not `build.sh`. The script regenerates the Wayland bindings,
// the font atlas and the SPIR-V before it builds, and all three are committed
// — so a build started by a landing rewrote tracked files in the project's own
// tree, and the next card to land there had to stash a diff this window had
// made behind its back. The generated files are in the repository precisely so
// that a plain `odin build` works; this is the case that needs it to.
//
// `--export-dynamic` stays, which the script explains: it puts the symbol
// names in the dynamic table, which is where the crash reporter's backtrace
// reads them from, and a crash log without it is a column of hex.
build_start :: proc(app: ^App, project: string) {
	if !build_is_own(project) do return
	sync.mutex_lock(&g_build.mu)
	already := g_build.running
	sync.mutex_unlock(&g_build.mu)
	if already do return

	src, _ := filepath.join({g_build.repo, "src"}, context.temp_allocator)
	if !os.exists(src) do return

	stamp := src_mtime(g_build.repo)
	if stamp != 0 && stamp <= g_build.built do return // it changed nothing under src
	g_build.pending = stamp
	build_reap()

	sync.mutex_lock(&g_build.mu)
	g_build.running = true
	g_build.ready = false
	sync.mutex_unlock(&g_build.mu)
	app_status(app, "building...")

	g_build.worker = thread.create_and_start_with_poly_data(
		strings.clone(g_build.repo),
		proc(repo: string) {
			defer delete(repo)
			// Everything it says goes to a file, the way the harness's stderr
			// does: the window has nowhere to put a build log, and after a
			// failure it is the only thing worth reading.
			context.allocator = context.temp_allocator
			log, lerr := os.open(cache_path("last-build.log"), {.Write, .Create, .Trunc})
			desc := os.Process_Desc {
				command     = {
					"odin",
					"build",
					"src",
					"-out:aithing",
					"-extra-linker-flags:-Wl,--export-dynamic",
				},
				working_dir = repo,
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

// Called once a frame. Both endings are said out loud, which they were not
// when a build that worked was immediately followed by the window replacing
// itself: that was the announcement. Now nothing visible happens when a build
// succeeds unless this says so.
build_poll :: proc(app: ^App) -> bool {
	build_reap()
	sync.mutex_lock(&g_build.mu)
	ready, ok := g_build.ready, g_build.ok
	g_build.ready = false
	sync.mutex_unlock(&g_build.mu)
	if !ready do return false
	// Only a build that worked counts: one that failed has to be tried again
	// on the next landing, even if nothing changed in between.
	if ok do g_build.built = g_build.pending
	app_status(app, ok ? "built — restart to pick it up" : "build failed; see last-build.log")
	return true
}

@(private = "file")
build_reap :: proc() {
	if g_build.worker != nil && thread.is_done(g_build.worker) {
		thread.destroy(g_build.worker)
		g_build.worker = nil
	}
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
