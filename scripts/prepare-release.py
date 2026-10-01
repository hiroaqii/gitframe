#!/usr/bin/env python3
"""Update the release version and commit it with an already prepared notes file."""

import argparse
import difflib
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
REPO = "hiroaqii/gitframe"
MANIFEST = "build.zig.zon"
VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def command(*args, check=True):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=120)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{args[0]} failed")
    return result


def version_tuple(version):
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("Use a stable major.minor.patch version, without a v prefix.")
    return tuple(map(int, version.split(".")))


def updated_manifest(contents, version):
    requested = version_tuple(version)
    matches = list(re.finditer(r'(?m)^[ \t]*\.version[ \t]*=[ \t]*"([^"\r\n]+)"[ \t]*,', contents))
    if len(matches) != 1:
        raise ValueError("Expected exactly one .version field in build.zig.zon")
    match = matches[0]
    current = match[1]
    if requested <= version_tuple(current):
        raise ValueError(f"Requested version {version} must be newer than the current version {current}.")
    return current, contents[:match.start(1)] + version + contents[match.end(1):]


def require_checkout():
    origin = command("git", "remote", "get-url", "origin").stdout.strip()
    if origin.removesuffix(".git") not in (f"git@github.com:{REPO}", f"https://github.com/{REPO}"):
        raise ValueError(f"origin must point to {REPO}")
    branch = command("git", "symbolic-ref", "--quiet", "HEAD", check=False)
    if branch.returncode:
        raise ValueError("Check out a branch before preparing a release; HEAD is detached.")
    for operation in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"):
        path = command("git", "rev-parse", "--git-path", operation).stdout.strip()
        if (ROOT / path).exists():
            raise ValueError("Finish the current merge, rebase, cherry-pick, or revert before preparing a release.")
    if command("git", "ls-files", "--unmerged").stdout:
        raise ValueError("Resolve existing conflicts before preparing a release.")
    return command("git", "rev-parse", "HEAD").stdout.strip(), branch.stdout.strip()


def require_clean_manifest():
    command("git", "ls-files", "--error-unmatch", "--", MANIFEST)
    for args in (("diff", "--quiet", "HEAD", "--", MANIFEST),
                 ("diff", "--cached", "--quiet", "--", MANIFEST)):
        result = command("git", *args, check=False)
        if result.returncode == 1:
            raise ValueError("build.zig.zon has local or staged edits; commit or resolve them first.")
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or "Could not inspect build.zig.zon")


def require_regular_file(relative):
    path = ROOT / relative
    if any((ROOT / parent).is_symlink() for parent in Path(relative).parents) or path.is_symlink():
        raise ValueError(f"Expected a regular file without symlink parents: {relative}")
    if not path.is_file():
        raise ValueError(f"Missing file: {relative}. Prepare it before running this command.")
    return path


def require_unused_tag(tag):
    local = command("git", "show-ref", "--verify", "--quiet", f"refs/tags/{tag}", check=False)
    if local.returncode == 0:
        raise ValueError(f"Local tag {tag} already exists; no files were changed.")
    if local.returncode != 1:
        raise RuntimeError(local.stderr.strip() or "Could not inspect local tags")
    remote = command("gh", "api", "--hostname", "github.com",
                     f"repos/{REPO}/git/ref/tags/{tag}", check=False)
    if remote.returncode == 0:
        raise ValueError(f"Remote tag {tag} already exists; no files were changed.")
    if "(HTTP 404)" not in remote.stderr:
        raise RuntimeError(remote.stderr.strip() or remote.stdout.strip() or "Could not inspect remote tags")


def run(args):
    version_tuple(args.version)
    sha, branch = require_checkout()
    require_clean_manifest()
    manifest = require_regular_file(MANIFEST)
    original = manifest.read_bytes()
    current, updated = updated_manifest(original.decode("utf-8"), args.version)
    tag = f"v{args.version}"
    notes_relative = f".github/release-notes/{tag}.md"
    notes = require_regular_file(notes_relative)
    notes_bytes = notes.read_bytes()
    if not notes_bytes.decode("utf-8").strip():
        raise ValueError(f"Release notes are empty: {notes_relative}. Write them before preparing the release.")
    command("git", "var", "GIT_AUTHOR_IDENT")
    command("git", "var", "GIT_COMMITTER_IDENT")
    require_unused_tag(tag)
    if require_checkout() != (sha, branch) or manifest.read_bytes() != original or notes.read_bytes() != notes_bytes:
        raise ValueError("HEAD, branch, version, or notes changed during validation; no files were changed by this command.")
    require_clean_manifest()
    print(f"Prepare {current} -> {args.version} on {branch.removeprefix('refs/heads/')}", flush=True)
    print("".join(difflib.unified_diff(original.decode("utf-8").splitlines(True), updated.splitlines(True),
                                     fromfile=MANIFEST, tofile=MANIFEST)), end="", flush=True)
    print(f"Release notes: {notes_relative}", flush=True)
    if args.dry_run:
        print("Would update the version and commit only these two files. No files or Git state were changed.")
        return
    manifest.write_bytes(updated.encode("utf-8"))
    try:
        command("git", "add", "--", MANIFEST, notes_relative)
        # --only excludes every unrelated staged path while preserving it in the index.
        command("git", "commit", "--only", "-m", f"chore: prepare release {tag}", "--", MANIFEST, notes_relative)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"Could not finish the preparation commit: {error}\n"
                           "The version edit and notes are left for inspection; finish the commit manually. "
                           "No tag or push was attempted.") from error
    commit = command("git", "rev-parse", "--short", "HEAD").stdout.strip()
    print(f"Committed {tag}: {commit}. Review and push the commit, then run scripts/release-github.py.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="new stable version, without a v prefix")
    parser.add_argument("--dry-run", action="store_true", help="validate and show the version diff without editing or committing")
    args = parser.parse_args()
    try:
        run(args)
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"prepare-release: {error}\n")
    except KeyboardInterrupt:
        parser.exit(130, "Interrupted. Inspect git status and the latest commit before retrying.\n")


if __name__ == "__main__":
    main()
