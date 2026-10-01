#!/usr/bin/env python3
"""Tag a pushed commit and wait for the Release workflow to validate and publish it."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import quote, urlencode

import release


ROOT = Path(__file__).resolve().parent.parent
REPO = "hiroaqii/gitframe"
WORKFLOW = "release.yml"
BUILD_JOBS = {"prepare", "Build linux-x86_64", "Build macos-arm64", "assemble"}


def command(*args, check=True):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=120)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{args[0]} failed")
    return result


def api(path, *, data=None, missing_ok=False, raw=False):
    args = ["gh", "api", "--hostname", "github.com", f"repos/{REPO}/{path}"]
    if raw:
        args += ["-H", "Accept: application/octet-stream"]
    if data is not None:
        args += ["--method", "POST", "--input", "-"]
    result = subprocess.run(args, cwd=ROOT, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        if missing_ok and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout if raw else json.loads(result.stdout or "null")


def require_checkout():
    origin = command("git", "remote", "get-url", "origin").stdout.strip()
    if origin.removesuffix(".git") not in (f"git@github.com:{REPO}", f"https://github.com/{REPO}"):
        raise ValueError(f"origin must point to {REPO}")
    return command("git", "rev-parse", "HEAD").stdout.strip()


def release_tag_at(sha):
    """Validate release metadata from the selected commit, not the index or worktree."""
    with tempfile.TemporaryDirectory(prefix="gitframe-release-metadata-") as temporary:
        snapshot = Path(temporary)
        manifest = command("git", "show", f"{sha}:build.zig.zon").stdout
        (snapshot / "build.zig.zon").write_text(manifest, encoding="utf-8")
        tag = release.validate_tag(None, snapshot)
        notes_path = f".github/release-notes/{tag}.md"
        notes = command("git", "show", f"{sha}:{notes_path}", check=False)
        if notes.returncode:
            raise ValueError(f"Cannot read committed release notes: {notes_path}. Commit and push them first.")
        destination = snapshot / notes_path
        destination.parent.mkdir(parents=True)
        destination.write_text(notes.stdout, encoding="utf-8")
        release.release_notes(tag, snapshot)
        return tag


def remote_commit(ref):
    value = api(f"git/ref/{quote(ref, safe='/')}", missing_ok=True)
    if value is None:
        return None
    obj = value["object"]
    for _ in range(8):
        if obj["type"] == "commit":
            return obj["sha"]
        if obj["type"] != "tag":
            break
        obj = api(f"git/tags/{obj['sha']}")["object"]
    raise ValueError(f"{ref} does not resolve to a commit")


def check_tag(tag, sha):
    local = command("git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}", check=False)
    if local.returncode == 0 and local.stdout.strip() != sha:
        raise ValueError(f"Local tag {tag} points to another commit; it will not be replaced.")
    if local.returncode not in (0, 1):
        raise RuntimeError(local.stderr.strip() or "Could not inspect local tag")
    remote = remote_commit(f"tags/{tag}")
    if remote is not None and remote != sha:
        raise ValueError(f"Remote tag {tag} points to another commit; it will not be replaced.")
    return local.returncode == 0, remote is not None


def find_run(event, sha, ref):
    query = urlencode({"event": event, "head_sha": sha, "branch": ref, "per_page": 100})
    runs = api(f"actions/workflows/{WORKFLOW}/runs?{query}")["workflow_runs"]
    matches = [run for run in runs if run["event"] == event and run["head_sha"] == sha
               and run["head_branch"] == ref]
    return max(matches, key=lambda run: run["id"], default=None)


def wait_for_run(event, sha, ref, timeout, retry_failed=False, dispatch=False):
    run = find_run(event, sha, ref)
    if run is None and dispatch:
        if remote_commit(f"heads/{ref}") != sha:
            raise ValueError("The remote branch moved before validation. Restart from the intended commit.")
        print(f"Starting Release validation for {sha} on {ref}", flush=True)
        api(f"actions/workflows/{WORKFLOW}/dispatches", data={"ref": ref})

    discovery_deadline = time.monotonic() + min(timeout, 180)
    while run is None:
        if time.monotonic() >= discovery_deadline:
            raise TimeoutError(f"No {event} Release run found for {ref} at {sha}. Check Actions, then rerun.")
        time.sleep(10)
        run = find_run(event, sha, ref)

    minimum_attempt = run["run_attempt"]
    if run["status"] == "completed" and run["conclusion"] != "success" and retry_failed:
        minimum_attempt += 1
        print(f"Retrying {run['html_url']}", flush=True)
        api(f"actions/runs/{run['id']}/rerun", data={})

    deadline = time.monotonic() + timeout
    last_status = None
    while True:
        current = api(f"actions/runs/{run['id']}")
        if (current["head_sha"], current["event"], current["head_branch"]) != (sha, event, ref):
            raise ValueError("Workflow run does not match the selected commit, event, and ref.")
        status = (current["run_attempt"], current["status"], current["conclusion"])
        if status != last_status:
            print(f"{current['html_url']}: attempt {status[0]}, {status[1]}, {status[2] or 'waiting'}", flush=True)
            last_status = status
        if current["run_attempt"] >= minimum_attempt and current["status"] == "completed":
            if current["conclusion"] != "success":
                raise RuntimeError(f"Release workflow failed: {current['html_url']}. Use --retry-failed to retry.")
            jobs = api(f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]
            required = BUILD_JOBS | ({"publish"} if event == "push" else set())
            successful = {job["name"] for job in jobs if job["conclusion"] == "success"}
            if not required <= successful:
                raise ValueError(f"Required jobs did not succeed: {sorted(required - successful)}")
            return
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Still waiting for {current['html_url']}. Rerun the script to resume.")
        time.sleep(10)


def verify_release(value, tag):
    if value is None or value["draft"] or value["prerelease"] or value["tag_name"] != tag:
        raise ValueError(f"{tag} is not a published stable release")
    expected = {f"gitframe-{tag}-{platform}.tar.gz" for platform in release.PLATFORMS}
    names = expected | {"SHA256SUMS"}
    assets = [asset for asset in value["assets"] if asset["name"] in names]
    if len(assets) != len(names) or {asset["name"] for asset in assets} != names:
        raise ValueError("The release must contain both archives and SHA256SUMS exactly once.")
    if any(asset["state"] != "uploaded" or asset["size"] <= 0 for asset in assets):
        raise ValueError("The release contains incomplete or empty assets.")
    assets = {asset["name"]: asset for asset in assets}
    checksums = api(f"releases/assets/{assets['SHA256SUMS']['id']}", raw=True)
    hashes = {}
    for line in checksums.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if match is None or match[2] in hashes:
            raise ValueError("Invalid or duplicate entry in SHA256SUMS")
        hashes[match[2]] = match[1]
    if set(hashes) != expected:
        raise ValueError("SHA256SUMS does not match the expected release archives")
    for name, digest in hashes.items():
        if assets[name].get("digest") != f"sha256:{digest}":
            raise ValueError(f"GitHub asset digest does not match SHA256SUMS: {name}")
    print(f"Published and verified: {value['html_url']}", flush=True)


def run(args):
    sha = require_checkout()
    tag = release_tag_at(sha)
    local_tag, remote_tag = check_tag(tag, sha)
    published = api(f"releases/tags/{tag}", missing_ok=True)
    print(f"Release {tag} from {sha}", flush=True)
    print("Only files committed at this revision will be released; local changes are not included.", flush=True)
    if published is not None and not published["draft"]:
        if not remote_tag:
            raise ValueError("Published release has no matching remote tag")
        verify_release(published, tag)
        return
    if published is not None and not remote_tag:
        raise ValueError("Existing draft has no matching remote tag; inspect it before proceeding.")
    if not remote_tag and remote_commit(f"heads/{args.branch}") != sha:
        raise ValueError(f"Push this commit to {args.branch} before releasing; remote HEAD must match.")
    if args.dry_run:
        if remote_tag:
            print("Would resume the tag's Release workflow.")
        elif args.preflight:
            print("Would run preflight validation, create/push the tag, then run the Release workflow again to publish.")
        else:
            print("Would create/push the tag and wait for one Release workflow to build, test, and publish.")
        return
    if not remote_tag:
        if args.preflight:
            wait_for_run("workflow_dispatch", sha, args.branch, args.timeout, args.retry_failed, dispatch=True)
        if require_checkout() != sha or remote_commit(f"heads/{args.branch}") != sha:
            raise ValueError("Local HEAD or the remote branch changed before tagging; no tag was pushed.")
        local_tag, remote_tag = check_tag(tag, sha)
        if not remote_tag:
            if not local_tag:
                command("git", "tag", "-a", tag, sha, "-m", f"GitFrame {tag}")
            print(f"Pushing {tag} at {sha}", flush=True)
            command("git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
                    "push", f"https://github.com/{REPO}.git", f"refs/tags/{tag}:refs/tags/{tag}")
    wait_for_run("push", sha, tag, args.timeout, args.retry_failed)
    if remote_commit(f"tags/{tag}") != sha:
        raise ValueError("Remote tag changed during publication")
    verify_release(api(f"releases/tags/{tag}"), tag)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--branch", default="main", help="pushed branch to release (default: main)")
    parser.add_argument("--dry-run", action="store_true", help="inspect only; do not start Actions or create/push a tag")
    parser.add_argument("--preflight", action="store_true", help="also validate before tagging (builds and tests twice)")
    parser.add_argument("--retry-failed", action="store_true", help="rerun an existing failed Release workflow")
    parser.add_argument("--timeout", type=int, default=3600, help="seconds to wait per workflow (default: 3600)")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        run(args)
    except (ValueError, RuntimeError, OSError, TimeoutError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"release-github: {error}\n")
    except KeyboardInterrupt:
        parser.exit(130, "Stopped waiting. Actions may still be running; rerun to resume.\n")


if __name__ == "__main__":
    main()
