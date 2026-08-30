# aithing

A native window around Claude Code. Every turn is a real `claude -p` process —
the harness, the tools, the permissions and the session files are all Claude
Code's own — and this program does nothing but draw: a mailbox of every session
on the machine down the left, the transcript in the middle, a composer at the
bottom.

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

- **Enter** sends, **Shift+Enter** is a newline, **Esc** interrupts the turn.
- **Ctrl+V** pastes — an image on the clipboard becomes an attachment, anything
  else is pasted as text. **Ctrl+C/X** copy and cut the selection.
- **Ctrl+N** new chat, **Ctrl+F** search, **Ctrl+M** cycles the model,
  **Ctrl+P** cycles the permission mode, **Ctrl+R** rescans the session list.
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

**Nothing blocks.** The window sleeps on the compositor's socket until
something happens; a keystroke is drawn on the frame it arrives in rather than
waiting out a frame budget, and every Vulkan wait has a timeout, so a hidden or
unresponsive compositor can never park the program inside the driver.

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
| `src/draw.odin` | sidebar, transcript, composer, the text box |
| `src/chat.odin` | the transcript model shared by the loader and the runner |
| `src/runner.odin` | `claude -p`, and the NDJSON reader thread |
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
