package aithing

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Cards run several at a time, and they all used to run in the same checkout.
// Four agents editing one working tree is four agents each building on top of
// what the other three had half-written: a card would come back green having
// run a test suite that another card had just broken, and the diff at the end
// belonged to nobody.
//
// So a card that lives in a git repository gets a worktree of its own, on a
// branch of its own, and its harness is started in there. The branch is
// `aithing/<card id>`, which is the card id and nothing else, so the same
// card asked twice lands back in the tree it was working in.
//
// A card that finishes puts its work back where it came from and then gives
// the tree up — worktree_land, then worktree_release, in that order and in
// one place. Neither used to happen: a branch per card and nothing that ever
// merged one, so a week of green cards was a week of `aithing/n-*` branches
// and a cache full of checkouts that somebody had to go and find by hand,
// and the answer to "is this card's work in the project?" was "go and look".
// It is not written down now either — a landed card has no tree and no branch,
// and that is the whole of the record.
//
// What is worth keeping, when a card did not finish, is git's call and not
// ours, because this program is a bad judge of it. `worktree remove` without
// --force refuses a tree with anything modified or untracked in it, and
// `branch -d` refuses a branch whose commits are not already in HEAD, so a
// card that committed its work loses the tree and keeps the branch, and a card
// with an afternoon of uncommitted editing in it keeps both. Removal used to
// be forbidden outright for exactly that fear, and the cost of the fear was a
// cache full of checkouts of every card anyone had ever run.
//
// Nothing is written down about a tree that went. The path is worked out from
// the card, so a card asked for again is checked out again — see
// worktree_restore for the other door into that, a follow-up typed into a
// thread whose tree has since been given back.
//
// One thing follows from a card working in a checkout of HEAD: uncommitted
// changes in the main tree are not in it — the agent sees the last commit,
// not what you have open in your editor.
//
// A big repository is where this gets expensive: `git worktree add` copies out
// every file, and a project carrying a gigabyte of assets pays that per card.
// The fix is a checkout that leaves the assets behind — sparse-checkout for
// the paths the work touches, with the rest read out of the main tree — and it
// is not written yet, because the projects this runs on today check out in
// well under a second.

// Where a card's tree goes, worked out from the card and nothing else, so
// nothing has to be written down to find it again.
worktree_path :: proc(project, id: string, allocator := context.temp_allocator) -> string {
	name := fmt.tprintf("%s-%s", base_name(project), id)
	return cache_path(fmt.tprintf("worktrees/%s", name), allocator)
}

// The directory a card's turn runs in. The project itself when it is not a git
// repository, or when git would not make the tree: a card that cannot have a
// worktree still has work to do, and refusing to run it would be worse than
// running it where it was always run.
//
// Called on the click that starts a card, and it waits for git. A checkout of
// this repository is a few milliseconds; see the note above for the one that
// is not.
worktree_for :: proc(project, id: string, allocator := context.allocator) -> (dir: string, why: string) {
	if project == "" || id == "" do return strings.clone(project, allocator), ""
	if ok, _ := git(project, {"rev-parse", "--git-dir"}); !ok {
		return strings.clone(project, allocator), ""
	}
	path := worktree_path(project, id)
	if os.exists(path) do return strings.clone(path, allocator), ""

	os.make_directory_all(filepath.dir(path))
	// A tree someone deleted by hand is still registered, and the add fails
	// on the name until the stale record goes.
	_, _ = git(project, {"worktree", "prune"})
	// The branch outlives the tree, and now that a finished card's tree is
	// given back (worktree_release) that is the ordinary case rather than the
	// odd one: a card asked for a second time has to land back on the commits
	// it made. This used to add with -B, which resets the branch to HEAD —
	// with nothing ever removing a tree that could only happen after someone
	// deleted one by hand, and it would have thrown that card's commits away.
	branch := worktree_branch(id)
	args := []string{"worktree", "add", path, branch}
	if !worktree_has_branch(project, branch) do args = {"worktree", "add", "-b", branch, path, "HEAD"}
	if ok, msg := git(project, args); !ok {
		return strings.clone(project, allocator), strings.clone(one_line(msg, 160), allocator)
	}
	return strings.clone(path, allocator), ""
}

