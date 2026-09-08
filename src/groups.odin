package aithing

import "core:math"
import "core:os"
import "core:strings"

// One task, several threads. A context that filled up, a window closed and
// reopened, a second run at the same thing the next morning: the work is one
// task and the map should show one card for it, not five.
//
// Nothing on disk says which threads belong together — a resumed session is
// not linked back to the one it came from, and every thread claims the same
// git branch — so the grouping is read off what the threads are called. Rare
// words weigh more than common ones, and a thread joins the group it is most
// like within its own project, or founds one.
//
// The group is one word: the most recurring word in the title that is not so
// common it describes the whole project. `laser`, `audio`, `steam`, `gimp` —
// the general task, which is the level worth a card. Everything else about a
// thread is on the thread.
//
// The answer is written to a file, so the first pass over a few hundred
// threads is the only one that does the whole job: after that a new thread is
// the only thing without an answer, and it joins a group already there.

// A topic word has to turn up in at least two threads to be a topic at all,
// and in no more than this share of a project's threads — a word in half the
// titles is what the project is called, not what a task is. Turning the share
// up makes for fewer, broader groups.
GROUP_MIN :: 2
GROUP_SHARE :: 15 // percent

// Words that say nothing about which task a thread is: the language itself,
// and the handful of verbs every thread title starts with.
@(private = "file")
STOP :: [?]string {
	"the", "and", "for", "with", "into", "from", "when", "after", "before",
	"all", "more", "less", "other", "same", "only", "its", "also", "not",
	"add", "fix", "fixes", "update", "remove", "new", "use", "using", "make",
	"made", "get", "got", "can", "should", "would", "have", "has", "had",
	"this", "that", "then", "just", "improve", "better", "some", "any",
	"bug", "bugs", "issue", "issues", "broken", "debug", "why", "how", "what",
	"check", "review", "updates", "updated", "change", "changes", "missing",
	"local", "fixed", "file", "files", "code", "small", "thing", "stuff",
	"show", "make", "work", "working",
}

// The file is rewritten from scratch when this changes, because a key written
// by an older rule means nothing to a newer one.
@(private = "file")
GROUPS_VERSION :: "3"

Groups :: struct {
	of:    map[string]string, // session id -> `<topic>|<project>`, or its own id when it is alone
	dirty: bool,
}

// A version line, then one line per thread: `<id> <group>`.
groups_load :: proc(g: ^Groups) {
	data, err := os.read_entire_file_from_path(config_path("groups"), context.temp_allocator)
	if err != nil do return
	it := each_line(string(data))
	first, _ := iter_next(&it)
	if strings.trim_space(first) != GROUPS_VERSION do return // worked out under an older rule
	for line in iter_next(&it) {
		row := strings.trim_space(line)
		if row == "" do continue
		id, _, key := strings.partition(row, " ")
		key = strings.trim_space(key)
		if id == "" || key == "" do continue
		g.of[strings.clone(id)] = strings.clone(key)
	}
}

groups_save :: proc(g: ^Groups) {
	if !g.dirty do return
	g.dirty = false
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, GROUPS_VERSION)
	strings.write_byte(&b, '\n')
	for id, key in g.of {
		strings.write_string(&b, id)
		strings.write_byte(&b, ' ')
		strings.write_string(&b, key)
		strings.write_byte(&b, '\n')
	}
	_ = os.write_entire_file(config_path("groups"), transmute([]byte)strings.to_string(b))
}

groups_destroy :: proc(g: ^Groups) {
	for id, key in g.of {
		delete(id)
		delete(key)
	}
	delete(g.of)
}

// The group a thread is in, which is a thread id: its own, if it founded one.
group_of :: proc(g: ^Groups, s: Session) -> string {
	if key, has := g.of[s.id]; has do return key
	return s.id
}

@(private = "file")
set :: proc(g: ^Groups, id, key: string) {
	if old, has := g.of[id]; has {
		delete(old)
		g.of[id] = strings.clone(key)
	} else {
		g.of[strings.clone(id)] = strings.clone(key)
	}
	g.dirty = true
}

