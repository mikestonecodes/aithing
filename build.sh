#!/bin/sh
# Builds aithing. The generated Wayland bindings and the compiled SPIR-V are
# both committed, so a plain `odin build src -out:aithing` works on its own;
# this script only regenerates them when the tools are around.
set -e
cd "$(dirname "$0")"

WL_XML=/usr/share/wayland/wayland.xml
XDG_XML=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DEC_XML=/usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml
BLUR_XML=/usr/share/wayland-protocols/staging/ext-background-effect/ext-background-effect-v1.xml

if [ -f "$WL_XML" ] && command -v python3 >/dev/null; then
	python3 tools/wl_gen.py src/wayland/protocol.odin "$WL_XML" "$XDG_XML" "$DEC_XML" "$BLUR_XML"
fi

# The font atlas is regenerated only when msdf-atlas-gen is around; the script
# bows out quietly otherwise, and the committed sheet is used as it is.
./tools/gen_font_atlas.sh >/dev/null

if command -v glslc >/dev/null; then
	glslc -O -fshader-stage=vert src/shaders/ui.vert -o src/shaders/ui.vert.spv
	glslc -O -fshader-stage=frag src/shaders/ui.frag -o src/shaders/ui.frag.spv
fi

# --export-dynamic puts the symbol names in the dynamic table, which is where
# the crash reporter's backtrace reads them from. Without it a crash log is a
# column of hex.
odin build src -out:aithing -extra-linker-flags:"-Wl,--export-dynamic" ${BUILD_FLAGS:-}
echo "built ./aithing"
