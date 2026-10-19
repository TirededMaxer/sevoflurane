#!/bin/bash
# Build only on an ephemeral GitHub runner. Never restore a local/cache archive.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
cd "$GITHUB_WORKSPACE"
work="$RUNNER_TEMP/sevo-build"
out="$RUNNER_TEMP/sevo-output"
mkdir -p "$work" "$out"
export SEVO_EMBED_ENGINE=0
stage="${1:-all}"
common=(-project Sevoflurane.xcodeproj -scheme Sevoflurane
    -destination 'platform=macOS,arch=arm64'
    -clonedSourcePackagesDirPath "$work/SourcePackages"
    -onlyUsePackageVersionsFromResolvedFile
    DEVELOPMENT_TEAM= ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO)
if [[ "$stage" == test || "$stage" == all ]]; then
    bash Tools/steam-ui/build-cloud.sh
    xcodebuild -version | tee "$out/toolchain.txt"
    sw_vers >> "$out/toolchain.txt"
    # Real fullscreen/modal checks need a process without other UI fixtures
    # changing NSApplication's window, activation and modal state underneath.
    for group in regular appkit; do
        if [[ "$group" == regular ]]; then
            filter=(-skip-testing:SevofluraneTests/AppKitPresentationTests)
        else
            filter=(-only-testing:SevofluraneTests/AppKitPresentationTests)
        fi
        echo "Testing $group suites in a separate app process"
        test_status=0
        xcodebuild "${common[@]}" "${filter[@]}" -configuration Debug -derivedDataPath "$work/Debug" \
            CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
            -testLanguage en -testRegion US -resultBundlePath "$work/$group.xcresult" test \
            > "$out/$group-tests.log" 2>&1 || test_status=$?
        xcrun xcresulttool get test-results summary --path "$work/$group.xcresult" > "$out/$group-test-summary.json"
        if [[ "$test_status" != 0 ]]; then
            python3 - "$out/$group-tests.log" <<'PY_FAILURES'
import sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text(errors="replace").splitlines():
    if "✘" in line or "Expectation failed:" in line or ("error:" in line and ".swift:" in line):
        print(line)
PY_FAILURES
            tail -30 "$out/$group-tests.log"
            exit "$test_status"
        fi
    done
    python3 - "$out" <<'PY_SUMMARY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
runs={name:json.loads((root/f"{name}-test-summary.json").read_text()) for name in ("regular","appkit")}
assert all(s["passedTests"]>0 for s in runs.values()), "Both test groups must run"
summary={key:sum(s[key] for s in runs.values()) for key in ("passedTests","failedTests","skippedTests")}
summary["runs"]=runs
(root/"test-summary.json").write_text(json.dumps(summary,indent=2)+"\n")
print(f"Cloud tests: {summary['passedTests']} passed; {summary['failedTests']} failed; {summary['skippedTests']} skipped")
PY_SUMMARY
fi
if [[ "$stage" == release || "$stage" == all ]]; then
    # A build-only run still needs the Win32 UI helper in the application.
    if [[ ! -f "$RUNNER_TEMP/sevo-steam-ui/sevo-steam-ui.exe" ]]; then
        bash Tools/steam-ui/build-cloud.sh
        xcodebuild -version > "$out/toolchain.txt"
        sw_vers >> "$out/toolchain.txt"
    fi
    xcodebuild "${common[@]}" -configuration Release -derivedDataPath "$work/Release" \
        CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES ENABLE_TESTABILITY=NO build \
        > "$out/build.log" 2>&1 || { tail -100 "$out/build.log"; exit 1; }
fi
