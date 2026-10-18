#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
work="$(mktemp -d "$RUNNER_TEMP/webkit-frame-source.XXXXXX")"
out="$RUNNER_TEMP/webkit-frame-source-output"
mkdir -p "$out"
cd "$GITHUB_WORKSPACE/Tools/webkit-frame-source"
# Only cloud compilation/testing. No package dependencies or restored caches.
clang -std=c11 -O2 -Wall -Wextra -Werror frame_checks.c frame_checks_test.c -o "$work/frame-checks-test"
"$work/frame-checks-test" | tee "$out/checker-tests.log"
python3 - "$work" <<'PY'
import pathlib, re, sys
html = pathlib.Path('fixture.html').read_text()
scripts = re.findall(r'<script>([\s\S]*?)</script>', html)
assert len(scripts) == 1
pathlib.Path(sys.argv[1], 'fixture-script.js').write_text(scripts[0])
assert 'https://' not in html and 'http://' not in html
assert 'getUserMedia' not in html and 'getDisplayMedia' not in html
PY
node --check "$work/fixture-script.js"
app="$work/WebKit Frame Source Diagnostic.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -std=c11 -arch arm64 -mmacosx-version-min=13.0 -O2 -Wall -Wextra -Werror \
  -c frame_checks.c -o "$work/frame_checks.o"
clang -arch arm64 -mmacosx-version-min=13.0 -fobjc-arc -O2 -Wall -Wextra -Werror \
  main.m render_server.m "$work/frame_checks.o" -framework AppKit -framework WebKit -framework QuartzCore \
  -framework Metal -framework IOSurface -framework CoreGraphics -framework CoreFoundation \
  -o "$app/Contents/MacOS/WebKitFrameSource"
cp Info.plist "$app/Contents/Info.plist"
cp fixture.html "$app/Contents/Resources/fixture.html"
/usr/libexec/PlistBuddy -c "Add :SevoBuildCommit string $GITHUB_SHA" "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none --options runtime "$app"
codesign --verify --deep --strict "$app"
file "$app/Contents/MacOS/WebKitFrameSource" > "$out/binary.txt"
otool -L "$app/Contents/MacOS/WebKitFrameSource" > "$out/linkage.txt"
codesign -dvv "$app" > "$out/signature.txt" 2>&1
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/webkit-frame-source-$GITHUB_SHA.zip"
python3 - "$app" "$out" "$GITHUB_SHA" <<'PY'
import hashlib,json,pathlib,sys
app,out,commit=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3]
files={str(p.relative_to(app)):hashlib.sha256(p.read_bytes()).hexdigest()
       for p in app.rglob('*') if p.is_file()}
manifest={'schema':1,'commit':commit,'architecture':'arm64','ad_hoc_signed':True,
          'checker_tests_executed':True,'gui_executed':False,'steam_connected':False,
          'app_files_sha256':files}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
archive=out/('webkit-frame-source-'+commit+'.zip')
(out/'archive.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n')
PY
cp README.md "$out/README.md"
