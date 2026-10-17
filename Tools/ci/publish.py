"""Publish only verified assets, then remove older Releases without deleting tags."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

assert os.environ.get("GITHUB_ACTIONS") == "true", "Run through GitHub Actions"
repo = os.environ["GITHUB_REPOSITORY"]
out = Path(os.environ["RUNNER_TEMP"]) / "sevo-output"
manifest = json.loads((out / "manifest.json").read_text())
assert not manifest.get("experimental", False), "Unaccepted overlay candidates cannot become a public Release"
tag = "v" + manifest["version"]
files = [out / manifest["dmg"], out / "SHA256SUMS.txt"]

def gh(*args, **kwargs):
    result = subprocess.run(["gh", *args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"gh {args}: {result.stderr}")
    return result.stdout

build_run = os.environ.get("SEVO_BUILD_RUN_ID", "")
if build_run:
    assert build_run.isdecimal(), "Build run must be a numeric Actions run ID"
    run = json.loads(gh("api", f"repos/{repo}/actions/runs/{build_run}"))
    assert run["head_sha"] == manifest["source"] and run["status"] == "completed"
    assert run["path"] == ".github/workflows/release.yml"
    assert run["repository"]["full_name"] == repo
    jobs = json.loads(gh("api", f"repos/{repo}/actions/runs/{build_run}/jobs"))["jobs"]
    successful = {step["name"] for job in jobs for step in job["steps"] if step["conclusion"] == "success"}
    assert {"Test and build on a fresh Apple Silicon runner", "Sign, verify and package",
            "Upload build and test evidence"} <= successful, "Original build checks must have passed"
    summary = json.loads((out / "test-summary.json").read_text())
    assert summary["passedTests"] > 0 and summary["failedTests"] == 0
else:
    assert manifest["source"] == os.environ["GITHUB_SHA"]
assert hashlib.sha256(files[0].read_bytes()).hexdigest() == manifest["sha256"]

releases = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
releases = [release for page in releases for release in page]
existing = next((release for release in releases if release["tag_name"] == tag), None)
if existing:
    assert existing["draft"], "Bump the version before replacing an already published Release"
    assert existing["target_commitish"] == manifest["source"], "Draft belongs to another source commit"
else:
    gh("release", "create", tag, "--repo", repo, "--draft", "--target", manifest["source"],
       "--title", "Sevoflurane " + manifest["version"], "--notes-file", str(out / "release-notes.md"))
gh("release", "upload", tag, "--repo", repo, "--clobber", *(str(file) for file in files))
gh("release", "edit", tag, "--repo", repo, "--notes-file", str(out / "release-notes.md"))

# A draft has no Git tag yet. Find it by ID from the authenticated release list.
current = json.loads(gh("api", f"repos/{repo}/releases?per_page=100"))
release_id = next(release["id"] for release in current if release["tag_name"] == tag)

def verify():
    remote = json.loads(gh("api", f"repos/{repo}/releases/{release_id}"))
    assets = {asset["name"]: asset for asset in remote["assets"]}
    assert set(assets) == {file.name for file in files}, assets
    with tempfile.TemporaryDirectory(prefix="sevo-release-check-") as directory:
        gh("release", "download", tag, "--repo", repo, "--dir", directory)
        for file in files:
            asset = assets[file.name]
            assert asset["state"] == "uploaded" and asset["size"] == file.stat().st_size
            assert hashlib.sha256((Path(directory) / file.name).read_bytes()).digest() == hashlib.sha256(file.read_bytes()).digest()
    return remote

verify()
gh("release", "edit", tag, "--repo", repo, "--draft=false", "--latest")
remote = verify()
assert not remote["draft"]
for previous in releases:
    if previous["tag_name"] != tag:
        gh("api", "--method", "DELETE", f"repos/{repo}/releases/{previous['id']}")
print(f"Published {remote['html_url']}; verified both downloads; removed older Releases, retained Git tags")
