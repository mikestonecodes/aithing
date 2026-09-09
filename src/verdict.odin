package aithing

import "core:strings"

// A card said `complete` because its process exited zero. Those are not the
// same question. `claude -p` exits zero when the turn is over, and a turn is
// over just as cleanly when the agent has written two paragraphs asking which
// of two things you meant — so a card that had done nothing but ask sat on
// the grid, dimmed and green, next to the ones that had actually been done.
//
// There is nothing in the stream that says whether the work got done: the
// exit code is about the process and the `result` record is about the turn.
// The only thing that knows is the agent, so the agent is asked. A headless
// card turn is given the card's wording with a preamble on the front, and it
// ends its last message with one of two markers.
//
// A turn that ends without one is read as Asked, not Done. That way round on
// purpose: an agent that did the work and forgot the marker leaves a card
// asking to be looked at, which costs a glance, and the other way round is
// the bug this is here to fix.
Verdict :: enum {
	None, // it never said, which is not a claim that the work is finished
	Done,
	Blocked,
}

PREAMBLE_OPEN :: "<aithing>\n"
PREAMBLE_CLOSE :: "</aithing>\n"

DONE_MARK :: "<aithing>done</aithing>"
BLOCK_MARK :: "<aithing>blocked</aithing>"

// What goes in front of a card's wording. Only headless turns get it: a turn
// typed into the composer draws into a transcript somebody is reading, and
// the person reading it can see perfectly well that it asked a question.
verdict_preamble :: proc(text: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate(
		{
			"<aithing>\n",
			"You are running one card off a board, on your own, with nobody watching the\n",
			"transcript. The card is the whole of the work. When you have no more to do,\n",
			"end your last message with one of these on a line of its own:\n\n",
			DONE_MARK,
			"     the work is finished\n",
			BLOCK_MARK,
			"  you are asking a question, or cannot go on\n\n",
			"A question with no marker after it is read as blocked, because nobody is\n",
			"there to answer it — say what you need on the line before the marker.\n\n",
			"`done` is about your having finished, not about code having changed: a card\n",
			"that only wanted an answer is done once you have given it. Report what you\n",
			"actually did and nothing else — a card that wrote no code has merged, pushed\n",
			"and built nothing, and nobody is reading the transcript to catch it.\n",
			"</aithing>\n\n",
			text,
		},
		allocator,
	)
}

// A stored prompt as a person should see it. The preamble goes on in one
// place, so it comes off in one: every read of what was sent that ends up on
// screen. The harness writes the prompt it was handed straight into the
// session file, so the card's thread was titled `<aithing>` and its transcript
// opened on the instructions we wrote to ourselves — the card's own wording,
// the only part anybody typed, was three paragraphs down and off the end of
// the line.
verdict_unwrap :: proc(text: string) -> string {
	if !strings.has_prefix(text, PREAMBLE_OPEN) do return text
	at := strings.index(text, PREAMBLE_CLOSE)
	if at < 0 do return text
	return strings.trim_left_space(text[at + len(PREAMBLE_CLOSE):])
}

// The same for what comes back. The marker is a word between this program and
// the agent, and a transcript that ends `<aithing>done</aithing>` is showing
// the reader a handshake, not an answer.
verdict_unmark :: proc(text: string) -> string {
	out := strings.trim_space(text)
	if strings.has_suffix(out, DONE_MARK) do out = out[:len(out) - len(DONE_MARK)]
	else if strings.has_suffix(out, BLOCK_MARK) do out = out[:len(out) - len(BLOCK_MARK)]
	return strings.trim_space(out)
}

// The agent's last word, off the text of one message. The later of the two
// markers wins, so a message that quotes the instructions before using them
// still ends up saying what it meant.
verdict_read :: proc(text: string) -> Verdict {
	done := strings.last_index(text, DONE_MARK)
	block := strings.last_index(text, BLOCK_MARK)
	if done < 0 && block < 0 do return .None
	return block > done ? .Blocked : .Done
}

// What the card shows beside `needs you`. A headless turn has no transcript
// anyone can open in a hurry, so the question has to travel to the grid the
// same way a failure's reason does — and a card that says `needs you` and
// nothing else is one you cannot act on.
verdict_say :: proc(text: string, allocator := context.temp_allocator) -> string {
	body := text
	if at := strings.last_index(body, BLOCK_MARK); at >= 0 do body = body[:at]
	if at := strings.last_index(body, DONE_MARK); at >= 0 do body = body[:at]
	body = strings.trim_space(body)
	// The tail, not the head: what an agent asks is the last thing it writes,
	// under whatever it did first.
	if at := strings.last_index_byte(body, '\n'); at >= 0 {
		if tail := strings.trim_space(body[at + 1:]); tail != "" do body = tail
	}
	return strings.clone(one_line(body, 160), allocator)
}
