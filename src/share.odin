package aithing

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

// Two windows open at once are two processes over one config directory. Each
// used to read its files once, on the way up, and from then on write its own
// copy back over them whenever anything changed. A card typed into one window
// never reached the other, and the next thing the other wrote put the file
// back the way it had been — taking the card off the disk as well as off the
// screen. Both windows handed out the same next card number, so two cards
// shared one worktree and one branch. Two copies of one list, and whichever
// saved last was right.
//
// So the file is the list, and a window's copy is only what it read last.
// Every change is made to the file as it stands, under a lock, and a window
// that finds the file has moved since it last looked reads it again. This is
// the plumbing for that: whether the file has moved, holding it still across a
// read and the write that depends on it, and writing it so that nobody ever
// reads half of one.

// What a file was when this window last read or wrote it. Every write is a
// rename, so every write is a new inode as well as a new time.
File_Stamp :: struct {
	inode: u128,
	size:  i64,
	mtime: time.Time,
}

// Zero for a file that is not there, which is also what a window that has
// never seen it holds — so a file nobody has written yet has not moved.
file_stamp :: proc(path: string) -> File_Stamp {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil do return {}
	return {info.inode, info.size, info.modification_time}
}

// The file and the stamp of the version that was read, both through one
// handle. A stamp taken by name before or after the read can belong to a
// different version from the bytes, and a window that recorded the newer
// stamp over the older bytes would never read the newer ones.
file_read :: proc(path: string, allocator := context.temp_allocator) -> (data: []byte, stamp: File_Stamp, ok: bool) {
	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	info, stat_err := os.fstat(f, context.temp_allocator)
	if stat_err != nil do return
	read_err: os.Error
	data, read_err = os.read_entire_file_from_file(f, allocator)
	if read_err != nil do return
	return data, {info.inode, info.size, info.modification_time}, true
}

// Held across a read and the write that depends on it, so two windows
// changing a file at once take turns rather than each writing over what the
// other has just written. The lock is a file of its own beside the one it
// guards: that one is replaced on every write, and a lock taken on it would be
// on a file that was gone a moment later.
//
// Nil when it cannot be had, and the change goes ahead anyway: a window that
// stops saving because a lock file could not be opened is worse than one that
// races. It is held for a read and a write, which is well under a millisecond,
// so the wait for it is bounded at half a second rather than left to the
// kernel: a window stopped in a debugger with the lock in its hand would
// otherwise freeze every other window at its next change.
file_lock :: proc(path: string) -> ^os.File {
	f, err := os.open(strings.concatenate({path, ".lock"}, context.temp_allocator), {.Write, .Create})
	if err != nil do return nil
	deadline := time.time_add(time.now(), 500 * time.Millisecond)
	for {
		#partial switch linux.flock(linux.Fd(os.fd(f)), {.EX, .NB}) {
		case .NONE:
			return f
		case .EWOULDBLOCK, .EINTR:
			if time.diff(time.now(), deadline) > 0 {
				time.sleep(time.Millisecond)
				continue
			}
		}
		os.close(f)
		return nil
	}
}

file_unlock :: proc(f: ^os.File) {
	if f != nil do os.close(f)
}

// Written whole beside it and renamed over it, so a window reading at the same
// moment gets the old version or the new one and never the first half of the
// new one. Only under file_lock, or by the one window that ever writes the
// file: the file beside it has one name.
file_replace :: proc(path: string, data: []byte) -> (stamp: File_Stamp, ok: bool) {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil do return
	if os.rename(tmp, path) != nil do return
	return file_stamp(path), true
}

// What the other windows have done since this one last looked, taken in: the
// cards, the turns they are holding, what each thread runs on, what new work
// starts on, and what is left of the plan. Once a frame, from the window's own
// loop and before anything in the frame reads any of it. A stat a file when
// nothing has moved, and a look at each run another window is holding.
//
// Only from the loop: a test's window has no other window to catch up with,
// and a survey from inside one would take whatever runs were lying in the
// cache as its own.
app_catch_up :: proc(app: ^App) -> bool {
	changed := todos_sync(&app.todos)
	if turns_survey(app) do changed = true
	if thread_settings_sync(app) do changed = true
	if file_stamp(config_path("model")) != app.model_seen {
		app.model = model_load(&app.model_seen)
		changed = true
	}
	if file_stamp(config_path("effort")) != app.effort_seen {
		app.effort = effort_load(&app.effort_seen)
		changed = true
	}
	if usage_sync(&app.usage) do changed = true
	return changed
}
