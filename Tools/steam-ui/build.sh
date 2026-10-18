#!/bin/bash
set -euo pipefail
if [ "$#" -ne 3 ]; then echo 'Usage: build.sh WINE_SOURCE GENERATED_HEADERS KERNEL32_IMPORT_LIBRARY'; exit 2; fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
llvm_root="$(brew --prefix llvm)"
lld_root="$(brew --prefix lld)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
"$llvm_root/bin/llvm-dlltool" -m i386:x86-64 -d "$repo_root/Tools/steam-ui/user32.def" -l "$work_dir/user32.lib"
"$llvm_root/bin/llvm-dlltool" -m i386:x86-64 -d "$repo_root/Tools/steam-ui/gdi32.def" -l "$work_dir/gdi32.lib"
"$llvm_root/bin/clang" --target=x86_64-w64-windows-gnu -O2 -ffreestanding -fno-stack-protector -Wno-dll-attribute-on-redeclaration -I "$2" -I "$1/include/msvcrt" -I "$1/include" -c "$repo_root/Tools/steam-ui/steam-ui.c" -o "$work_dir/steam-ui.obj"
mkdir -p "$repo_root/Sevoflurane/Resources/SteamUI"
"$lld_root/bin/lld-link" /entry:mainCRTStartup /subsystem:console /nodefaultlib "/out:$repo_root/Sevoflurane/Resources/SteamUI/sevo-steam-ui.exe" "$work_dir/steam-ui.obj" "$3" "$work_dir/user32.lib" "$work_dir/gdi32.lib"
