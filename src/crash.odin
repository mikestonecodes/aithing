package aithing

import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

// The other half of the watchdog. A freeze reports the phase it stopped in; a
// crash should report the stack it stopped on. A window that simply disappears
// is the worst bug report there is — the terminal it was started from has
// usually scrolled away, and started from the desktop file there is none.
//
// So every fatal signal writes a backtrace to ~/.cache/aithing/crash.log and
// then lets the default handler finish the job. Everything below runs inside a
// signal handler: no allocation, no locks, and the file is opened up front so
// the handler only ever has a descriptor to write to.

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	backtrace :: proc(buffer: [^]rawptr, size: c.int) -> c.int ---
	backtrace_symbols_fd :: proc(buffer: [^]rawptr, size: c.int, fd: c.int) ---
}

@(private = "file")
g_crash_fd: c.int = -1

// Appends rather than truncating: a crash is worth keeping across the runs
// that come after it. The path is for the tests, whose shared cache directory
// another test may be emptying while this one writes into it.
crash_report_install :: proc(log := "") {
	path := log != "" ? log : cache_path("crash.log", context.temp_allocator)
	f, err := os.open(path, {.Write, .Create, .Append})
	if err != nil do return
	g_crash_fd = c.int(os.fd(f))

	act := posix.sigaction_t {
		// One report per process. Putting the default handler back means the
		// crash still ends the process the way it would have, and a fault
		// inside the handler cannot loop.
		sa_flags = {.RESETHAND},
	}
	act.sa_handler = on_fatal
	for sig in ([?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT}) {
		posix.sigaction(sig, &act, nil)
	}

	// The one death this file could not report, because it is not a fault:
	// a write to a pipe nobody is reading kills the process outright, and
	// there is nothing to take a backtrace of. Every pipe here is somebody
	// else's end of a conversation — a clipboard peer that gave up waiting,
	// a `claude` that exited mid-stream — and none of them is a reason for
	// the window to disappear. Ignored, so the write fails as EPIPE where it
	// happens and the caller deals with it.
	posix.sigignore(.SIGPIPE)

	// The watchdog's way of asking the frame loop where it is. Restarted, so
	// a wait the loop is stuck in carries on waiting after the report instead
	// of coming back EINTR to a caller that would take it for a failure.
	stack := posix.sigaction_t {
		sa_flags = {.RESTART},
	}
	stack.sa_handler = on_stack
	posix.sigaction(.SIGUSR1, &stack, nil)

	// glibc loads the unwinder on the first backtrace, and loading allocates,
	// which a handler must not; a frame loop stuck inside malloc would then
	// never write its report. So the first one is taken here.
	frames: [1]rawptr
	backtrace(&frames[0], 1)
}

// A freeze, told the way a crash is: the watchdog notices the frame loop has
// stopped and says so here, and then has the loop's own thread write the
// stack it is standing on. The line the watchdog used to print went to
// last-run.log alone, which relaunching the frozen window truncates — so the
// one freeze anybody reported left nothing behind but the fact of it.
crash_stall :: proc(phase: Phase, seconds: f64, main_tid: linux.Pid) {
	if g_crash_fd < 0 do return
	say(fmt.tprintf("\n--- aithing stalled: %v for %.1fs ---\n", phase, seconds))
	_ = linux.tgkill(linux.getpid(), main_tid, .SIGUSR1)
}

// And how long it lasted. A window that comes back after eight seconds of
// running git is a different bug from one that has to be killed, and without
// this line the two leave the same report.
crash_unstall :: proc(seconds: f64) {
	if g_crash_fd < 0 do return
	say(fmt.tprintf("--- moving again after %.1fs ---\n", seconds))
}

@(private = "file")
on_stack :: proc "c" (sig: posix.Signal) {
	if g_crash_fd < 0 do return
	frames: [64]rawptr
	n := backtrace(&frames[0], len(frames))
	backtrace_symbols_fd(&frames[0], n, g_crash_fd)
}

// For the deaths that are not signals. A Vulkan call that fails takes the
// process out through os.exit, which no handler sees and which leaves nothing
// behind but a line on a stderr that may have gone to a log the next run
// truncates. Anything fatal says so here first.
crash_note :: proc(msg: string) {
	if g_crash_fd < 0 do return
	say("\n--- aithing died: ")
	say(msg)
	say(" ---\n")
}

@(private = "file")
on_fatal :: proc "c" (sig: posix.Signal) {
	if g_crash_fd < 0 do return
	say("\n--- aithing crashed: ")
	say(signal_name(sig))
	say(" ---\n")

	frames: [64]rawptr
	n := backtrace(&frames[0], len(frames))
	backtrace_symbols_fd(&frames[0], n, g_crash_fd)
	// Returning re-runs the faulting instruction with the default handler in
	// place, so the process dies exactly as it would have without us.
}

@(private = "file")
say :: proc "contextless" (s: string) {
	linux.write(linux.Fd(g_crash_fd), transmute([]u8)s)
}

@(private = "file")
signal_name :: proc "contextless" (sig: posix.Signal) -> string {
	#partial switch sig {
	case .SIGSEGV:
		return "SIGSEGV (bad address)"
	case .SIGBUS:
		return "SIGBUS"
	case .SIGILL:
		// What an Odin bounds check or a failed assert traps with. The message
		// itself went to stderr, which is last-run.log unless a terminal took
		// it first.
		return "SIGILL (trap: bounds check, assert or unreachable)"
	case .SIGFPE:
		return "SIGFPE"
	case .SIGABRT:
		return "SIGABRT"
	}
	return "signal"
}
