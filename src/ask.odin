package aithing

import "core:os"
import "core:strings"

// A question that is not about any project: what a word means, how a thing in
// the world works. Everything else in the window starts from a project — a
// card is filed under one and runs in a checkout of it, a thread runs where
// the project is — so a question like that had to be asked from inside some
// repository, where it ran on whatever model the cards were set to, left a
// card on that project's grid, and had the agent reading the code first to
// see whether the question was about it.
//
// So a question is its own place. It runs in a directory of its own with
// nothing in it, on the model that answers questions best rather than the one
// the cards are set to, and it never becomes a card. The launcher asks one:
// type it, ctrl enter.

ASK_MODEL :: Model.Opus

// Where questions run. Named for what it is so that the launcher's search
// finds them under it; not offered as a project, because it is not one.
ask_dir :: proc(allocator := context.temp_allocator) -> string {
	dir := cache_path("questions", allocator)
	os.make_directory_all(dir)
	return dir
}

// Whether a thread is a question, read off where it runs. Nothing else says
// so: the place is the whole of the difference.
is_ask :: proc(cwd: string) -> bool {
	return cwd != "" && cwd == cache_path("questions")
}

// The model a turn in `cwd` runs on. The chip under the composer reads the
// same answer, so what it says is what answers.
turn_model :: proc(app: ^App, cwd: string) -> Model {
	return is_ask(cwd) ? ASK_MODEL : app.model
}

// What the launcher has typed in it, asked as a question, in a thread that
// opens in front of you.
launcher_ask :: proc(app: ^App) {
	query := strings.clone(strings.trim_space(editor_text(&app.search)), context.temp_allocator)
	if query == "" do return
	canvas_new_chat(app, ask_dir())
	// A question is a new one. Routing would read it against the questions
	// asked this afternoon and open whichever shared two words with it.
	route_off(app)
	_ = app_submit(app, query, query)
}