// Puts a card's work back where it came from, the moment the card says it is
// done. A branch per card and nothing that ever merged one meant the work was
// finished and nowhere: `git worktree list` grew a row a card, and a week of
// green cards was a week of branches you had to go and find by hand.
//
// The whole of this happens in the card's own tree until the last line. The
// obvious way round — check out the card's branch over the project, merge,
// check back — is the one that goes wrong, because the project is where a
// person is working: it has files open and half-written, and the version of
// this that stashed them, merged, and popped could hand you a conflict in
// work you had not finished and were not thinking about.
//
// So: the card commits what it did, the project's branch is merged *into* the
// card's, and then the project is fast-forwarded onto the result. A conflict
// is resolved on the card's branch or not at all, and the only thing ever
// done to the project's working tree is a fast-forward — which git itself
// refuses if it would write over a file somebody has modified. Nothing here
// stashes, resets or checks anything out.
//
// `why` empty is landed. Anything else is git's own sentence about what
// stopped it, and it goes on the card. `conflicted` says the tree has been
// left mid-merge, markers and MERGE_HEAD and all — which is not a mess to be
// cleaned up but the one thing an agent needs to fix it, so the caller starts
// a turn in there rather than giving up (see app_land_worktree).
//
// It waits for git, on the frame the turn ended. That is a commit and two
// merges — milliseconds on the repositories this runs on, and the same bet
// worktree_for already makes on the way in.
worktree_land :: proc(project, id, subject: string) -> (why: string, conflicted: bool) {
	if project == "" || id == "" do return "", false
	path := worktree_path(project, id)
	// A card whose tree has already gone. This used to answer "landed" for
	// one and do nothing, which is how a finished card ended up with its work
	// on a branch nobody would ever merge: the sweep takes the tree of every
	// finished card as the window opens, so by the time anything asked to
	// land it there was no tree to land from, and the branch was the only
	// record left that the work existed at all.
	if !os.exists(path) do return worktree_land_treeless(project, id), false
	branch := worktree_branch(id)

	// A tree already mid-merge is a tree something has already had a go at
	// resolving and did not finish. Saying so, rather than starting the merge
	// over, is the whole of what stops a card that cannot be landed going
	// round for ever — and it needs nothing written down, because a tree with
	// MERGE_HEAD in it is the record.
	if worktree_merging(path) do return "the merge was left unresolved", false

	// Whatever the agent left lying about. A card is one piece of work and
	// this is the end of it, so there is nothing to be gained by asking which
	// of the files it touched it meant: all of them, or the card is not done.
	if worktree_dirty(path) {
		if ok, msg := git(path, {"add", "-A"}); !ok do return one_line(msg, 160), false
		msg := subject != "" ? one_line(subject, 72) : fmt.tprintf("card %s", id)
		if ok, out := git(path, {"commit", "-m", msg}); !ok do return one_line(out, 160), false
	}

	// Where it goes back to: the branch the project itself has checked out,
	// which is the branch the tree was cut from. Not a name written down
	// anywhere and not "main" — a project sitting on a release branch would
	// have had its cards landed somewhere nobody was looking.
	base, has_base := worktree_head(project)
	if !has_base do return "the project is not on a branch", false
	if base == branch do return "", false // its own tree is the project's; nothing to land

	// Nothing of its own to give back. Not a failure: a card that read code
	// and answered a question is done, and there is no commit in it.
	if ahead, _ := git(path, {"merge-base", "--is-ancestor", branch, base}); ahead do return "", false

	// The project's branch, brought into the card's. This is where a conflict
	// surfaces, and it surfaces in the tree the work was done in — which is
	// the only place anyone could resolve it.
	//
	// Not aborted. This used to `merge --abort` and hand the card back saying
	// the branches conflict, which is a card that has stopped on the one job
	// the thing that did the work is best placed to finish: it wrote both
	// sides of half of it. The markers stay in the files and MERGE_HEAD stays
	// set, and the caller puts an agent in the tree.
	if ok, msg := git(path, {"merge", "--no-edit", base}); !ok {
		if worktree_merging(path) {
			return one_line(msg != "" ? msg : "the branches conflict", 160), true
		}
		return one_line(msg != "" ? msg : "the merge would not start", 160), false
	}
	return worktree_fast_forward(project, branch), false
}

