#!/bin/sh
# Bakes the three UI fonts into one multi-channel signed distance field atlas.
#
# The old atlas was a bitmap baked by stb_truetype at one size, which is why
# text was only ever crisp at that size and why anything scaled off it — a
# heading, a 13px timestamp — arrived soft or gritty. An MSDF stores the
# distance to the glyph outline rather than its coverage, so the fragment
# shader reconstructs a sharp edge at any size from the same sheet.
#
# One sheet holds all three fonts: msdf-atlas-gen's `-and` packs them together
# and the metrics come back as one variant per font, in the order given here.
#
# Needs msdf-atlas-gen. Both outputs are committed, so a plain build does not.
set -e
cd "$(dirname "$0")/.."

OUT_PNG=src/font/atlas.png
OUT_BIN=src/font/atlas.bin
OUT_JSON=$(mktemp --suffix=.json)
CHARSET=$(mktemp)
trap 'rm -f "$CHARSET" "$OUT_JSON"' EXIT

REGULAR=/usr/share/fonts/noto/NotoSans-Regular.ttf
BOLD=/usr/share/fonts/noto/NotoSans-Bold.ttf
MONO=/usr/share/fonts/noto/NotoSansMono-Regular.ttf

if ! command -v msdf-atlas-gen >/dev/null; then
	echo "msdf-atlas-gen not installed; keeping the committed atlas" >&2
	exit 0
fi

# Latin only, on purpose: this draws Claude Code transcripts, and a sheet that
# also carried CJK would be a hundred times the glyphs for text that never
# appears. What is here is ASCII, the Latin-1 supplement, and the punctuation
# an answer actually contains — curly quotes, dashes, bullets, arrows, ticks
# and the box-drawing characters that `tree` and friends print. Anything the
# fonts do not have is dropped here and folded onto ASCII at runtime.
python3 - "$CHARSET" <<'CHARS'
import sys
cps = set()
cps |= set(range(0x20, 0x7F))     # ASCII
cps |= set(range(0xA0, 0x100))    # Latin-1 supplement: accents, degrees, +-
cps |= set(range(0x2010, 0x2016)) # hyphens and dashes
cps |= set(range(0x2018, 0x201F)) # curly quotes
cps |= {0x2007, 0x2009, 0x202F}   # figure, thin and narrow no-break spaces
cps |= {0x2020, 0x2021, 0x2022, 0x2026, 0x2030, 0x2039, 0x203A, 0x2043}
cps |= {0x20AC, 0x2122, 0x2190, 0x2191, 0x2192, 0x2193, 0x21B5}
cps |= {0x2212, 0x2248, 0x2260, 0x2261, 0x2264, 0x2265}
cps |= {0x2713, 0x2714, 0x2717, 0x2718, 0x25AA, 0x25CF, 0x25CB, 0x25B6, 0x25C0}
cps |= {0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524,
        0x252C, 0x2534, 0x253C, 0x2550, 0x2551, 0x2588, 0x2591, 0x2592, 0x2593}
with open(sys.argv[1], "w") as f:
    for cp in sorted(cps):
        f.write("0x%04X\n" % cp)
print("  %d code points x 3 fonts" % len(cps))
CHARS

# -size is the em size the distances are computed at, not a limit on how big
# text can be drawn; -pxrange is how many pixels the distance ramp spans, and
# the shader is told the same number through the packed header.
msdf-atlas-gen \
	-font "$REGULAR" -charset "$CHARSET" \
	-and -font "$BOLD" -charset "$CHARSET" \
	-and -font "$MONO" -charset "$CHARSET" \
	-type msdf -format png -size 48 -pxrange 4 -potr \
	-json "$OUT_JSON" -imageout "$OUT_PNG" 2>&1 | grep -v '^Missing' || true

# The JSON is repacked into a flat record the program reads without a parser:
# the layout here is mirrored by Atlas_Header, Font_Header and Glyph in
# src/font.odin, and nothing at runtime does more than point at it.
python3 - "$OUT_JSON" "$OUT_BIN" <<'PACK'
import json, struct, sys
d = json.load(open(sys.argv[1]))
a = d["atlas"]
variants = d["variants"] if "variants" in d else [d]

out = bytearray()
out += struct.pack("<3I2fI", 0x31534446, a["width"], a["height"],
                   a["distanceRange"], a["size"], len(variants))
for v in variants:
    m = v["metrics"]
    glyphs = sorted(v["glyphs"], key=lambda g: g["unicode"])
    out += struct.pack("<3fI", m["ascender"], m["descender"], m["lineHeight"],
                       len(glyphs))
    for g in glyphs:
        pb = g.get("planeBounds") or {"left": 0, "bottom": 0, "right": 0, "top": 0}
        ab = g.get("atlasBounds") or {"left": 0, "bottom": 0, "right": 0, "top": 0}
        out += struct.pack("<I9f", g["unicode"], g["advance"],
                           pb["left"], pb["bottom"], pb["right"], pb["top"],
                           ab["left"], ab["bottom"], ab["right"], ab["top"])
open(sys.argv[2], "wb").write(out)
print("  atlas %dx%d, range %s, glyphs per font %s, %d bytes of metrics" %
      (a["width"], a["height"], a["distanceRange"],
       [len(v["glyphs"]) for v in variants], len(out)))
PACK
echo "wrote $OUT_PNG $OUT_BIN"
