package aithing

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// What asking every stone what it is costs, for a thread of the size that
// actually turns up.
//
// The path is rebuilt from the chat on every frame, and every stone on it is
// asked for its colour and its mark. For a shell call that answer is read out
// of the command — which means the text of a four-kilobyte python heredoc is
// walked, per stone, per frame. That is only the right way round while the
// walk is one pass with a switch on the byte; the first version searched the
// command for each of fifteen markers in turn, which is fifteen passes over
// everything, and it is the reason this file exists.
//
// The alternative is to work the family out once and keep it on the block,
// which is a second copy of something the input already says. This is the
// measurement that argument would have to beat.
@(private = "file")
STONES :: 400
// Generous against the tenth of a millisecond it takes: this is here to catch
// a return to a search per marker, not to police a microsecond.
@(private = "file")
BUDGET_MS :: f64(2)

@(test)
the_path_is_cheap_to_colour :: proc(t: ^testing.T) {
	// A long session's worth of stones: mostly short commands, with a python
	// heredoc of the length those actually run to every fourth call. The
	// heredoc is the expensive one — it is the only shape whose text has to
	// be looked at at both ends.
	script := strings.builder_make()
	defer strings.builder_destroy(&script)
	strings.write_string(&script, `{"command": "python3 - <<'EOF'\np = 'src/peek.odin'\ns = open(p).read()\n`)
	for i in 0 ..< 60 {
		fmt.sbprintf(&script, `old_%d = 'a line of a file that is being put somewhere else, number %d'\n`, i, i)
	}
	strings.write_string(&script, `s = s.replace(old_0, old_1)\nopen(p, 'w').write(s)\nEOF"}`)
	heredoc := strings.to_string(script)
	short := `{"command": "odin test src -define:ODIN_TEST_FANCY=false 2>&1 | tail -3"}`
	testing.expect(t, len(heredoc) > 4000, "the fixture is meant to be longer than both windows")

	// The answers, first: a measurement of the wrong answer is worth nothing.
	_, edit := tool_style("Bash", heredoc)
	_, run := tool_style("Bash", short)
	testing.expect_value(t, edit, Icon.Edit)
	testing.expect_value(t, run, Icon.Run)

	// Every stone answering for itself, the way snake_gather asks.
	ROUNDS :: 10
	icon: Icon
	start := time.now()
	for _ in 0 ..< ROUNDS {
		for i in 0 ..< STONES do _, icon = tool_style("Bash", i % 4 == 0 ? heredoc : short)
	}
	ms := time.duration_milliseconds(time.since(start)) / ROUNDS
	fmt.eprintfln("  path, %d shell stones: %.3f ms (%v)", STONES, ms, icon)
	testing.expectf(t, ms < BUDGET_MS, "colouring %d shell stones took %.3f ms, over the %.1f ms budget", STONES, ms, BUDGET_MS)
}
