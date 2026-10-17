#!/bin/bash
# Build only on an ephemeral GitHub runner. Never restore a local/cache archive.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
cd "$GITHUB_WORKSPACE"
work="$RUNNER_TEMP/sevo-build"
out="$RUNNER_TEMP/sevo-output"
mkdir -p "$work" "$out"
export SEVO_EMBED_ENGINE=0
bash Tools/embedded-overlay/build.sh
cp "$RUNNER_TEMP/sevo-overlay/check.txt" "$out/overlay-check.txt"
xcodebuild -version | tee "$out/toolchain.txt"
sw_vers >> "$out/toolchain.txt"
common=(-project Sevoflurane.xcodeproj -scheme Sevoflurane
    -destination 'platform=macOS,arch=arm64'
    -clonedSourcePackagesDirPath "$work/SourcePackages"
    -onlyUsePackageVersionsFromResolvedFile
    DEVELOPMENT_TEAM= ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO)
test_status=0
xcodebuild "${common[@]}" -configuration Debug -derivedDataPath "$work/Debug" \
    CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
    -testLanguage en -testRegion US -resultBundlePath "$work/Tests.xcresult" test \
    > "$out/tests.log" 2>&1 || test_status=$?
xcrun xcresulttool get test-results summary --path "$work/Tests.xcresult" > "$out/test-summary.json"
if [[ "$test_status" != 0 ]]; then tail -100 "$out/tests.log"; exit "$test_status"; fi
xcodebuild "${common[@]}" -configuration Release -derivedDataPath "$work/Release" \
    CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES ENABLE_TESTABILITY=NO build \
    > "$out/build.log" 2>&1 || { tail -100 "$out/build.log"; exit 1; }
