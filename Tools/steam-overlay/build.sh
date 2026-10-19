#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
work="$RUNNER_TEMP/steam-overlay"
out="$RUNNER_TEMP/sevo-output"
mkdir -p "$work" "$out"
cd "$GITHUB_WORKSPACE/Tools/steam-overlay"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
  brew install mingw-w64 > "$out/overlay-toolchain.log" 2>&1
fi
clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -pthread transport_test.c -o "$work/transport-test"
"$work/transport-test" | tee "$out/overlay-transport-tests.log"
clang -arch x86_64 -std=c11 -O2 -Wall -Wextra -Werror -pthread transport_test.c -o "$work/transport-x64-test"
/usr/bin/arch -x86_64 "$work/transport-x64-test" | tee -a "$out/overlay-transport-tests.log"
clang -arch x86_64 -std=c11 -O2 -Wall -Wextra -Werror -pthread paint_test.c -o "$work/paint-test"
/usr/bin/arch -x86_64 "$work/paint-test" | tee "$out/overlay-paint-tests.log"
node --check "$GITHUB_WORKSPACE/Sevoflurane/Web/native_overlay_input.js"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -shared -static-libgcc \
  -Wl,--exclude-all-symbols paint.c -lbcrypt -o "$work/sevo-overlay-webkit.dll"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -municode -static-libgcc \
  attach.c -o "$work/sevo-overlay-attach.exe"
python3 - "$work" "$GITHUB_SHA" <<'PY'
import hashlib,json,struct,sys
from pathlib import Path
root=Path(sys.argv[1]);hashes={}
for name in ('sevo-overlay-webkit.dll','sevo-overlay-attach.exe'):
 data=(root/name).read_bytes();pe=struct.unpack_from('<I',data,0x3c)[0]
 assert data[:2]==b'MZ' and data[pe:pe+4]==b'PE\0\0' and struct.unpack_from('<H',data,pe+4)[0]==0x8664
 hashes[name]=hashlib.sha256(data).hexdigest()
(root/'manifest.json').write_text(json.dumps({'schema':1,'source':sys.argv[2],
 'helper_sha256':'5ee6df1a5a2237dd3efb7d7042b02ba20f2238ba15d961b1a10ef6d575c59362',
 'cef_sha256':'c85bf94462b3c79baeac63823db52d15e116eead71ea414e5d3a112c59e434d3',
 'payload_sha256':hashes},indent=2)+'\n')
PY
