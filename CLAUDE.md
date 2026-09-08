# Working on aithing

## One variable per question

The rule this codebase is held to: **anything on screen is drawn from one
variable, a click writes that variable, and the frame reads it.** No second
copy, no field kept in step with another field, no "invalidate this when that
changes".

Every out-of-sync bug this program has had came from two places holding an
opinion about the same thing and one of them being wrong: a heading printing
the last project worked in over a grid of all of them, a card that would not
open because a special case only moved the cursor onto it, a bubble left
dimmed because the third place that had to clear a flag forgot.

When something on screen is wrong, look for the second copy before patching
the symptom.

### How it is done here

- **What is on screen** is `App.page` (`Grid` | `Thread`) and `App.overlay`
  (`None` | `Launcher` | `Model`). Two orthogonal questions, one variable
  each. An overlay shuts by going back to the page underneath, so it never
  has to remember where it came from.
- **Where the caret is** is not stored. `app_focus()` works it out from the
  page. Neither is **what the thread is called** (`app_chat_title()`, read off
  the session list), **which session is open** (`session_index` of
  `chat.session_id`, never an index kept beside it), or **which project you
  are in** (`app_project()` — one answer, not four open-coded ones).
- **The derived lists** — the grid and the launcher's sessions — are rebuilt
  on read, in `canvas_layout()` and `app_visible()`. There are no version
  counters and nothing calls `app_filter` by hand. An index that never
  outlives the call that made it cannot go stale.
- **What a card is doing** is read off the process doing it:
  `todo_display_state()` asks the turns. Only settled
  states — `Open`, `Asked`, `Done`, `Failed` — are ever written down;
  `todo_set_state` asserts that.
- **Whether the work got done** is not the exit code. A turn ends just as
  cleanly when the agent stopped to ask a question, so the agent is asked for
  a verdict (`verdict.odin`) and `turn_outcome()` reads it; a turn that never
  said is `Asked`, never `Done`.
- **Where you can type** is `app_capture_open()` — the grid's box exists when
  the grid names one project — and `app_focus()` reads it, so the box and the
  caret cannot disagree. Nothing waits to go out: a message typed into a busy
  thread starts its own turn beside the one already running.

### When a cache is allowed

Only for measured cost, and only behind a single funnel that every write goes
through. Two exist: `Todos.per_session` (a refcount via `session_claim` /
`session_release`; deriving it is the scan that used to cost a tenth of a
second) and `app.heights` (transcript measurement, keyed on `chat_ver`).
Adding a third needs a measurement, not a hunch — the per-frame rebuild of the
whole grid costs about half a millisecond at 1200 sessions and 400 cards, and
frames are only drawn on input or animation.

## Build and test

```sh
./build.sh                                  # or: odin build src -out:aithing
odin test src -define:ODIN_TEST_FANCY=false
```

Both must pass before anything is finished.

## Comments

Comments here say *why*, in prose, and usually name what the code used to do
and what went wrong with it. Match that. A comment restating the line below it
is noise; a comment explaining the bug that shaped the line is the point.
