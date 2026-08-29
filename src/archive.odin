package aithing

import "core:os"
import "core:path/filepath"
import "core:strings"

// The sidebar is a working list, not a log: what you are on stays at the top,
// everything else is archived and out of the way. Sessions that have never
// been filed either way fall back to "the newest few are what I'm working on",
// which is right on a fresh install and stops mattering as soon as anything is
// filed by hand.

ACTIVE_BY_DEFAULT :: 10

Archive :: struct {
	// id -> archived. Only sessions filed by hand are in here; everything else
	// takes the default.
	filed: map[string]bool,
	dirty: bool,
}

archive_path :: proc(allocator := context.temp_allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	dir, _ := filepath.join({home, ".config", "aithing"}, context.temp_allocator)
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, "archived"}, allocator)
	return path
}

// One line per filed session: `+<id>` is archived, `-<id>` is kept active.
archive_load :: proc(a: ^Archive) {
	data, err := os.read_entire_file_from_path(archive_path(), context.temp_allocator)
	if err != nil do return
	it := each_line(string(data))
	for line in iter_next(&it) {
		row := strings.trim_space(line)
		if len(row) < 2 do continue
		id := strings.clone(row[1:])
		a.filed[id] = row[0] == '+'
	}
}

archive_save :: proc(a: ^Archive) {
	if !a.dirty do return
	a.dirty = false
	b := strings.builder_make(context.temp_allocator)
	for id, archived in a.filed {
		strings.write_byte(&b, archived ? '+' : '-')
		strings.write_string(&b, id)
		strings.write_byte(&b, '\n')
	}
	_ = os.write_entire_file(archive_path(), transmute([]byte)strings.to_string(b))
}

archive_is :: proc(a: ^Archive, id: string, index: int) -> bool {
	if filed, has := a.filed[id]; has do return filed
	return index >= ACTIVE_BY_DEFAULT
}

archive_set :: proc(a: ^Archive, id: string, archived: bool) {
	if _, has := a.filed[id]; !has {
		a.filed[strings.clone(id)] = archived
	} else {
		a.filed[id] = archived
	}
	a.dirty = true
}

archive_destroy :: proc(a: ^Archive) {
	for id in a.filed do delete(id)
	delete(a.filed)
}
