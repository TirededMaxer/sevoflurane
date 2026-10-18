#!/bin/bash
# Build only on an ephemeral GitHub runner. Never restore a local/cache archive.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
cd "$GITHUB_WORKSPACE"
work="$RUNNER_TEMP/sevo-build"
out="$RUNNER_TEMP/sevo-output"
mkdir -p "$work" "$out"
export SEVO_EMBED_ENGINE=0
# Compile the small Win32 UI bridge from source on this fresh runner.
if [[ ! -x "$(brew --prefix llvm)/bin/llvm-dlltool" ]]; then brew install llvm; fi
if [[ ! -x "$(brew --prefix lld)/bin/lld-link" ]]; then brew install lld; fi
bash Tools/steam-ui/build-cloud.sh
xcodebuild -version | tee "$out/toolchain.txt"
sw_vers >> "$out/toolchain.txt"
common=(-project Sevoflurane.xcodeproj -scheme Sevoflurane
    -destination 'platform=macOS,arch=arm64'
    -clonedSourcePackagesDirPath "$work/SourcePackages"
    -onlyUsePackageVersionsFromResolvedFile
    DEVELOPMENT_TEAM= ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO)
if [[ "${SEVO_OVERLAY_EXPERIMENT:-0}" == 1 ]]; then
    common+=('OTHER_SWIFT_FLAGS=$(inherited) -D SEVO_WINDOW_OVERLAY_EXPERIMENT')
    bash Tools/embedded-overlay/build.sh
    cp "$RUNNER_TEMP/sevo-overlay/window-check.txt" "$out/overlay-window-check.txt"
fi
test_status=0
xcodebuild "${common[@]}" -configuration Debug -derivedDataPath "$work/Debug" \
    CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
    -testLanguage en -testRegion US -resultBundlePath "$work/Tests.xcresult" test \
    > "$out/tests.log" 2>&1 || test_status=$?
xcrun xcresulttool get test-results summary --path "$work/Tests.xcresult" > "$out/test-summary.json"
python3 - "$out/test-summary.json" <<'PY_SUMMARY'
import json,sys
s=json.load(open(sys.argv[1]))
print(f"Cloud tests: {s['passedTests']} passed; {s['failedTests']} failed; {s['skippedTests']} skipped")
PY_SUMMARY
if [[ "$test_status" != 0 ]]; then tail -100 "$out/tests.log"; exit "$test_status"; fi
xcodebuild "${common[@]}" -configuration Release -derivedDataPath "$work/Release" \
    CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES ENABLE_TESTABILITY=NO build \
    > "$out/build.log" 2>&1 || { tail -100 "$out/build.log"; exit 1; }
