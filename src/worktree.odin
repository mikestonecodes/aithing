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
// Nothing here ever removes one. A worktree is where the work is, and
// uncommitted work in it is not this program's to throw away — so a dismissed
// card leaves its tree and its branch behind, and `git worktree list` is how
// you find them. That is on purpose; deleting them on dismiss was the one
// version of this that could lose an afternoon.
//
// One thing follows from a card working in a checkout of HEAD: uncommitted
// changes in the main tree are not in it — the agent sees the last commit,
// not what you have open in your editor.
//
// A card that finishes hands its branch back — see worktree_merge — so a
// turn that edits this window's own source does rebuild it, from the project
// and not from the tree the work was done in.
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
	if ok, _, _ := git(project, {"rev-parse", "--git-dir"}); !ok {
		return strings.clone(project, allocator), ""
	}
	path := worktree_path(project, id)
	if os.exists(path) do return strings.clone(path, allocator), ""

	os.make_directory_all(filepath.dir(path))
	// A tree someone deleted by hand is still registered, and the add fails
	// on the name until the stale record goes.
	_, _, _ = git(project, {"worktree", "prune"})
	// -B rather than -b: the branch outlives the tree, so a card whose tree
	// was removed and asked for again lands back on its own branch.
	if ok, _, msg := git(project, {"worktree", "add", "-B", worktree_branch(id), path, "HEAD"}); !ok {
		return strings.clone(project, allocator), strings.clone(one_line(msg, 160), allocator)
	}
	return strings.clone(path, allocator), ""
}

// Where the work goes when a card is finished. A branch nobody merges is a
// card that says `done` over work that is not in the project: it sat in the
// cache under a name only `git worktree list` knew, and the next card cut
// its own tree from a HEAD that had never seen it — so two cards asked to
// build on each other both started from before either.
//
// So a turn that ends Done hands its branch over. What the agent left
// uncommitted is committed first, because an agent asked to do a piece of
// work is not asked to commit it and most do not; then the branch is merged
// into whatever the project checkout has open, which is the branch its tree
// was cut from.
//
// Anything git will not do — a conflict, a detached HEAD, local changes the
// merge would tread on — comes back as git's own sentence, and nothing is
// forced and nothing is thrown away. The commit is still on the branch and
// the tree is still in the cache; the card says `needs you` with the reason,
// which is the only honest thing it can say while the work is not in the
// project.
//
// Waited on, on the frame the turn ends, the same as the checkout that
// started it: a merge of this repository is a few milliseconds. What comes
// back is temp-allocated and goes straight onto the card.
worktree_merge := worktree_merge_git

// Only the tests point that anywhere else; a test suite that merged for real
// would need a repository per card.
worktree_merge_git :: proc(project, cwd, id, text: string) -> (why: string) {
	if project == "" || id == "" || cwd == "" || cwd == project do return ""
	if !os.exists(cwd) do return ""

	if ok, out, _ := git(cwd, {"status", "--porcelain"}); ok && strings.trim_space(out) != "" {
		if ok, _, msg := git(cwd, {"add", "-A"}); !ok do return one_line(msg, 160)
		// The card's own wording, so a log of merges reads as the board did.
		subject := one_line(text, 120)
		if subject == "" do subject = fmt.tprintf("aithing %s", id)
		if ok, _, msg := git(cwd, {"commit", "-m", subject}); !ok do return one_line(msg, 160)
	}

	// A detached HEAD is refused rather than merged into: the merge would
	// land on a commit with no branch on it, which is work put somewhere
	// nobody will look again.
	ok, head, _ := git(project, {"symbolic-ref", "--short", "HEAD"})
	if !ok || strings.trim_space(head) == "" {
		return fmt.tprintf("no branch checked out in %s", base_name(project))
	}
	if ok, out, msg := git(project, {"merge", "--no-edit", worktree_branch(id)}); !ok {
		// A merge that stopped halfway leaves the project mid-conflict, which
		// is a state the person who opens it next did not ask for.
		_, _, _ = git(project, {"merge", "--abort"})
		// Which file it fell out over is on stdout; stderr only says that it
		// did. The card has room for one line, and the file is the useful one.
		lines := each_line(out)
		for line in iter_next(&lines) {
			if strings.has_prefix(line, "CONFLICT") do return one_line(line, 160)
		}
		return one_line(msg, 160)
	}
	return ""
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
	if !strings.has_prefix(cwd, cache_path("worktrees")) do return cwd
	name := base_name(cwd)
	at := strings.last_index(name, "-n-")
	if at < 0 do return cwd
	item := todos_find(&app.todos, name[at + 1:])
	if item < 0 || app.todos.list[item].cwd == "" do return cwd
	return app.todos.list[item].cwd
}

// One git command, waited on. Its stderr is what comes back as `msg`,
// because the one thing worth saying about a worktree that could not be made
// is git's own sentence about why.
@(private = "file")
git :: proc(cwd: string, args: []string) -> (ok: bool, out: string, msg: string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "git", "-C", cwd)
	append(&cmd, ..args)
	state, outs, errs, err := os.process_exec(
		{command = cmd[:], working_dir = cwd},
		context.temp_allocator,
	)
	if err != nil do return false, "", fmt.tprintf("cannot run git: %v", err)
	if state.exited && state.exit_code == 0 do return true, string(outs), ""
	// Some of git's refusals are on stdout, and a card that says `failed`
	// with nothing after it is one you cannot act on.
	said := strings.trim_space(string(errs))
	if said == "" do said = strings.trim_space(string(outs))
	return false, string(outs), said
}
