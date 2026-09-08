package aithing

import "core:os"
import "core:strings"

// Threads filed away by hand. Dismissing the last card of a thread files it,
// which is what keeps the x pressed: nothing is going to offer that thread a
// card again.
//
// It used to be more than that — a set of rules about how far back the grid
// reached, how long finished work stayed on it and how many threads a project
// was allowed — and all of them ran against the clock, so the grid rearranged
// itself while nobody was touching it. What decides now is dismissal, and
// nothing else does.

Archive :: struct {
	// id -> archived. Only sessions filed by hand are in here; everything else
	// takes the default.
	filed: map[string]bool,
	dirty: bool,
}

// One line per filed session: `+<id>` is archived, `-<id>` is kept active.
archive_load :: proc(a: ^Archive) {
	data, err := os.read_entire_file_from_path(config_path("archived"), context.temp_allocator)
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
	_ = os.write_entire_file(config_path("archived"), transmute([]byte)strings.to_string(b))
}

archive_is :: proc(a: ^Archive, id: string) -> bool {
	if filed, has := a.filed[id]; has do return filed
	return false
}

archive_set :: proc(a: ^Archive, id: string, archived: bool) {
	if _, has := a.filed[id]; !has {
		a.filed[strings.clone(id)] = archived
	} else {
		a.filed[id] = archived
	}
	a.dirty = true
}

// The model choice lives beside the archive: one word, so that picking a model
// is remembered the way the sidebar is.
model_load :: proc() -> Model {
	data, err := os.read_entire_file_from_path(config_path("model"), context.temp_allocator)
	if err != nil do return MODEL_DEFAULT
	m, _ := model_parse(strings.trim_space(string(data)))
	return m
}

model_save :: proc(m: Model) {
	_ = os.write_entire_file(config_path("model"), transmute([]byte)model_short[m])
}

// And the effort beside the model, for the same reason and in the same shape.
effort_load :: proc() -> Effort {
	data, err := os.read_entire_file_from_path(config_path("effort"), context.temp_allocator)
	if err != nil do return EFFORT_DEFAULT
	e, _ := effort_parse(strings.trim_space(string(data)))
	return e
}

effort_save :: proc(e: Effort) {
	_ = os.write_entire_file(config_path("effort"), transmute([]byte)effort_flag[e])
}

archive_destroy :: proc(a: ^Archive) {
	for id in a.filed do delete(id)
	delete(a.filed)
}