// Landing what is left of a card once its tree has gone: the branch, and
// nothing else. There is nowhere to bring the project's branch into, so the
// merge happens the other way round, in the project itself — and a conflict
// there is put straight back, because the project's working tree is the one
// somebody has open, not a checkout made for a card. A card that conflicts
// this way keeps its branch and says so; the work is not lost, it is just not
// in yet.
@(private = "file")
worktree_land_treeless :: proc(project, id: string) -> (why: string) {
	branch := worktree_branch(id)
	if !worktree_has_branch(project, branch) do return "" // nothing of it left anywhere
	base, has_base := worktree_head(project)
	if !has_base do return "the project is not on a branch"
	if base == branch do return ""
	// Already in. Not a failure, and the common answer: most finished cards
	// were landed the moment their last turn ended.
	if ahead, _ := git(project, {"merge-base", "--is-ancestor", branch, base}); ahead do return ""

	if ok, msg := git(project, {"merge", "--no-edit", branch}); !ok {
		// Never left mid-merge. The tree-based path leaves the markers in
		// place on purpose, because an agent is put in that tree to settle
		// them — there is no such tree here, and leaving a half-merge in the
		// project would stop every card that landed after it.
		if worktree_merging(project) do _, _ = git(project, {"merge", "--abort"})
		return one_line(msg != "" ? msg : "the branches conflict", 160)
	}
	return ""
}

// The last step, and the only thing that ever touches the project's own
// working tree. The merge above made the card's branch a descendant, so this
// can only be a fast-forward — and --ff-only is the safety, because git will
// not take one that would write over a file somebody has modified.
//
// Which is the case worth going further on, and the one thing borrowed from
// the dashboard this replaces: when the only thing in the way is uncommitted
// work in the project, put it aside, take the fast-forward, and put it back.
// Refusing instead means a card that did its work perfectly does not land
// because of an unrelated file you happen to have open.
//
// The stash is only ever popped when this is the call that made it. `git
// stash push` with nothing to save exits zero and saves nothing, so a pop
// after it is a pop of whatever somebody stashed last week — which is why the
// ref is read either side rather than the exit code being trusted.
@(private = "file")
worktree_fast_forward :: proc(project, branch: string) -> (why: string) {
	ok, msg := git(project, {"merge", "--ff-only", branch})
	if ok do return ""
	if !worktree_dirty(project) do return one_line(msg != "" ? msg : "the project would not fast-forward", 160)

	before := worktree_stash(project)
	_, _ = git(project, {"stash", "push", "-u", "-m", fmt.tprintf("aithing: landing %s", branch)})
	ours := worktree_stash(project) != before
	ok2, msg2 := git(project, {"merge", "--ff-only", branch})
	if ours {
		// Back before anything else is said about it, landed or not: work
		// taken off somebody's tree without being asked has to go back on it
		// on every path out of here.
		if popped, pop_msg := git(project, {"stash", "pop"}); !popped {
			return one_line(fmt.tprintf("landed, but your own changes are stuck in git stash: %s", pop_msg), 160)
		}
	}
	if !ok2 do return one_line(msg2 != "" ? msg2 : "the project would not fast-forward", 160)
	return ""
}

// A tree stopped in the middle of a merge, which is the only record that
// anything has tried to resolve one here.
worktree_merging :: proc(path: string) -> bool {
	ok, _ := git_out(path, {"rev-parse", "-q", "--verify", "MERGE_HEAD"})
	return ok
}

// What the top of the stash is, or "" for an empty one. Read either side of a
// push to find out whether the push was ours to pop.
@(private = "file")
worktree_stash :: proc(project: string) -> string {
	_, out := git_out(project, {"rev-parse", "-q", "--verify", "refs/stash"})
	return strings.trim_space(out)
}

// Anything at all not committed in a tree, untracked files included — the
// same question `worktree remove` asks before it refuses.
@(private = "file")
worktree_dirty :: proc(path: string) -> bool {
	ok, out := git_out(path, {"status", "--porcelain"})
	return ok && strings.trim_space(out) != ""
}

