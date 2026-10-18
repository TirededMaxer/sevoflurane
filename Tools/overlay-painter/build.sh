#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
repo="$GITHUB_WORKSPACE"
work="$RUNNER_TEMP/sevo-build/overlay-painter"
out="$RUNNER_TEMP/sevo-output"
mkdir -p "$work" "$out"
cd "$repo/Tools/overlay-painter"
# Fresh compiler on the ephemeral runner; no local or cached build inputs.
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then brew install mingw-w64 > "$out/painter-toolchain.log" 2>&1; fi
python3 -B -m unittest discover -s . -p test_probe_session.py -v 2>&1 | tee "$out/painter-session-tests.log"
clang -std=c11 -Wall -Wextra -Werror paint_frame.c paint_frame_test.c -o "$work/frame-test"
clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter webkit_frame.m -framework AppKit -framework WebKit -o "$work/sevo-painter-frame"
codesign --force --sign - "$work/sevo-painter-frame"
"$work/sevo-painter-frame" "$work/test.bgra" 640 400
"$work/frame-test" "$work/test.bgra" | tee "$out/painter-tests.log"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -shared -static-libgcc -Wl,--exclude-all-symbols \
    painter_probe.c proxy_thunks.S paint_frame.c -o "$work/sevo-painter.dll"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -municode -static-libgcc \
    attach.c -o "$work/sevo-painter-attach.exe"
python3 verify_build.py "$work" "$out"
cp painter_probe.py README.md cef-abi-evidence.json "$work/"
