package aithing

import "core:os"
import "core:testing"

// A folder that shares a repository's name is that repository's project: the
// launcher offers the name once, the grid shows one section for it, and a
// card filed under the folder runs in the repository.
@(test)
a_namesake_folder_is_the_repositorys_project :: proc(t: ^testing.T) {
	REPO :: "/tmp/aithing-test-home/Source/game"
	CLIPS :: "/tmp/aithing-test-home/Videos/game"
	OTHER :: "/tmp/aithing-test-home/Source/other"
	os.make_directory_all(REPO + "/.git")
	os.make_directory_all(CLIPS)
	os.make_directory_all(OTHER)
	defer os.remove_all("/tmp/aithing-test-home")

	app := new(App)
	defer free(app)
	defer todos_destroy(&app.todos)
	defer delete(app.todo_view)

	// The folder the clips are in holds more cards than the repository does,
	// which is not what makes a project home.
	todos_add(&app.todos, "cut a clip", "", CLIPS)
	todos_add(&app.todos, "cut another", "", CLIPS)
	todos_add(&app.todos, "a spider bot factory", "", REPO)
	todos_add(&app.todos, "elsewhere", "", OTHER)

	homes := project_homes(app)
	testing.expect_value(t, project_home(homes, CLIPS), REPO)
	testing.expect_value(t, project_home(homes, REPO), REPO)
	testing.expect_value(t, project_home(homes, OTHER), OTHER)

	// One section for the game, one for the other, and narrowing to the
	// folder of clips is narrowing to the game.
	app_build_cards(app)
	n, _ := app_view_projects(app)
	testing.expect_value(t, n, 2)

	app.canvas.project = CLIPS
	testing.expect_value(t, app_project(app), REPO)
	app.canvas.project = ""
}
