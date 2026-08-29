#!/bin/sh
# Runs aithing under gdb and writes a backtrace to ~/.cache/aithing/crash.log if
# it goes down. Build with symbols first:  BUILD_FLAGS=-debug ./build.sh
set -e
cd "$(dirname "$0")"
mkdir -p "$HOME/.cache/aithing"
AITHING_KEYS=1 gdb -q -batch \
	-ex run \
	-ex "echo \n--- crashed ---\n" \
	-ex "thread apply all bt 24" \
	--args ./aithing "$@" 2>&1 | tee "$HOME/.cache/aithing/crash.log"