// The branch a checkout is on, or false when it is on none. A detached HEAD
// is a project with nowhere to land work, which is a thing to say rather than
// a thing to guess a branch for.
@(private = "file")
worktree_head :: proc(path: string) -> (branch: string, ok: bool) {
	out: string
	out_ok := false
	out_ok, out = git_out(path, {"symbolic-ref", "--short", "-q", "HEAD"})
	if !out_ok do return "", false
	name := strings.trim_space(out)
	return name, name != ""
}

// Where the work goes once it has landed. Landing used to end at the merge
// into the project's branch, which is a branch on one machine: `main` sat
// fourteen commits ahead of the remote with nothing said about it, and a card
// whose work was finished, merged and invisible to everyone else read as a
// card that had not been done. So the landing pushes.
//
// A repository with no remote is silence, not a failure — plenty of what this
// runs on is local-only, and a note about it on every card would be noise. So
// is a detached HEAD: there is no branch name to push. Anything else is git's
// own sentence about why, which is the only thing worth saying about a push
// that was refused.
worktree_push :: proc(project: string) -> (why: string) {
	ok, remotes := git_out(project, {"remote"})
	if !ok do return ""
	names := strings.fields(remotes, context.temp_allocator)
	if len(names) == 0 do return ""
	branch, on_one := worktree_head(project)
	if !on_one do return ""
	if pushed, msg := git(project, {"push", names[0], branch}); !pushed {
		return one_line(msg != "" ? msg : "the push was refused", 160)
	}
	return ""
}

// Gives a card's tree back. What is worth keeping is git's call, not ours:
// the remove is the plain one, so a tree with anything modified or untracked
// in it stays, and the branch delete is `-d`, so a branch carrying commits
// that are not in HEAD stays too. False means nothing went, which is the same
// answer for a tree that was never there and one that had work in it — the
// caller does the same thing either way, which is nothing.
worktree_release :: proc(project, id: string) -> bool {
	if project == "" || id == "" do return false
	path := worktree_path(project, id)
	if !os.exists(path) do return false
	if ok, _ := git(project, {"worktree", "remove", path}); !ok do return false
	// Only after the tree has gone: a branch cannot be deleted while a
	// worktree has it checked out, and the commits are the reason to keep it.
	_, _ = git(project, {"branch", "-d", worktree_branch(id)})
	return true
}

// A tree that was given back comes back the moment work goes to it again. A
// card's turn asks worktree_for on the way in, but a follow-up typed into the
// thread of a finished card does not go through the card at all — it runs
// wherever the thread ran — and a working directory that is no longer there
// is a harness that will not start and a message that never went out.
//
// Not a second record of which trees exist: the path says which card it was,
// the card says which project, and git makes the checkout again.
worktree_restore :: proc(app: ^App, cwd: string) -> string {
	if cwd == "" || os.exists(cwd) do return cwd
	id := worktree_card(cwd)
	if id == "" do return cwd
	project := worktree_project(app, cwd)
	if project == cwd do return cwd
	dir, _ := worktree_for(project, id, context.temp_allocator)
	return dir
}

// Whether a tree is nobody's workplace any more: its card is finished, or its
// card is off the grid entirely. Everything that removes a tree asks this, so
// there is one sentence anywhere saying when a tree is done with.
//
// Running is not a state that is stored and is not one that is asked for here
// — the caller checks the turns, which is the only thing that knows.
worktree_idle :: proc(t: ^Todos, id: string) -> bool {
	at := todos_find(t, id)
	return at < 0 || t.list[at].state == .Done || t.list[at].state == .Merged
}

// Every tree in the cache that no card is working in, given back at once.
// Run at startup, because that is when nothing is running and when the pile
// left by every card ever finished is at its biggest — a window that has been
// used for a week otherwise carries a checkout per card it ever ran.
//
// It waits for git, one remove per tree, and the trees that are still in use
// cost a `stat` and nothing else. A machine with a hundred finished cards on
// it pays a second, once, on the launch after the version that made them.
worktree_sweep :: proc(t: ^Todos) {
	root := cache_path("worktrees")
	dir, err := os.open(root)
	if err != nil do return
	defer os.close(dir)
	entries, read_err := os.read_directory(dir, -1, context.temp_allocator)
	if read_err != nil do return
	for e in entries {
		if e.type != .Directory do continue
		id := worktree_card(e.fullpath)
		if id == "" || !worktree_idle(t, id) do continue
		// The tree knows its repository — `.git` in it is a line pointing at
		// the one that made it — so a card that is gone from the list, and
		// cannot say which project it belonged to, is still removable.
		repo := worktree_repo(e.fullpath)
		if repo == "" do continue
		if ok, _ := git(repo, {"worktree", "remove", e.fullpath}); !ok do continue
		_, _ = git(repo, {"branch", "-d", worktree_branch(id)})
	}
}

