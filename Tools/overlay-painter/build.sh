#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
repo="$GITHUB_WORKSPACE"
work="$RUNNER_TEMP/sevo-build/overlay-painter"
out="$RUNNER_TEMP/sevo-output"
mkdir -p "$work" "$out"
cd "$repo/Tools/overlay-painter"
# A fresh cross compiler on the ephemeral runner, never a local/cache build input.
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then brew install mingw-w64 > "$out/painter-toolchain.log" 2>&1; fi
python3 -B -m unittest discover -s . -p test_installer.py -v 2>&1 | tee "$out/painter-installer-tests.log"
clang -std=c11 -Wall -Wextra -Werror paint_frame.c paint_frame_test.c -o "$work/frame-test"
clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter webkit_frame.m -framework AppKit -framework WebKit -o "$work/sevo-painter-frame"
codesign --force --sign - "$work/sevo-painter-frame"
"$work/sevo-painter-frame" "$work/test.bgra" 640 400
"$work/frame-test" "$work/test.bgra" | tee "$out/painter-tests.log"
python3 - "$work" <<'PY'
from pathlib import Path
import json,sys
work=Path(sys.argv[1]);exports=json.loads(Path('cef-exports.json').read_text())['exports']
hooks={'cef_browser_host_create_browser':'sevo_create_browser_thunk','cef_browser_host_create_browser_sync':'sevo_create_browser_sync_thunk'}
lines=['LIBRARY libcef','EXPORTS']
for e in exports:
 target=hooks.get(e['name'],'sevo_libcef_original.'+e['name'])
 lines.append(f"  {e['name']}={target} @{e['ordinal']}")
(work/'libcef.def').write_text('\n'.join(lines)+'\n')
PY
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -shared -static-libgcc \
    proxy.c proxy_thunks.S paint_frame.c "$work/libcef.def" -o "$work/libcef.dll"
python3 verify_build.py "$work" "$out"
cp install_probe.py README.md cef-exports.json cef-abi-evidence.json "$work/"
