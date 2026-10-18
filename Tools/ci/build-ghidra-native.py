"""Build REA's missing macOS ARM64 Ghidra decompiler only on GitHub."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import zipfile

assert os.environ.get("GITHUB_ACTIONS") == "true" and platform.machine() == "arm64"
version = "12.1.4"
name = "ghidra_12.1.4_PUBLIC_20260921.zip"
url = "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/" + name
source_sha = "ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db"
root = Path(os.environ["RUNNER_TEMP"]) / "sevo-ghidra-native"
root.mkdir()
archive = root / name
subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(archive), url], check=True)
assert hashlib.file_digest(archive.open("rb"), "sha256").hexdigest() == source_sha
with zipfile.ZipFile(archive) as package:
    assert all((root / member.filename).resolve().is_relative_to(root.resolve()) for member in package.infolist())
subprocess.run(["ditto", "-x", "-k", str(archive), str(root)], check=True)
engine = root / ("ghidra_" + version + "_PUBLIC")
cpp = engine / "Ghidra/Features/Decompiler/src/decompile/cpp"
# The official Makefile defaults to Intel on Darwin. Override its documented
# make variables; preserve the pinned upstream source and target selection.
subprocess.run(["make", "-j", "6", "ghidra_opt", "CXX=clang++ -std=c++11",
                "ARCH_TYPE=-arch arm64", "ADDITIONAL_FLAGS=-mmacosx-version-min=14.0 -w",
                "OSDIR=mac_arm_64"], cwd=cpp, check=True)
out = Path(os.environ["RUNNER_TEMP"]) / "sevo-ghidra-output"
out.mkdir()
binary = out / "decompile"
shutil.copy2(cpp / "ghidra_opt", binary)
assert subprocess.run(["lipo", "-archs", str(binary)], capture_output=True, text=True, check=True).stdout.strip() == "arm64"
subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
for license_name in ["LICENSE", "NOTICE", "DISCLAIMER.md"]:
    source = engine / license_name
    if source.exists():
        shutil.copy2(source, out / license_name)
manifest = {"upstreamVersion": version, "sourceURL": url, "sourceZIP_SHA256": source_sha,
            "sourceCommit": os.environ["GITHUB_SHA"], "architecture": "arm64",
            "sha256": hashlib.file_digest(binary.open("rb"), "sha256").hexdigest()}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(out / "SHA256SUMS.txt").write_text(manifest["sha256"] + "  decompile\n")
print(json.dumps(manifest))
