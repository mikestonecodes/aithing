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
frames are only drawn on input or animation. That number is not a claim, it is
a test: `the_grid_is_cheap_to_rebuild` in `src/grid_cost_test.odin` builds a
list that size and fails if a rebuild goes over its budget. It is there
because the number was once wrong by two orders of magnitude — the sweep asked
where the worktree cache was once per session, which is a `mkdir` per session
per call, and the search lowercased four fields of every session into fresh
copies on top. The answer to a slow derived list is to make deriving it cheap
and to pin the cost; reach for a cache only when that has been tried.

## Build and test

```sh
./build.sh                                  # or: odin build src -out:aithing
odin test src -define:ODIN_TEST_FANCY=false
```

Both must pass before anything is finished.

## Finishing a card

A card is not done when the work is written. It is done when the binary the
user launches — `/home/mike/Source/aithing/aithing` — has the work in it. That
is four steps, not two, and the last one is the one that gets forgotten:

```sh
git fetch origin && git merge --no-edit origin/main   # in the card's worktree
git push origin HEAD:main
git -C /home/mike/Source/aithing merge --ff-only origin/main
/home/mike/Source/aithing/build.sh
```

Do all four every time, follow-ups included, as the last step and not as
something to ask about. Then check that
`git -C /home/mike/Source/aithing log --oneline -1` is what you just pushed.

The last two are not ceremony. A card runs in a worktree, which cannot check
out `main` because the primary checkout is holding it, so `git push origin
HEAD:main` moves the *remote* ref and nothing else: the primary checkout stays
on whatever commit it was on, and `./build.sh` run from the worktree builds a
binary in the worktree that nobody launches. The window does not rebuild itself
either — auto reload and `dev.sh` were deleted — so a card that stops after the
push has changed nothing the user can see. This has already happened once: a
finished card was pushed, the app was restarted, the old version came up, and
the question was whether a merge had overwritten the work. It had not. The
build had gone somewhere nobody was looking.

Rebuilding while the app is running is safe — the linker unlinks the output
first — but the running process keeps the old inode, so say that it needs a
restart.

## Comments

Comments here say *why*, in prose, and usually name what the code used to do
and what went wrong with it. Match that. A comment restating the line below it
is noise; a comment explaining the bug that shaped the line is the point.
