"""Sign and package the cloud-built application; no local build inputs."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

assert os.environ.get("GITHUB_ACTIONS") == "true", "Run through GitHub Actions"
repo = Path(os.environ["GITHUB_WORKSPACE"])
work = Path(os.environ["RUNNER_TEMP"]) / "sevo-build"
out = Path(os.environ["RUNNER_TEMP"]) / "sevo-output"
tests_run = os.environ.get("SEVO_SKIP_TESTS") != "true"
if tests_run:
    summary = json.loads((out / "test-summary.json").read_text())
    assert summary["passedTests"] > 0 and summary["failedTests"] == 0, summary
else:
    summary = {"status": "not_run", "reason": "explicit workflow input"}
    (out / "test-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
source = work / "Release/Build/Products/Release/Sevoflurane.app"
stage = work / "dmg-root/Sevoflurane.app"
shutil.copytree(source, stage, symlinks=True)
assert not (stage / "Contents/Resources/EmbeddedOverlay").exists()
legacy_source = Path(os.environ["RUNNER_TEMP"]) / "sevo-steam-ui/sevo-steam-ui.exe"
legacy_stage = stage / "Contents/Resources/SteamUI"
legacy_stage.mkdir(exist_ok=True)
shutil.copy2(legacy_source, legacy_stage / "sevo-steam-ui.exe")
assert not (stage / "Contents/Resources/NativeOverlay").exists()
info = plistlib.loads((stage / "Contents/Info.plist").read_bytes())
version = info["CFBundleShortVersionString"]
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-fork\.[0-9]+", version), version
assert info["NSMicrophoneUsageDescription"]
assert not list(stage.rglob("*.xctest"))
assert not list(stage.rglob("*SteamParent*"))
assert not list(stage.rglob("*Sophon*"))
assert not (stage / "Contents/Resources/Engine").exists()
empty = work / "empty-entitlements.plist"
empty.write_bytes(plistlib.dumps({}))

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def sign(path, entitlements):
    run("codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none",
        "--entitlements", str(entitlements), str(path))

for helper in (stage / "Contents/Helpers").iterdir():
    if helper.is_file():
        sign(helper, empty)
for extension in (stage / "Contents/PlugIns").glob("*.appex"):
    sign(extension, repo / "SevofluraneThumbnail/SevofluraneThumbnail.entitlements")
daemon = stage / "Contents/Library/LaunchAgents/SevofluraneDaemon"
sign(daemon, repo / "SevofluraneDaemon/Microphone.entitlements")
sign(stage, repo / "Sevoflurane/Microphone.entitlements")
run("codesign", "--verify", "--deep", "--strict", str(stage))
for binary in (stage, daemon):
    entitlements = run("codesign", "-d", "--entitlements", "-", "--xml", str(binary), capture_output=True)
    assert plistlib.loads(entitlements.stdout) == {"com.apple.security.device.audio-input": True}
    details = run("codesign", "-dvv", str(binary), capture_output=True)
    assert "runtime" in details.stderr.decode()
cli = str(stage / "Contents/Helpers/sevo")
assert version in run(cli, "--version", capture_output=True, text=True).stdout
help_text = run(cli, "--help", capture_output=True, text=True).stdout
assert "hoyo" not in help_text.lower()
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "release-check", "version": "1"}}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
]
response = run(cli, "mcp", input="".join(json.dumps(r) + "\n" for r in requests),
               capture_output=True, text=True, timeout=30)
messages = [json.loads(line) for line in response.stdout.splitlines() if line.strip()]
tools = next(m["result"]["tools"] for m in messages if m.get("id") == 2)
names = {tool["name"] for tool in tools}
assert not any("hoyo" in name.lower() for name in names)
assert {"app_launch", "program_launch"} <= names
(stage.parent / "Applications").symlink_to("/Applications", target_is_directory=True)
dmg = out / f"Sevoflurane-{version}-arm64.dmg"
run("hdiutil", "create", "-volname", f"Sevoflurane {version}", "-srcfolder", str(stage.parent),
    "-format", "UDZO", str(dmg))
run("hdiutil", "verify", str(dmg))
digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
(out / "SHA256SUMS.txt").write_text(f"{digest}  {dmg.name}\n")
notes = (repo / "RELEASE_NOTES.md").read_text()
test_note = (f"{summary['passedTests']} passed, {summary['failedTests']} failed, {summary['skippedTests']} skipped."
             if tests_run else "Test suites not run, as explicitly requested.")
notes += (f"\n\nCloud validation: {test_note} CLI/MCP, signatures and DMG integrity verified.\n"
          f"Source: `{os.environ['GITHUB_SHA']}`\n\n"
          f"[Build and test run]({os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
          f"/actions/runs/{os.environ['GITHUB_RUN_ID']})\n")
(out / "release-notes.md").write_text(notes)
(out / "manifest.json").write_text(json.dumps({"version": version, "dmg": dmg.name,
    "sha256": digest, "source": os.environ["GITHUB_SHA"], "mcpTools": len(tools), "experimental": False, "testsRun": tests_run}, indent=2) + "\n")
print(f"Verified {version}: {len(tools)} MCP tools, SHA-256 {digest}")
