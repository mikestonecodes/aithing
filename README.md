# aithing

A native window around Claude Code. Every turn is a real `claude -p` process —
the harness, the tools, the permissions and the session files are all Claude
Code's own — and this program does nothing but draw: a grid of everything
being worked on, an item a card, grouped by project, and a transcript that a
card zooms open into.

Odin, raw Wayland, raw Vulkan, one GLSL pipeline. No GLFW, no SDL, no Dear
ImGui, no egui, no libxkbcommon, no C build step. The immediate-mode UI is the
same one behind [spoticyclint](https://github.com/mikestonecodes/spoticyclint),
carried over and extended with text input, a clipboard and a text caret.

## Build

```sh
./build.sh          # or: odin build src -out:aithing
```

Links against `libwayland-client` and `libvulkan`, plus Odin's vendored
`stb_image`. `build.sh` regenerates the Wayland protocol bindings, recompiles
the shaders and rebakes the font atlas when `python3`, `glslc` and
`msdf-atlas-gen` are present; all three outputs are committed, so none of them
is needed for a plain build.

Needs the `claude` CLI on `PATH`.

## Use

```sh
./aithing                          # reopens the most recent session
./aithing --new                    # a blank chat in the current directory
./aithing --model haiku "hello"    # send a prompt straight away
```

- The **line above the grid** says what the grid is showing: the project it
  has been narrowed to, or `all projects`. Beside it, where a card typed below
  will land — the narrowing when there is one, the project last opened
  otherwise. Without that second half there was nothing on screen saying where
  new work would go, and it went wherever the window happened to have been
  launched; with the two of them collapsed into one name, a grid of every
  project sat under one project's heading.
- The **grid** is the home view, and it starts empty: a card on it is one
  thing you asked for, put there by you. Each card says where its work stands
  — waiting, processing, complete, failed — and a card whose turn is
  running says what that turn is doing right now. Work that came back clean
  stays on the grid, drawn back, until it is dismissed. Clicking a card opens
  its thread — a card whose turn is still running included, and its output
  streams into the transcript you just opened.
  **Esc** gives up one thing per press: the launcher, the model picker, the
  open thread, whatever is half-typed, and then the narrowing. **Left** and
  **right** move between cards; **up** and **down** belong to the box below.
- The **x** on a card takes it off the grid for good. What was dismissed is
  written down beside the list, because the two things that make cards — the
  stub every unread thread gets and the list the agent hands back — would
  otherwise put it straight back on the next scan. A thread whose last card
  has gone is filed off the map with it.
- The **box along the bottom** is where a list is written. It asks for
  nothing but the work: where one item stops and the next begins is a line,
  a line each. Every part is a card and a thread of its own, and they go out
  together. **Up** and **down** walk back through what has already been typed
  there, the way a shell does; **Enter** over an empty box opens the card the
  cursor is on, and a card nothing has started yet is started.
- **Enter** sends inside a thread, **Shift+Enter** is a newline, **Esc**
  closes the open thread. Esc never stops work — that is **Ctrl+C**.
- **Super+V** pastes — an image on the clipboard becomes an attachment,
  anything else is pasted as text. **Super+C/X** copy and cut, and **Super+A**
  selects all. Copy with nothing selected takes whatever the pointer is
  resting on: a card, a paragraph of an answer, an error. Copy is super rather than ctrl so that
  **Ctrl+C** can mean the one thing it means everywhere else: stop what is
  running. Inside a thread that stops the thread's turn and the follow-ups
  typed behind it; on the grid it stops the card the cursor is on.
- **Ctrl+N** new thread in the current directory, **/** or **Ctrl+F** opens
  the launcher (type to narrow, a project row narrows the grid), **Ctrl+M**
  cycles the model, **Ctrl+R** rescans the session list.
- Closing the window and opening it again puts back what was on screen: the
  thread that was open, the project the grid was narrowed to, the card the
  cursor was on, how far down it was scrolled, the model and both half-typed
  boxes.
- The two words in the corner of the composer are the model and the permission
  mode; both cycle on click.

## What it does

**The harness is the CLI.** A turn runs

```
claude -p <prompt> --output-format stream-json --include-partial-messages \
       --verbose --permission-mode <mode> [--model <m>] [--resume <session>]
```

in the session's own working directory. Its NDJSON is read on a worker thread
and turned into events the window applies to the transcript: text and thinking
arrive as deltas, tool calls appear the moment the model starts writing their
arguments, and anything carrying a `parent_tool_use_id` is a subagent, so its
output is nested under the Task that spawned it rather than spliced inline.
The session id comes back in the `init` record and is what `--resume` gets for
the next turn, which means a conversation started here continues in `claude`
itself, and vice versa.

**A card is a thread.** One each. What is typed into the box is cut into a card
a line, and every card gets its own `claude -p` in its own conversation. The
parts used to ride on one thread between them, which meant a card could not be
opened, stopped or dismissed without the ones typed beside it coming along, and
every one of those was a special case in the code.

**The sidebar is `~/.claude/projects`.** One JSONL file per session; the scan
reads the head of each for the first prompt and the working directory, and the
tail for the title records Claude Code writes (`custom-title` beats `ai-title`
beats the last prompt). Sessions run to a hundred megabytes, so opening one
parses only the last 8 MB and says so at the top. Both the scan and the parse
happen on worker threads — the window never waits on the disk.

**Pasted images** are written to `~/.cache/aithing` and their paths appended to
the prompt, which is how a person would hand Claude a screenshot; the composer
shows a thumbnail of each. The clipboard is spoken directly to the compositor
(`wl_data_device`, `wl_data_source`), including `image/png`.

**The grid is what you put on it.** A card comes from the box along the
bottom, and from nowhere else. Nothing on the machine puts one there: a
thread started in another window, or in `claude` itself, does not turn up as a
card, and the grid of a fresh install is empty until something is typed into
it. Cards leave when they are dismissed, and that is the only way.

This is the third answer to the same question and the first one that holds
still. The grid used to give every thread on the machine a card of its own and
set an agent reading each one, so a few hundred threads meant a few hundred
cards nobody asked for, arriving over the following minutes. What it showed
was then rebuilt every ten seconds from rules that read the clock — a settle
window, a fortnight window, a cap per project, one card per group of related
threads — and ordered by session mtime, so cards appeared and vanished on
their own and the projects swapped places while nobody touched anything. And
rebuilding it walked every thread against every card several times a frame,
which on a few hundred of each is a few hundred thousand string joins a frame:
key presses took minutes to land.

What is left has no clock in it and no opinion about what deserves a place.
Projects come in a fixed order, cards within one come newest-made first, and a
card put down keeps its place until something is made above it or it is
dismissed. The reader that turned threads into cards is gone with it.

**A card is a piece of work, and nothing is folded into anything.** A line
typed into the box is a card, and that card is a conversation. The grid used to
fold cards worded alike down to one with a count of the threads behind it — a
context that filled up, a window closed and opened again, a second run at the
same thing the next morning — which meant the card you were looking at belonged
to a thread you had not chosen, and dismissing it took away one of several. A
card is one row, one thread, one thing to open.

**Turns are slots, and there are as many as are asked for.** A turn started
from the grid is headless: its own
`claude -p`, its own thread on disk, no transcript on screen. Every card asked
for goes out the moment it is asked for, however many that is. There was a
ceiling of four and a queue behind it, and a card in that queue said `queued`
— which is a card telling you its work is not being done while the machine
sits idle. The card says `processing`, and
clicking it opens the thread as soon as the harness has named one. Only the
turn typed into the composer draws into the transcript, because there is only
one transcript.

Each slot owns its process, its reader thread and its event list, and the
slots are allocated apart and never moved or compacted — the reader thread
holds a pointer into its own slot, and a settled slot is reused where it
stands. Two turns are never pointed at one thread,
which would be two `--resume`s of a session racing each other, so a follow-up
typed into a busy thread still waits in the message queue behind it. That is
the one thing left that waits, and it waits on the session file, not on a
slot.

**Ctrl+C** stops one turn: the one in the thread on screen, or the one behind
the card the cursor is on. One, never all of them. Esc stops nothing at all —
it used to fall through to killing every turn in flight, and since a killed
`claude` exits non-zero and arrives as a failure, a press that found nothing
else to back out of turned every running card red with nothing on screen to
say why.

Nothing stops two slots being pointed at the same working directory, so a
list written against one project is as many processes editing one checkout as
there are lines in it.

**Nothing blocks.** The window sleeps on the compositor's socket until
something happens; a keystroke is drawn on the frame it arrives in rather than
waiting out a frame budget, and every Vulkan wait has a timeout, so a hidden or
unresponsive compositor can never park the program inside the driver.

## The list

A thread is not a piece of work. One thread carries the bug that started it,
the two follow-ups and the thing noticed halfway through, and a grid with one
card per thread hides every one of them behind the first sentence anyone
happened to type. So the card is the item, and the thread follows from it.

A list typed into the box in one go is **a card a line, and a thread a card**.
A bullet or a number in front of a line is taken off; nothing else is guessed
at. The parts used to be joined back into one prompt on one thread — the second
line is usually about the first — and a full stop inside a line was a split too,
with a table of thirty words for spotting the sentences that had to be glued
back together again. All of it went with the shared thread: a guess about where
a sentence ends is a guess about where a conversation ends, and a line break is
not a guess.

Cards are made in that box and nowhere else. There was once an agent that read
every thread on the machine into cards of its own — a second `claude -p` per
thread, headless, asked for a JSON array — and it worked, in the sense that it
returned what it was asked for. It is gone, because a few hundred threads
meant a few hundred cards nobody asked for, arriving over the following few
minutes, and no amount of making that tidier makes it wanted.

The list is written to `~/.config/aithing/todos` beside the archive — the
cards, and every card dismissed by hand — and what was on screen to
`~/.config/aithing/state`, rewritten whenever it changes. `AITHING_CONFIG`
points the lot somewhere else, so a test run stays out of the way of a window
someone is using.

## Text

Glyphs come off one multi-channel signed distance field baked ahead of time by
`tools/gen_font_atlas.sh` and carried in the binary — all three fonts on one
1024x1024 sheet, in one bindless slot. The sheet stores the distance to each
glyph's outline rather than its coverage, so the fragment shader rebuilds a
sharp edge at whatever size the quad is: a 13px timestamp and a 24px heading
come off the same pixels, and moving the window to a display at another scale
costs nothing. The one number the shader cannot work out for itself is how many
screen pixels the distance ramp spans, which rides along in the vertex.

## Layout

| file | what's in it |
| --- | --- |
| `src/main.odin` | CLI, the frame loop, keyboard shortcuts |
| `src/app.odin` | app state, session switching, applying stream events |
| `src/canvas.odin` | the grid of cards, and the panel one zooms open into |
| `src/todos.odin` | the items themselves: the store, and cutting typed text into them |
| `src/state.odin` | what was on screen, written down and put back |
| `src/archive.odin` | threads filed away by hand, and the saved model |
| `src/groups.odin` | which threads are the same task, read off their titles |
| `src/manager.odin` | routing a draft to the thread it is plainly about |
| `src/draw.odin` | sidebar, transcript, composer, the text box |
| `src/chat.odin` | the transcript model shared by the loader and the runner |
| `src/peek.odin` | what a stone of the path opens into: a panel per family of tool |
| `src/shell.odin` | what a shell command actually did: read off the command, not run |
| `src/runner.odin` | `claude -p`, and the NDJSON reader thread |
| `src/turns.odin` | the slots those run in: as many turns at once as asked for |
| `src/sessions.odin` | reading `~/.claude/projects` |
| `src/jobs.odin` | the scan and parse worker threads |
| `src/watchdog.odin` | the phase a frozen frame loop stopped in |
| `src/crash.odin` | a backtrace to `crash.log` when a signal kills it |
| `src/font.odin` | the MSDF glyph sheet: metrics, lookup, measuring |
| `src/font/` | `atlas.png` and `atlas.bin`, baked by `tools/gen_font_atlas.sh` |
| `src/markdown.odin` | wrapping and drawing headings, lists, code, inline spans |
| `src/textedit.odin` | the editor buffer: cursor, selection, word motion |
| `src/keys.odin` | evdev keycodes to characters |
| `src/clipboard.odin` | `wl_data_device` paste and copy |
| `src/attach.odin` | pasted images |
| `src/ui.odin` | immediate-mode core: draw list, ids, widgets, animation |
| `src/window.odin` | Wayland window, xdg-shell, pointer, keyboard, key repeat |
| `src/gpu*.odin` | Vulkan: swapchain, bindless textures, the UI pipeline |
| `src/shaders/` | `ui.vert`, `ui.frag` and their compiled SPIR-V |
| `src/wayland/` | `client.odin` (hand-written), `protocol.odin` (generated) |

## When it goes wrong

Both of the failures a window cannot narrate itself are written down instead.
A frame loop that stops moving for three seconds prints `STALL: <phase>` — the
phase being whichever of poll, events, jobs, input, build or draw it stopped
in. A fatal signal appends a named backtrace to `~/.cache/aithing/crash.log`
before the process dies; `build.sh` links with `--export-dynamic` so the frames
carry names, and `BUILD_FLAGS=-debug ./build.sh` adds line numbers.

Not every death is a signal: a failed Vulkan call leaves through `os.exit`,
which no handler sees, so those write their reason to `crash.log` on the way
out too.

Everything the program prints goes to `~/.cache/aithing/last-run.log` when
stderr is not a terminal, which is where an Odin bounds-check message lands.
`AITHING_LOG=<name>` puts it somewhere else, so a test run does not truncate
the log of a window someone is using.
`debug.sh` runs the whole thing under gdb for the cases neither catches.

`AITHING_CYCLE=1` walks every session on disk, one every 400ms, through the
same deferred-click path a pointer uses and with a rescan racing each one: it
is how the transcript reader and the session switching are exercised against
every session on the machine rather than the handful anyone would click.
`AITHING_PROFILE=1` reports frame build and draw times, and keystroke latency.

## Looking at it without looking at it

```sh
./aithing --shot out.png --scene grid      # grid, project, thread, opening, launcher
./aithing --shot out.png --scene peek      # peek, command, plan, script: a stone's panel open
./aithing --shot out.png --scene thread --size 1600x1000
```

One frame, drawn into an image of the program's own and written out as a PNG.
There is no window and no compositor involved, so it runs over ssh and from an
agent editing this source; and the state is built rather than arrived at — a
scene in `src/shot.odin` says what is on the grid, which card is running, what
the failed one said and which thread is open, so the same picture comes out on
a machine that has never run a turn. Two runs of a scene are byte-identical:
the animations are settled at a fixed timestep first and the shader clock is
put back to zero for the frame that is kept.

`peek`, `command`, `plan` and `script` rest the pointer on a stone of the path
so that the panel under it is in the picture: an edit as a diff, a shell
command with what it printed, a plan with its boxes, and a file rewritten by a
python heredoc — which is an edit, and is drawn as one. Which stone is a
number in `scene_stone`, counted along the path, rather than a pixel.

`opening` is the one scene that is not settled: it is a card partway through
becoming a thread, stopped at a fixed frame, which is the only way to look at
that movement without pointing a camera at a screen.

The window is see-through where the compositor blurs the desktop through it,
and a file has no desktop; those places are filled with the window's own colour
on the way out, so a screenshot is the interface and not a hole.

## Known limits

- Keys are translated against a US layout. The compositor sends an xkb keymap
  and translating it properly is what libxkbcommon is for, which this program
  does not link; a non-US layout types US characters.
- The glyph atlas is Latin only — ASCII, the Latin-1 supplement, and the
  punctuation and box drawing an answer actually contains. There is no CJK and
  no emoji; anything outside the sheet draws as `?`.
- Fractional scaling is not handled — only integer `preferred_buffer_scale`.
