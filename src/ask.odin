package aithing

import "core:os"

// A project for questions that are not about any code: what a word means, how
// a thing in the world works. Asked from inside a repository, a question like
// that ran on whatever model the cards were set to and had the agent reading
// the code first to see whether it was about it.
//
// So it is a project like any other — narrowed to from the launcher, cards
// typed into its box — whose directory has nothing in it and is no git
// repository, so a card runs there rather than in a tree of its own, and whose
// cards answer on the model that answers questions best.

QUESTIONS_MODEL :: Model.Opus

// Where the questions project lives. Made on the way, so the launcher can
// offer it before anything has ever been asked there.
questions_dir :: proc(allocator := context.temp_allocator) -> string {
	dir := cache_path("questions", allocator)
	os.make_directory_all(dir)
	return dir
}

is_questions :: proc(cwd: string) -> bool {
	return cwd != "" && cwd == cache_path("questions")
}

// The model a turn in `cwd` runs on. The chip under the box reads the same
// answer, so what it says is what answers.
turn_model :: proc(app: ^App, cwd: string) -> Model {
	return is_questions(cwd) ? QUESTIONS_MODEL : app.model
}
