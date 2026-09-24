package aithing

import "core:fmt"
import "core:os"
import "core:strings"

// What a turn runs on: which model answers and how hard it thinks.
//
// It was one pair for the whole window, so a thread had no answer of its own.
// The chips under a thread said whatever had last been picked anywhere — on
// the grid, for a card in another project — and the next message in that
// thread quietly went out on it. Nothing on screen said what a thread had
// been running on, and changing it for one conversation changed it for all of
// them.
//
// So a thread has its own, written down the first time the harness names it
// and changed only from inside it. `app.model` and `app.effort` are what new
// work starts on — a card typed under the grid, a thread nobody has sent
// anything into yet — and nothing more.
Setting :: struct {
	model:  Model,
	effort: Effort,
}

// What the next turn in `session` runs on. A thread from before threads had
// their own takes the window's, as it always did.
thread_setting :: proc(app: ^App, session: string) -> Setting {
	if s, has := app.per_thread[session]; has && session != "" do return s
	return Setting{app.model, app.effort}
}

// What a turn in `cwd`, writing to `session`, is started on. The questions
// project answers on its own model whatever the thread says: see ask.odin.
turn_setting :: proc(app: ^App, cwd, session: string) -> Setting {
	s := thread_setting(app, session)
	if is_questions(cwd) do s.model = QUESTIONS_MODEL
	return s
}

// The thread the chips are about, or "" when they are about new work. A
// thread whose first turn is still waiting to be named has no entry to write
// to yet, so its chips are the window's — which is what that turn started on.
app_setting_thread :: proc(app: ^App) -> string {
	return app.page == .Thread ? app.chat.session_id : ""
}

// What the chips say: the one answer turn_start reads, so the chip is what
// answers.
app_setting :: proc(app: ^App) -> Setting {
	return thread_setting(app, app_setting_thread(app))
}

// Every choice goes through here: the pickers, the arrow keys and ctrl m and
// ctrl e. Inside a named thread it is that thread's; anywhere else it is what
// new work starts on.
app_choose :: proc(app: ^App, s: Setting) {
	session := app_setting_thread(app)
	if session == "" {
		if s.model != app.model do model_save(s.model)
		if s.effort != app.effort do effort_save(s.effort)
		app.model, app.effort = s.model, s.effort
		return
	}
	thread_set(app, session, s)
	// A turn already running keeps what it was started on — the process was
	// handed a model on its command line and has no way to be handed another
	// — so say when the change is for the message after it, or the chip
	// reads as if the answer arriving now came from it.
	if app_session_busy(app, session) {
		app_status(app, fmt.tprintf("the next message runs on %s · %s", model_label[s.model], effort_label[s.effort]))
	}
}

// The first time a thread is named, it keeps what its turn was started on.
// Taking the window's at that point instead would record whatever had been
// picked in the second between the send and the name — for somewhere else.
thread_keep :: proc(app: ^App, session: string, s: Setting) {
	if session == "" do return
	if _, has := app.per_thread[session]; has do return
	thread_set(app, session, s)
}

@(private = "file")
thread_set :: proc(app: ^App, session: string, s: Setting) {
	if _, has := app.per_thread[session]; !has {
		app.per_thread[strings.clone(session)] = s
	} else {
		app.per_thread[session] = s
	}
	thread_settings_save(app)
}

// One line a thread, `<id> <model> <effort>`, in the words the command line
// takes, beside the window's own choice.
thread_settings_load :: proc(app: ^App) {
	data, err := os.read_entire_file_from_path(config_path("threads"), context.temp_allocator)
	if err != nil do return
	it := each_line(string(data))
	for line in iter_next(&it) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) != 3 do continue
		m, mok := model_parse(f[1])
		e, eok := effort_parse(f[2])
		if !mok || !eok do continue
		app.per_thread[strings.clone(f[0])] = Setting{m, e}
	}
}

@(private = "file")
thread_settings_save :: proc(app: ^App) {
	b := strings.builder_make(context.temp_allocator)
	for id, s in app.per_thread {
		fmt.sbprintfln(&b, "%s %s %s", id, model_short[s.model], effort_flag[s.effort])
	}
	_ = os.write_entire_file(config_path("threads"), transmute([]byte)strings.to_string(b))
}

thread_settings_destroy :: proc(app: ^App) {
	for id in app.per_thread do delete(id)
	delete(app.per_thread)
}
