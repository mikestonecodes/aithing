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
`stb_truetype` and `stb_image`. `build.sh` regenerates the Wayland protocol
bindings and recompiles the shaders when `python3` and `glslc` are present;
both outputs are committed, so neither is needed for a plain build.

Needs the `claude` CLI on `PATH`.

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

## Known limits

- Keys are translated against a US layout. The compositor sends an xkb keymap
  and translating it properly is what libxkbcommon is for, which this program
  does not link; a non-US layout types US characters.
- The glyph atlas covers ASCII and Latin-1, with the punctuation Claude tends
  to use (curly quotes, em dashes, bullets) folded onto the nearest ASCII.
- Switching sessions while a turn is running is refused rather than queued.
- Fractional scaling is not handled — only integer `preferred_buffer_scale`.
