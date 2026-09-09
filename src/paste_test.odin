package aithing

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import stbi "vendor:stb/image"

// A picture pasted into the box under the grid is a path in the text, and the
// picture drawn where that path is written is read back out of the text every
// frame. This is the whole reason there is no attachment list beside the box:
// what the card carries and what the box shows are one answer, so deleting the
// path deletes the picture, and no amount of splitting, requeueing or
// backspacing can leave a picture of something the prompt no longer names.

@(private = "file")
a_png :: proc(t: ^testing.T, name: string) -> string {
	dir := "/tmp/aithing-test-paste"
	os.make_directory_all(dir)
	path := fmt.aprintf("%s/%s", dir, name)
	pixels := [4 * 2 * 4]u8{}
	for i in 0 ..< len(pixels) do pixels[i] = 0xff
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if stbi.write_png(cpath, 4, 2, 4, raw_data(pixels[:]), 4 * 4) == 0 {
		testing.fail_now(t, "could not write the test png")
	}
	return path
}

@(test)
the_box_shows_the_pictures_its_text_names :: proc(t: ^testing.T) {
	png := a_png(t, "one.png")
	defer delete(png)

	app := new(App)
	defer {
		editor_destroy(&app.capture)
		app_previews_destroy(app)
		free(app)
	}

	editor_set_text(&app.capture, fmt.tprintf("look at this %s and fix it", png))
	imgs := capture_images(app)
	testing.expect_value(t, len(imgs), 1)
	testing.expect_value(t, imgs[0].width, 4)
	testing.expect_value(t, imgs[0].height, 2)

	// The same path twice is the same picture twice, and it is only ever read
	// off disk once: the second one comes back out of the decode already done.
	editor_set_text(&app.capture, fmt.tprintf("%s %s", png, png))
	testing.expect_value(t, len(capture_images(app)), 2)
	testing.expect_value(t, len(app.previews), 1)

	// And it goes when the words naming it go. There is nowhere else it could
	// be being kept, which is the point.
	editor_set_text(&app.capture, "look at this and fix it")
	testing.expect_value(t, len(capture_images(app)), 0)
}

// What counts as a path worth opening. Prose is not, and a relative word that
// happens to end in .png is prose: a paste always writes an absolute path.
@(test)
only_a_written_out_path_is_a_picture :: proc(t: ^testing.T) {
	testing.expect(t, path_is_image("/tmp/a/paste-1.png"))
	testing.expect(t, path_is_image("/tmp/a/PASTE-1.JPEG"))
	testing.expect(t, path_is_image("/tmp/a/shot.webp"))
	testing.expect(t, !path_is_image("/tmp/a/notes.md"))
	testing.expect(t, !path_is_image("/tmp/a/paste"))

	app := new(App)
	defer {
		editor_destroy(&app.capture)
		app_previews_destroy(app)
		free(app)
	}
	// A word that reads like a picture and is not a path, and a path that
	// reads like a picture and is not on disk: neither draws anything, and
	// neither is looked for twice.
	editor_set_text(&app.capture, "screenshot.png /tmp/aithing-test-paste/missing.png")
	testing.expect_value(t, len(capture_images(app)), 0)
	testing.expect_value(t, len(app.previews), 1)
	testing.expect_value(t, len(capture_images(app)), 0)
}

// The path goes out and is never read. It is what the harness opens and what
// says which card carries which picture, so it stays in the text — and every
// place a person's own words are printed back at them goes through this.
@(test)
the_words_come_back_without_the_paths :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		text_without_images("the ring is too pale here /tmp/a/paste-1.png"),
		"the ring is too pale here",
	)
	testing.expect_value(
		t,
		text_without_images("/tmp/a/paste-1.png make this darker /tmp/a/paste-2.jpg"),
		"make this darker",
	)
	// A word that only looks like one is prose and stays: a paste always
	// writes an absolute path.
	testing.expect_value(t, text_without_images("open screenshot.png"), "open screenshot.png")
}

// A picture steps and deletes as the one thing it looks like. It used to be
// eighty characters of cache path on screen; now it is a picture the width of
// a letter, and a caret that walked it letter by letter would sit still under
// forty presses and take forty backspaces to remove.
@(test)
a_pasted_picture_deletes_in_one_press :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	editor_set_text(&e, "look /tmp/a/paste-1.png")
	editor_key(&e, Key{code = KEY_BACKSPACE}, 0)
	testing.expect_value(t, editor_text(&e), "look ")

	editor_set_text(&e, "look /tmp/a/paste-1.png here")
	e.cursor, e.anchor = 5, 5
	testing.expect_value(t, next_rune(editor_text(&e), e.cursor), 23)
	testing.expect_value(t, prev_rune(editor_text(&e), 23), 5)
}

// What the transcript shows of a turn that named a picture: the words, and the
// picture itself as a stone of its own. The same for the message just typed
// and the one read back off a session file a year later, because both come
// through msg_write_user.
@(test)
a_turn_that_named_a_picture_shows_the_picture :: proc(t: ^testing.T) {
	chat: Chat
	defer chat_destroy(&chat)
	m := chat_append(&chat, .User)
	msg_write_user(&chat, m, "look at this /tmp/a/paste-1.png and fix it")

	blocks := chat.msgs[m].blocks[:]
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Text)
	testing.expect_value(t, block_text(&blocks[0]), "look at this and fix it")
	testing.expect_value(t, blocks[1].kind, Block_Kind.Image)
	testing.expect_value(t, blocks[1].image, "/tmp/a/paste-1.png")
}
