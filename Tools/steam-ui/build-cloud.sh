#!/bin/bash
# Rebuild the Win32 presentation bridge only on a fresh GitHub runner.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]
cd "$GITHUB_WORKSPACE"
work="$RUNNER_TEMP/sevo-steam-ui"
mkdir -p "$work"
llvm="$(brew --prefix llvm)"
lld="$(brew --prefix lld)"
for dll in user32 kernel32 gdi32; do
    "$llvm/bin/llvm-dlltool" -m i386:x86-64 -d "Tools/steam-ui/$dll.def" -l "$work/$dll.lib"
done
"$llvm/bin/clang" --target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-builtin \
    -fno-stack-protector -DSEVO_STANDALONE -c Tools/steam-ui/steam-ui.c -o "$work/steam-ui.obj"
"$lld/bin/lld-link" /entry:mainCRTStartup /subsystem:console /nodefaultlib \
    "/out:$work/sevo-steam-ui.exe" "$work/steam-ui.obj" "$work/kernel32.lib" "$work/user32.lib" "$work/gdi32.lib"
cp "$work/sevo-steam-ui.exe" Sevoflurane/Resources/SteamUI/sevo-steam-ui.exe
