package aithing

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// What a session file is read down to: a title, a preview, and whether the
// work in it was ever checked. The reading walks the tail looking at the
// record types, and the shapes here are the ones it has to tell apart —
// a message record leads with its uuid and carries the tool calls, while the
// title records lead with their type and carry nothing else.

@(private = "file")
write_session :: proc(t: ^testing.T, name: string, lines: []string) -> string {
	dir := "/tmp/aithing-test-sessions"
	os.make_directory_all(dir)
	path := fmt.tprintf("%s/%s.jsonl", dir, name)
	body: string
	for l in lines do body = fmt.tprintf("%s%s\n", body, l)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil, "wrote the session")
	return path
}

@(private = "file")
read :: proc(t: ^testing.T, name: string, lines: []string) -> Session {
	path := write_session(t, name, lines)
	info, _ := os.stat(path, context.allocator)
	defer os.file_info_delete(info, context.allocator)
	// Cloned because session_free owns it, the way a real scan hands it over.
	s := Session{path = strings.clone(path), size = info.size}
	session_read_summary(&s, context.allocator)
	return s
}

@(test)
a_title_record_names_the_thread :: proc(t: ^testing.T) {
	s := read(
		t,
		"titled",
		{
			`{"parentUuid":null,"cwd":"/tmp/work","type":"user","message":{"role":"user","content":"first thing said"}}`,
			`{"type":"ai-title","aiTitle":"what the model called it"}`,
			`{"type":"custom-title","customTitle":"what I called it"}`,
			`{"type":"last-prompt","lastPrompt":"the newest thing said"}`,
		},
	)
	defer session_free(&s)
	// A custom title beats the model's, and the last prompt is the line under it.
	testing.expect_value(t, s.title, "what I called it")
	testing.expect_value(t, s.preview, "the newest thing said")
	testing.expect_value(t, s.cwd, "/tmp/work")
}

@(test)
a_check_that_passed_and_an_edit_after_it :: proc(t: ^testing.T) {
	ran := `{"parentUuid":"a","type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"odin test src"}}]}}`
	came_back := `{"parentUuid":"b","type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}`
	edited := `{"parentUuid":"c","type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/a.odin"}}]}}`
	said := `{"parentUuid":"d","cwd":"/tmp/work","type":"user","message":{"role":"user","content":"do the thing"}}`

	passed := read(t, "passed", {said, ran, came_back})
	defer session_free(&passed)
	testing.expect_value(t, passed.verify, Verify.Passed)

	// An edit after the check puts the answer out of date.
	stale := read(t, "stale", {said, ran, came_back, edited})
	defer session_free(&stale)
	testing.expect_value(t, stale.verify, Verify.Untested)

	// A check that came back an error stays failed.
	failed := read(
		t,
		"failed",
		{
			said,
			ran,
			`{"parentUuid":"b","type":"user","message":{"content":[{"type":"tool_result","content":"boom","is_error":true}]}}`,
		},
	)
	defer session_free(&failed)
	testing.expect_value(t, failed.verify, Verify.Failed)

	// Nothing was ever run, so there is nothing to have checked.
	none := read(t, "none", {said, `{"type":"ai-title","aiTitle":"just talk"}`})
	defer session_free(&none)
	testing.expect_value(t, none.verify, Verify.None)
	// And a thread that said one thing and ran nothing is not worth a card.
	testing.expect(t, none.transient, "a thread with one prompt and no work is transient")
	testing.expect(t, !passed.transient, "a thread that ran something is not")
}
