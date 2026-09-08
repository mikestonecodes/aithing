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

`./dev.sh` rebuilds on every change under `src/`. A running window stats its
own binary twice a second, and when a newer one lands it `exec`s over itself —
same process, same place: the open session, the model and whatever is
half-typed in the composer all come back. Nothing coordinates the two, the
build is the signal, so a plain `./build.sh` from another terminal reloads an
open window just as well. A reload never interrupts a turn in flight; it waits
for the answer to finish.

## Use

```sh
./aithing                          # reopens the most recent session
./aithing --new                    # a blank chat in the current directory
./aithing --model haiku "hello"    # send a prompt straight away
```

- The **grid** is the home view, and it starts empty: a card on it is one
  thing you asked for, put there by you. Each card says where its work stands
  — waiting, queued, processing, complete, failed — and a card whose turn is
  running says what that turn is doing right now. Work that came back clean
  stays on the grid, drawn back, until it is dismissed. Clicking a card opens
  its thread at the message it is about, unless its own turn is still running,
  in which case it stays where it is and goes on saying so. **Esc** zooms back
  out, and from the grid it backs out of a narrowed view. Arrows move between
  cards.
- The **x** on a card takes it off the grid for good. What was dismissed is
  written down beside the list, because the two things that make cards — the
  stub every unread thread gets and the list the agent hands back — would
  otherwise put it straight back on the next scan. A thread whose last card
  has gone is filed off the map with it.
- The **box along the bottom** is where a list is written. It asks for
  nothing but the work: where one item stops and the next begins is worked out
  from what was written — a line, a bullet, a numbered point, a sentence —
  and the count under the box says what was made of it before **Enter** is
  pressed. What was typed goes out as **one thread**, the way it would if it
  had been typed into a composer, and the parts are the cards on it.
  **Enter** over an empty box opens the card the cursor is on, and a card
  nothing has started yet joins the run queue.
- **Enter** sends inside a thread, **Shift+Enter** is a newline, **Esc**
  closes the open thread. Esc never stops work — that is **Ctrl+C**.
- **Super+V** pastes — an image on the clipboard becomes an attachment,
  anything else is pasted as text. **Super+C/X** copy and cut the selection,
  and **Super+A** selects all. Copy is super rather than ctrl so that
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

**Threads are read once.** A thread gets its cards from one agent pass and
keeps them. Re-reading one because it had grown meant every turn anyone took —
here or in another window — rewrote that thread's whole card set underneath
whoever was looking at it, so cards appeared, moved and reworded themselves at
random. A thread this window started from a card is never read at all: the
card already says what the thread is for.

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

**A card is a piece of work, and the grid folds both ways round it.** One
thread carries several items, so a thread is several cards: what is typed into
the box in one go is one prompt to one thread — the second line is usually
about the first, and cutting it into separate conversations would throw away
everything each part knows about the others — and the parts are a card each.
And the same item picked up in several threads is one card: a context that
filled up, a window closed and opened again, a second run at the same thing
the next morning are all the same piece of work, so the newest of them is the
card and it says how many threads are behind it. Wordings are folded down to
their letters and digits before they are compared, so `Fix the caret.` and
`fix the caret` are one item. A card nothing has started is never folded into
another: it is waiting on a person, which is not something to hide behind a
count.

**Turns are slots, and there are four.** A turn started from the grid is
headless: its own
`claude -p`, its own thread on disk, no transcript on screen. So four cards go
out together rather than one after another, each holding a slot until it is
done, and the fifth waits for one. The card itself says `processing`, and
clicking it opens the thread as soon as the harness has named one. Only the
turn typed into the composer draws into the transcript, because there is only
one transcript.

Each slot owns its process, its reader thread and its event list, and the
slots are a fixed array that is never moved or compacted — the reader thread
holds a pointer into its own slot. Two turns are never pointed at one thread,
which would be two `--resume`s of a session racing each other, so a follow-up
typed into a busy thread still waits in the message queue behind it.

**Ctrl+C** stops one turn: the one in the thread on screen, or the one behind
the card the cursor is on. One, never all of them. Esc stops nothing at all —
it used to fall through to killing every turn in flight, and since a killed
`claude` exits non-zero and arrives as a failure, a press that found nothing
else to back out of turned every running card red with nothing on screen to
say why. The run queue survives the auto-reload, which is the one thing that
takes a window over mid-list.

Nothing stops two slots being pointed at the same working directory, so four
lists written against one project are four processes editing one checkout.

**Nothing blocks.** The window sleeps on the compositor's socket until
something happens; a keystroke is drawn on the frame it arrives in rather than
waiting out a frame budget, and every Vulkan wait has a timeout, so a hidden or
unresponsive compositor can never park the program inside the driver.

## The list

A thread is not a piece of work. One thread carries the bug that started it,
the two follow-ups and the thing noticed halfway through, and a grid with one
card per thread hides every one of them behind the first sentence anyone
happened to type. So the card is the item, and the two follow from that.

A list typed into the box in one go is **one thread and a card a part**. Where
one item stops and the next begins is worked out from what was written — a
line, a bullet, a numbered point, a sentence — and the whole of it goes out as
one prompt, the way it would if it had been typed into a composer. Cutting it
into separate conversations would throw away what each part knows about the
rest; the cards are how it reads back on the grid afterwards.

The same item carried in several threads is **one card**. A context that
filled up, a window closed and opened again, a second run at the same thing
the next morning are all the same piece of work: the newest of them is the
card and it says how many threads are behind it. Wordings are folded to their
letters and digits before they are compared, so `Fix the caret.` and `fix the
caret` are one item.

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
someone is using. The state file is the same picture the auto-reload hands to
the binary that replaces it, by the same serializer, which is why a normal
launch and a reload put back exactly the same thing.

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
| `src/todos.odin` | the items themselves: the store, batches, and cutting typed text into them |
| `src/state.odin` | what was on screen, written down and put back |
| `src/archive.odin` | threads filed away by hand, and the saved model |
| `src/groups.odin` | which threads are the same task, read off their titles |
| `src/manager.odin` | routing a draft to the thread it is plainly about |
| `src/draw.odin` | sidebar, transcript, composer, the text box |
| `src/chat.odin` | the transcript model shared by the loader and the runner |
| `src/runner.odin` | `claude -p`, and the NDJSON reader thread |
| `src/turns.odin` | the slots those run in: several turns at once |
| `src/sessions.odin` | reading `~/.claude/projects` |
| `src/jobs.odin` | the scan and parse worker threads |
| `src/reload.odin` | noticing a rebuilt binary and exec'ing it over this one |
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

## Known limits

- Keys are translated against a US layout. The compositor sends an xkb keymap
  and translating it properly is what libxkbcommon is for, which this program
  does not link; a non-US layout types US characters.
- The glyph atlas is Latin only — ASCII, the Latin-1 supplement, and the
  punctuation and box drawing an answer actually contains. There is no CJK and
  no emoji; anything outside the sheet draws as `?`.
- Fractional scaling is not handled — only integer `preferred_buffer_scale`.
