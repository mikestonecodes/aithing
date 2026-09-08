package aithing

import "core:strings"
import "core:time"

// Typing into an empty composer is the most common thing anyone does here,
// and it always meant the same thing: a new thread. But half of what gets
// typed is the next thing about what was just being worked on, and starting a
// thread for it throws away the context that would have answered it.
//
// So the window decides. While the draft grows in a new chat, it is matched
// against the threads open in this project in the last few hours; if it is
// plainly about one of them, that thread is opened underneath and the message
// goes there instead. If it is not about any of them, nothing happens and the
// message starts a thread, which is what it would have done anyway.
//
// The decision is visible, because it opens the thread in front of you rather
// than deciding quietly at send time — and ctrl-n takes it back and holds it
// back for the rest of the draft.

// Short drafts say too little to route on: `it's broken` is about whatever is
// on screen, and there is nothing on screen.
ROUTE_MIN_CHARS :: 14
// How far back a thread can have been touched and still be the one you are
// in the middle of.
ROUTE_WINDOW :: 6 * time.Hour
// Words in common before a draft is about a thread rather than merely near
// it, counting only words that are not all over the project anyway.
ROUTE_SHARED :: 2

// Called once a frame while the composer has a new chat in it. Does nothing
// until the draft has changed and grown enough to be worth reading.
route_update :: proc(app: ^App) {
	if app.route_off || app.chat.session_id != "" do return
	if app_chat_busy(app) do return
	text := strings.trim_space(editor_text(&app.editor))
	if len(text) < ROUTE_MIN_CHARS do return
	if text == app.route_text do return // already read, and it said no
	delete(app.route_text)
	app.route_text = strings.clone(text)

	index := route_pick(app, text)
	if index < 0 do return
	// Opening it is the whole of the decision: the transcript underneath is
	// the thread being continued, and the draft is untouched.
	// After the open, not before: opening one says "loading..." over it.
	app_open(app, index)
	app_status(app, "continuing this thread — ctrl n for a new one")
}

// The thread a draft is about, or -1. Only threads in the same project and
// only ones touched recently: a task from last week is a thread you would go
// and find, not one you would fall into by typing.
route_pick :: proc(app: ^App, text: string) -> int {
	cwd := app.chat.cwd != "" ? app.chat.cwd : app.cwd
	if cwd == "" do return -1

	// A word in most of a project's threads says nothing about which one.
	seen := make(map[string]int, context.temp_allocator)
	n := 0
	for s in app.sessions {
		if s.cwd != cwd do continue
		n += 1
		for w in title_words(s.title) do seen[w] += 1
	}
	if n == 0 do return -1
	common := max(2, n * GROUP_SHARE / 100)

	draft := title_words(text)
	best, score := -1, 0
	for s, i in app.sessions {
		if s.cwd != cwd || s.transient do continue
		if time.since(s.mtime) > ROUTE_WINDOW do continue

		shared := 0
		for w in title_words(s.title) {
			if seen[w] > common do continue
			for d in draft {
				if d != w do continue
				shared += 1
				break
			}
		}
		// Sessions come newest first, so the first thread to reach a score is
		// the most recent one that reached it.
		if shared > score {
			best, score = i, shared
		}
	}
	return score >= ROUTE_SHARED ? best : -1
}

// ctrl n, which is the way to say the manager got it wrong. It stays wrong
// for the rest of what is being typed: routing again on the next keystroke
// would put the thread straight back.
route_off :: proc(app: ^App) {
	app.route_off = true
}

// A message going out ends the draft it was routed for, and the next one is
// read fresh.
route_clear :: proc(app: ^App) {
	app.route_off = false
	delete(app.route_text)
	app.route_text = ""
}
