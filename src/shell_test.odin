package aithing

import "core:testing"

// What a shell call amounts to is read off the text of the command. These are
// the commands this program actually sees in its own transcripts — the agent
// rewrites files with a python heredoc far more often than it rewrites them
// with the edit tool — plus the ones that must not be mistaken for edits.

@(test)
a_python_heredoc_is_an_edit :: proc(t: ^testing.T) {
	// The shape the agent writes: the two sides named above, the call below.
	cmd := `python3 - <<'EOF'
p = 'src/peek.odin'
s = open(p).read()
old = '''PEEK_W :: f32(520)
PEEK_MAX :: f32(470)'''
new = '''PEEK_W :: f32(560)
PEEK_MAX :: f32(470)'''
s = s.replace(old, new)
open(p, 'w').write(s)
EOF`
	sh := shell_read(cmd)
	testing.expect_value(t, sh.family, Icon.Edit)
	testing.expect_value(t, len(sh.swaps), 1)
	testing.expect_value(t, sh.swaps[0].old, "PEEK_W :: f32(520)\nPEEK_MAX :: f32(470)")
	testing.expect_value(t, sh.swaps[0].new, "PEEK_W :: f32(560)\nPEEK_MAX :: f32(470)")
	testing.expect_value(t, len(sh.files), 1)
	testing.expect_value(t, sh.files[0], "src/peek.odin")
}

// Written out rather than named, and with the newlines as escapes: the same
// change, said the other way.
@(test)
a_replace_written_out_is_the_same_change :: proc(t: ^testing.T) {
	cmd := "python3 - <<EOF\ns = open('a.odin').read().replace(\"one\\ntwo\", \"one\\nTWO\")\nopen('a.odin', 'w').write(s)\nEOF"
	sh := shell_read(cmd)
	testing.expect_value(t, sh.family, Icon.Edit)
	testing.expect_value(t, len(sh.swaps), 1)
	testing.expect_value(t, sh.swaps[0].old, "one\ntwo")
	testing.expect_value(t, sh.swaps[0].new, "one\nTWO")
}

@(test)
sed_in_place_is_an_edit :: proc(t: ^testing.T) {
	sh := shell_read("sed -i 's/PEEK_W :: 520/PEEK_W :: 560/' src/peek.odin")
	testing.expect_value(t, sh.family, Icon.Edit)
	testing.expect_value(t, len(sh.swaps), 1)
	testing.expect_value(t, sh.swaps[0].old, "PEEK_W :: 520")
	testing.expect_value(t, sh.swaps[0].new, "PEEK_W :: 560")
	testing.expect_value(t, len(sh.files), 1)
}

// A heredoc redirected into a file is that file's new contents, which is the
// same news a Write brings: everything in it went in.
@(test)
a_heredoc_into_a_file_is_what_it_now_says :: proc(t: ^testing.T) {
	sh := shell_read("cat > /tmp/note.md <<'EOF'\none\ntwo\nEOF")
	testing.expect_value(t, sh.family, Icon.Edit)
	testing.expect_value(t, len(sh.swaps), 1)
	testing.expect_value(t, sh.swaps[0].old, "")
	testing.expect_value(t, sh.swaps[0].new, "one\ntwo")
}

// Reading is not writing, and the line a listing starts at is worth knowing:
// numbering `sed -n '120,160p'` from one would put a number against every
// line and every one of them would be wrong.
@(test)
reading_a_file_is_a_read :: proc(t: ^testing.T) {
	whole := shell_read("cat src/app.odin")
	testing.expect_value(t, whole.family, Icon.Read)
	testing.expect_value(t, whole.from, 1)

	part := shell_read("sed -n '120,160p' src/app.odin")
	testing.expect_value(t, part.family, Icon.Read)
	testing.expect_value(t, part.from, 120)

	found := shell_read("grep -rn peek_rows src/")
	testing.expect_value(t, found.family, Icon.Find)
}

// And the ones that must not be taken for edits. Every second command in a
// transcript ends in `2>&1` or throws its output at /dev/null, and a stone
// that went blue for either would say the turn had changed a file when it had
// run the tests.
@(test)
a_command_that_writes_nothing_stays_a_command :: proc(t: ^testing.T) {
	for cmd in ([?]string {
		"odin test src -define:ODIN_TEST_FANCY=false 2>&1 | tail -3",
		"./build.sh >/dev/null 2>&1",
		"git log --oneline -1",
	}) {
		sh := shell_read(cmd)
		testing.expectf(t, sh.family == .Run, "%s came out as %v", cmd, sh.family)
		testing.expect_value(t, len(sh.swaps), 0)
	}
}
