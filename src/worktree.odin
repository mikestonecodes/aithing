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
// A tree goes back when the work in it is over: a card that is finished, or a
// card that is no longer on the grid at all. Nothing here decides what is
// worth keeping, because this program is a bad judge of that — git is asked
// instead. `worktree remove` without --force refuses a tree with anything
// modified or untracked in it, and `branch -d` refuses a branch whose commits
// are not already in HEAD, so a card that committed its work loses the tree
// and keeps the branch, and a card with an afternoon of uncommitted editing in
// it keeps both. Removal used to be forbidden outright for exactly that fear,
// and the cost of the fear was a cache full of checkouts of every card anyone
// had ever run.
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
	return at < 0 || t.list[at].state == .Done
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

// One git command, waited on. Its stderr is what comes back, because the one
// thing worth saying about a worktree that could not be made is git's own
// sentence about why.
@(private = "file")
git :: proc(cwd: string, args: []string) -> (ok: bool, msg: string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "git", "-C", cwd)
	append(&cmd, ..args)
	state, _, errs, err := os.process_exec(
		{command = cmd[:], working_dir = cwd},
		context.temp_allocator,
	)
	if err != nil do return false, fmt.tprintf("cannot run git: %v", err)
	if state.exited && state.exit_code == 0 do return true, ""
	return false, strings.trim_space(string(errs))
}
