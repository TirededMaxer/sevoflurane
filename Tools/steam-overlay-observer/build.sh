#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
work="$RUNNER_TEMP/steam-overlay-observer"
out="$RUNNER_TEMP/observer-output"
mkdir -p "$work" "$out"
cd "$GITHUB_WORKSPACE/Tools/steam-overlay-observer"
# No restored build cache or local compiler inputs. The runner is ephemeral.
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
  brew install mingw-w64 > "$out/toolchain.log" 2>&1
fi
# This executes Microsoft x64-ABI callbacks from the same observer.c under Rosetta.
# It is not a Windows or Steam runtime acceptance test.
/usr/bin/arch -x86_64 /usr/bin/true
clang -arch x86_64 -std=c11 -O2 -fno-inline-functions -Wall -Wextra -Werror -pthread observer_test.c -o "$work/observer-abi-test"
/usr/bin/arch -x86_64 "$work/observer-abi-test" "$work/stats-fixture.bin" | tee "$out/abi-tests.log"
clang -arch x86_64 -std=c11 -O2 -fno-inline-functions -Wall -Wextra -Werror -pthread cpp_observer_test.c -o "$work/cpp-observer-abi-test"
/usr/bin/arch -x86_64 "$work/cpp-observer-abi-test" "$work/cpp-stats-fixture.bin" | tee "$out/cpp-abi-tests.log"
OBS_FIXTURE="$work/stats-fixture.bin" OBS_CPP_FIXTURE="$work/cpp-stats-fixture.bin" PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest -v test_controller 2>&1 | tee "$out/controller-tests.log"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -shared -static-libgcc \
  -Wl,--exclude-all-symbols observer.c -lbcrypt -o "$work/sevo-overlay-observer.dll"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -shared -static-libgcc \
  -Wl,--exclude-all-symbols cpp_observer.c -lbcrypt -o "$work/sevo-overlay-cpp-observer.dll"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -municode -static-libgcc \
  attach.c -o "$work/sevo-overlay-observer-attach.exe"
PYTHONDONTWRITEBYTECODE=1 python3 -B verify_build.py "$work" "$out" "$GITHUB_SHA"
cp observer.py README.md "$work/"
COPYFILE_DISABLE=1 tar -czf "$out/steam-overlay-observer-$GITHUB_SHA.tar.gz" -C "$work" \
  sevo-overlay-observer.dll sevo-overlay-cpp-observer.dll sevo-overlay-observer-attach.exe observer.py README.md manifest.json
shasum -a 256 "$out/steam-overlay-observer-$GITHUB_SHA.tar.gz" > "$out/archive.sha256"
