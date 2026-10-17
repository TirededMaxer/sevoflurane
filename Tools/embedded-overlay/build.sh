#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]]
out="$RUNNER_TEMP/sevo-overlay"
mkdir -p "$out"
common=(-arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -framework AppKit -framework Metal -framework QuartzCore -framework IOSurface)
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -O2 -fblocks -dynamiclib Tools/embedded-overlay/OverlayLoader.c -install_name @rpath/SevoEmbeddedOverlay.dylib -o "$out/SevoEmbeddedOverlay.dylib"
xcrun clang "${common[@]}" -dynamiclib Tools/embedded-overlay/OverlayRenderer.m Tools/embedded-overlay/WindowSurface.m -install_name @rpath/SevoOverlayRenderer.dylib -o "$out/SevoOverlayRenderer.dylib"
xcrun clang "${common[@]}" Tools/embedded-overlay/check.m "$out/SevoOverlayRenderer.dylib" -Wl,-rpath,@executable_path -o "$out/sevo-overlay-check"
codesign --force --sign - --timestamp=none "$out/SevoEmbeddedOverlay.dylib"
codesign --force --sign - --timestamp=none "$out/SevoOverlayRenderer.dylib"
codesign --force --sign - --timestamp=none "$out/sevo-overlay-check"
status=0
"$out/sevo-overlay-check" "$RUNNER_TEMP/sevo-overlay-check.surface" > "$out/check.txt" 2>&1 || status=$?
cat "$out/check.txt"
[[ "$status" == 0 || "$status" == 77 ]]
# The injected loader itself must not pull the GUI/GPU frameworks into Steam.
! otool -L "$out/SevoEmbeddedOverlay.dylib" | grep -E 'AppKit|Metal|QuartzCore'

# A cross-architecture timestamp handshake catches Rosetta tick-scale drift.
python3 - "$out/sevo-overlay-check" <<'PY_CLOCK'
import subprocess, sys
arm = int(subprocess.check_output([sys.argv[1], "--clock"]))
intel = int(subprocess.check_output(["arch", "-x86_64", sys.argv[1], "--clock"]))
assert abs(intel - arm) < 5_000_000_000, (arm, intel)
print("PASS: arm64 and Rosetta share nanosecond timestamps")
PY_CLOCK

# This is a presentation/input-policy prototype, not game integration acceptance.
xcrun clang "${common[@]}" Tools/embedded-overlay/window-check.m Tools/embedded-overlay/WindowSurface.m -o "$out/sevo-window-check"
codesign --force --sign - --timestamp=none "$out/sevo-window-check"
"$out/sevo-window-check" | tee "$out/window-check.txt"
