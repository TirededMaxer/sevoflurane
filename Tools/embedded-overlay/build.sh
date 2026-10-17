#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]]
out="$RUNNER_TEMP/sevo-overlay"
mkdir -p "$out"
common=(-arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -framework AppKit -framework Metal -framework QuartzCore)
xcrun clang "${common[@]}" -dynamiclib Tools/embedded-overlay/OverlayRenderer.m -install_name @rpath/SevoEmbeddedOverlay.dylib -o "$out/SevoEmbeddedOverlay.dylib"
xcrun clang "${common[@]}" Tools/embedded-overlay/check.m -L "$out" -l:SevoEmbeddedOverlay.dylib -Wl,-rpath,@executable_path -o "$out/sevo-overlay-check"
codesign --force --sign - --timestamp=none "$out/SevoEmbeddedOverlay.dylib"
codesign --force --sign - --timestamp=none "$out/sevo-overlay-check"
status=0
"$out/sevo-overlay-check" "$RUNNER_TEMP/sevo-overlay-check.surface" > "$out/check.txt" 2>&1 || status=$?
cat "$out/check.txt"
[[ "$status" == 0 || "$status" == 77 ]]
