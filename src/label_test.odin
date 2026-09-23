package aithing

import "core:strings"
import "core:testing"

// Two directories with the same last component are two projects, and the
// names over them have to say so, or the grid shows one project twice.
@(test)
namesakes_are_told_apart_by_their_parent :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer todos_destroy(&app.todos)

	todos_add(&app.todos, "a card", "", "/home/mike/Source/toomanymachines")
	todos_add(&app.todos, "another", "", "/home/mike/Source/aithing")
	testing.expect_value(t, project_label(app, "/home/mike/Source/toomanymachines"), "toomanymachines")

	todos_add(&app.todos, "a cut", "", "/home/mike/Videos/toomanymachines")
	testing.expect_value(t, project_label(app, "/home/mike/Source/toomanymachines"), "Source/toomanymachines")
	testing.expect_value(t, project_label(app, "/home/mike/Videos/toomanymachines"), "Videos/toomanymachines")
	testing.expect_value(t, project_label(app, "/home/mike/Source/aithing"), "aithing")
	testing.expect(t, !strings.contains(project_label(app, "/home/mike/Source/aithing"), "/"))
}
