package aithing

import "core:c"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

// The other half of the watchdog. A freeze reports the phase it stopped in; a
// crash should report the stack it stopped on. A window that simply disappears
// is the worst bug report there is — the terminal it was started from has
// usually scrolled away, and under auto reload there may not have been one.
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

// Appends rather than truncating: a crash is worth more than the run that
// comes after it, and the next run starts within seconds under auto reload.
crash_report_install :: proc() {
	path := cache_path("crash.log", context.temp_allocator)
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
