package aithing

import "core:strings"
import "core:testing"

@(private = "file")
link_in :: proc(s: string) -> string {
	start, end, ok := link_next(s, 0)
	return ok ? s[start:end] : ""
}

// The sentence around an address is not part of it. An agent writes links in
// brackets, at the end of sentences and as markdown, and a link that opened
// `https://example.com/a).` is a page that does not exist.
@(test)
an_address_ends_where_the_sentence_takes_over :: proc(t: ^testing.T) {
	testing.expect_value(t, link_in("see https://example.com/a."), "https://example.com/a")
	testing.expect_value(t, link_in("(see https://example.com/a)."), "https://example.com/a")
	testing.expect_value(t, link_in("[the docs](https://example.com/a)"), "https://example.com/a")
	testing.expect_value(t, link_in("**https://example.com/a**"), "https://example.com/a")
	testing.expect_value(t, link_in("<http://example.com/a>"), "http://example.com/a")
	testing.expect_value(t, link_in("https://en.wikipedia.org/wiki/Odin_(god)"), "https://en.wikipedia.org/wiki/Odin_(god)")
	testing.expect_value(t, link_in("https://example.com/?q=a,b&c=d"), "https://example.com/?q=a,b&c=d")
	testing.expect_value(t, link_in("the https:// scheme"), "")
	testing.expect_value(t, link_in("xhttps://example.com"), "")
	testing.expect_value(t, link_in("nothing to see"), "")
}

// A URL longer than the bubble is broken wherever the width runs out, and a
// line that holds the second half of one holds no `https://` to be found. The
// line looks for links in the paragraph it was cut from, so pointing at any
// piece of the address is pointing at all of it.
@(test)
every_piece_of_a_broken_address_is_the_whole_address :: proc(t: ^testing.T) {
	g_atlas = Atlas{width = 1, height = 1, distance_range = 4, em_px = 48}

	ui: UI
	defer ui_destroy(&ui)
	for f in ([]^Font{&ui.regular, &ui.bold, &ui.mono}) {
		for i in 0 ..< DENSE_COUNT {
			f.dense[i] = Glyph {
				code    = u32(DENSE_FIRST) + u32(i),
				advance = 0.5,
				plane   = {0, 0, 0.5, 0.7},
				atlas   = {0, 0, 1, 1},
			}
		}
		f.ascent, f.descent, f.baseline = 1, -0.25, 0.8
	}

	URL :: "https://github.com/odin-lang/Odin/blob/master/core/strings/strings.odin#L100"
	b: Block
	defer strings.builder_destroy(&b.text)
	strings.write_string(&b.text, "it is in " + URL + " somewhere")

	WIDTH :: f32(300)
	md_layout(&ui, &b, WIDTH)

	pieces := 0
	input := Input{has_mouse = true, mouse = {3, 10}}
	for l in b.lines {
		if !strings.contains(URL, l.text) do continue
		pieces += 1
		ui_begin(&ui, 800, 600, &input, 1.0 / 60)
		md_draw_line(&ui, l, 0, 0, WIDTH, TEXT, FAINT)
		testing.expectf(t, ui_hovered_text(&ui) == URL, "%q points at %q", l.text, ui_hovered_text(&ui))
		ui_end(&ui)
	}
	testing.expectf(t, pieces >= 2, "the address was not broken: %d pieces", pieces)
}