// The card a tree belongs to, read off its name — `<project>-n-<number>`, and
// the number is the card's. "" for anything that is not one of ours, which is
// the only thing that keeps a sweep of a directory in the cache from being a
// sweep of whatever else happens to be in there.
worktree_card :: proc(path: string) -> string {
	if !strings.has_prefix(path, cache_path("worktrees")) do return ""
	name := base_name(path)
	at := strings.last_index(name, "-n-")
	if at < 0 do return ""
	return name[at + 1:]
}

// The repository a tree was cut from. A worktree's `.git` is a file, not a
// directory, and it holds one line: `gitdir: <repo>/.git/worktrees/<name>`.
// Three directories up from that is the repository, and git will take
// anything inside it.
@(private = "file")
worktree_repo :: proc(path: string) -> string {
	marker, _ := filepath.join({path, ".git"}, context.temp_allocator)
	data, err := os.read_entire_file_from_path(marker, context.temp_allocator)
	if err != nil do return ""
	line := strings.trim_space(string(data))
	if !strings.has_prefix(line, "gitdir:") do return ""
	// Three directories up, by cutting the string rather than by three
	// filepath.dir calls: each of those allocates a copy that nothing here
	// would ever free.
	repo := strings.trim_space(strings.trim_prefix(line, "gitdir:"))
	for _ in 0 ..< 3 {
		cut := strings.last_index_byte(repo, '/')
		if cut <= 0 do return ""
		repo = repo[:cut]
	}
	if !os.exists(repo) do return ""
	return repo
}

@(private = "file")
worktree_has_branch :: proc(project, branch: string) -> bool {
	ok, _ := git(project, {"rev-parse", "--verify", "--quiet", fmt.tprintf("refs/heads/%s", branch)})
	return ok
}

worktree_branch :: proc(id: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"aithing/", id}, allocator)
}

// A worktree is where a card works; it is not a project. The grid groups by
// project and a new card lands in the project you are in, so both have to see
// through the tree to the thing it was cut from — otherwise reading a card's
// thread files the next card you write under a path in the cache.
//
// Read back off the card, not written down beside it: the tree is named after
// the card, and the card knows which project it came from.
worktree_project :: proc(app: ^App, cwd: string) -> string {
	if cwd == "" do return cwd
	id := worktree_card(cwd)
	if id == "" do return cwd
	item := todos_find(&app.todos, id)
	if item < 0 || app.todos.list[item].cwd == "" do return cwd
	return app.todos.list[item].cwd
}

// One git command, waited on, for its answer rather than its complaint:
// which branch, whether anything is modified. Same run, different half of it.
@(private = "file")
git_out :: proc(cwd: string, args: []string) -> (ok: bool, out: string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "git", "-C", cwd)
	append(&cmd, ..args)
	state, outs, _, err := os.process_exec(
		{command = cmd[:], working_dir = cwd},
		context.temp_allocator,
	)
	if err != nil do return false, ""
	if !state.exited || state.exit_code != 0 do return false, ""
	return true, string(outs)
}

// One git command, waited on. Its stderr is what comes back, because the one
// thing worth saying about a worktree that could not be made is git's own
// sentence about why — and for the merges, which say what conflicted on
// stdout, both halves, because a merge that stops with `CONFLICT (content)`
// and nothing on stderr used to land on a card as `failed` with no reason.
@(private = "file")
git :: proc(cwd: string, args: []string) -> (ok: bool, msg: string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "git", "-C", cwd)
	append(&cmd, ..args)
	state, outs, errs, err := os.process_exec(
		{command = cmd[:], working_dir = cwd},
		context.temp_allocator,
	)
	if err != nil do return false, fmt.tprintf("cannot run git: %v", err)
	if state.exited && state.exit_code == 0 do return true, ""
	said := strings.trim_space(string(errs))
	if said == "" do said = strings.trim_space(string(outs))
	return false, said
}