// The words of a title worth matching on, lowercased, in order and without
// repeats. Everything is on the temp allocator: it lives for the pass. Shared
// with the manager, which reads a draft the same way.
title_words :: proc(title: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	low := strings.to_lower(title, context.temp_allocator)
	rest := low
	for rest != "" {
		i := 0
		for i < len(rest) && !is_word_byte(rest[i]) do i += 1
		rest = rest[i:]
		j := 0
		for j < len(rest) && is_word_byte(rest[j]) do j += 1
		if j == 0 do break
		w := rest[:j]
		rest = rest[j:]
		if len(w) <= 2 do continue
		// `tiers` and `tier` are the same task. Only a plain plural, and only
		// where dropping the s leaves a word: `status` and `css` keep theirs.
		if len(w) > 4 && w[len(w) - 1] == 's' {
			end := w[len(w) - 2:]
			if end != "ss" && end != "us" && end != "is" && end != "as" do w = w[:len(w) - 1]
		}
		skip := false
		for s in STOP do if w == s {
			skip = true
			break
		}
		if skip do continue
		for seen in out do if seen == w {
			skip = true
			break
		}
		if !skip do append(&out, w)
	}
	return out[:]
}

@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.'
}

// Puts every thread that has no group into one. Threads already placed keep
// theirs and are what a new thread looks at first, so the first run does the
// whole list and every run after it does only what has arrived since.
groups_assign :: proc(g: ^Groups, sessions: []Session) {
	// The common case, ten seconds after the last scan: nothing new arrived
	// and there is nothing to work out.
	fresh := false
	for s in sessions {
		if _, has := g.of[s.id]; !has {
			fresh = true
			break
		}
	}
	if !fresh do return

	words := make([][]string, len(sessions), context.temp_allocator)
	for s, i in sessions do words[i] = title_words(s.title)

	// How often a word turns up, counted inside its own project: `laser` says
	// what a task is in one repo and nothing at all in another. Counted over
	// every project too, which is what tells a word about the work from a
	// word about work — `change`, `missing`, `first` turn up everywhere.
	df := make(map[string]map[string]int, context.temp_allocator)
	total := make(map[string]int, context.temp_allocator)
	all := make(map[string]int, context.temp_allocator)
	for s, i in sessions {
		total[s.cwd] += 1
		if s.cwd not_in df do df[s.cwd] = make(map[string]int, context.temp_allocator)
		per := &df[s.cwd]
		for w in words[i] {
			per[w] += 1
			all[w] += 1
		}
	}
	n := f32(len(sessions))

	// The groups there already are, by project, with how many threads are in
	// each: a new thread joins the biggest group it has a word in common with,
	// which is what keeps a general task general.
	size := make(map[string]int, context.temp_allocator)
	for s in sessions {
		if key, has := g.of[s.id]; has do size[key] += 1
	}

	for s, i in sessions {
		if _, has := g.of[s.id]; has do continue
		per := df[s.cwd]
		cap := max(GROUP_MIN, total[s.cwd] * GROUP_SHARE / 100)

		// A group already in this project, named after a word in the title.
		key, at := "", 0
		for w in words[i] {
			k := group_key(w, s.cwd)
			if n, has := size[k]; has && n > at do key, at = k, n
		}
		// Otherwise the word that names the task best: said by the most
		// threads in this project, and by the fewest everywhere else.
		if key == "" {
			best, score := "", f32(0)
			for w in words[i] {
				c := per[w]
				if c < GROUP_MIN || c > cap do continue
				if sc := f32(c) * math.ln(n / f32(all[w])); sc > score do best, score = w, sc
			}
			if best != "" do key = group_key(best, s.cwd)
		}
		// A thread whose title has nothing in common with anything is a task
		// on its own, which most threads are.
		if key == "" do key = s.id

		set(g, s.id, key)
		size[strings.clone(key, context.temp_allocator)] += 1
	}
}

// A topic is only a topic inside its project, so the project is part of the
// name. The space is what the file splits on, so the key must not hold one.
@(private = "file")
group_key :: proc(word, cwd: string) -> string {
	return strings.concatenate({word, "|", cwd}, context.temp_allocator)
}
