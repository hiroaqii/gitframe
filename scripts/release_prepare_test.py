"""Preparation commits are tested in temporary repos; GitHub requests are read-only fakes."""

import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("prepare_release", Path(__file__).with_name("prepare-release.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
VERSION = "1.2.3"
TAG = f"v{VERSION}"
MANIFEST = b'.{\n    .name = .gitframe,\n    .version = "1.2.2",\n    .minimum_zig_version = "0.16.0",\n}\n'


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        root_patch = patch.object(prepare, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        self.real_command = prepare.command
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("remote", "add", "origin", f"https://github.com/{prepare.REPO}.git")
        self.manifest = self.root / prepare.MANIFEST
        self.manifest.write_bytes(MANIFEST)
        (self.root / "README.md").write_text("Original readme\n")
        self.git("add", ".")
        self.git("commit", "-m", "Fixture")
        self.head = self.git("rev-parse", "HEAD")
        self.notes_relative = f".github/release-notes/{TAG}.md"
        self.notes = self.root / self.notes_relative
        self.notes.parent.mkdir(parents=True)
        self.notes.write_text("## Fixed\n\n- Release notes: 日本語 & `quoted` text.\n", encoding="utf-8")
        self.remote_response = subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")
        self.remote_calls = []
        self.during_remote = None
        command_patch = patch.object(prepare, "command", side_effect=self.command)
        command_patch.start()
        self.addCleanup(command_patch.stop)

    def git(self, *args):
        return self.real_command("git", *args).stdout.strip()

    def command(self, *args, **kwargs):
        if args[0] == "gh":
            self.assertEqual(args, ("gh", "api", "--hostname", "github.com",
                                   f"repos/{prepare.REPO}/git/ref/tags/{TAG}"))
            self.remote_calls.append(args)
            if self.during_remote:
                self.during_remote()
            return self.remote_response
        self.assertNotIn("push", args)
        self.assertNotIn("fetch", args)
        self.assertNotIn("clone", args)
        self.assertNotIn("tag", args)
        return self.real_command(*args, **kwargs)

    def args(self, version=VERSION, dry_run=False):
        return argparse.Namespace(version=version, dry_run=dry_run)

    def state(self):
        return (self.git("rev-parse", "HEAD"), self.git("status", "--porcelain"),
                self.git("diff", "--cached", "--binary"), self.git("diff", "--binary"),
                self.git("tag", "--list"), self.manifest.read_bytes(),
                self.notes.read_bytes() if self.notes.exists() else None)

    def assert_rejected_without_changes(self, message, args=None, error=ValueError):
        before = self.state()
        with self.assertRaisesRegex(error, message):
            prepare.run(args or self.args())
        self.assertEqual(self.state(), before)

    def test_commits_only_release_files_and_preserves_unrelated_staged_and_unstaged_edits(self):
        readme = self.root / "README.md"
        readme.write_text("Staged readme\n")
        self.git("add", "README.md")
        readme.write_text("Unstaged readme\n")
        staged = self.git("diff", "--cached", "--", "README.md")
        (self.root / "local-script.py").write_text("# Untracked local script\n")
        notes = self.notes.read_bytes()
        prepare.run(self.args())
        self.assertEqual(set(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines()),
                         {prepare.MANIFEST, self.notes_relative})
        self.assertEqual(self.git("rev-parse", "HEAD^"), self.head)
        self.assertEqual(self.manifest.read_bytes(), MANIFEST.replace(b'"1.2.2"', b'"1.2.3"'))
        self.assertEqual(self.git("show", f"HEAD:{self.notes_relative}"), notes.decode("utf-8").strip())
        self.assertEqual(self.git("show", "HEAD:README.md"), "Original readme")
        self.assertEqual(self.git("diff", "--cached", "--", "README.md"), staged)
        self.assertEqual(readme.read_text(), "Unstaged readme\n")
        self.assertEqual(self.notes.read_bytes(), notes)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertIn("?? local-script.py", self.git("status", "--porcelain"))
        self.assertEqual(len(self.remote_calls), 1)

    def test_dry_run_changes_neither_files_nor_git_state(self):
        self.git("add", self.notes_relative)
        before = self.state()
        prepare.run(self.args(dry_run=True))
        self.assertEqual(self.state(), before)
        self.assertEqual(len(self.remote_calls), 1)

    def test_old_and_equal_versions_stop_before_network_and_file_changes(self):
        for version in ("0.9.9", "1.2.1", "1.2.2"):
            with self.subTest(version=version):
                self.assert_rejected_without_changes("must be newer", self.args(version))
        self.assertEqual(self.remote_calls, [])

    def test_invalid_versions_are_rejected(self):
        for version in ("v1.2.3", "1.2", "1.2.3-rc.1", "01.2.3", "1.2.3\n", "../1.2.3"):
            with self.subTest(version=version):
                self.assert_rejected_without_changes("stable major.minor.patch", self.args(version))
        self.assertEqual(self.remote_calls, [])

    def test_version_comparison_is_numeric_and_preserves_other_manifest_bytes(self):
        original = MANIFEST.decode().replace("1.2.2", "1.2.9").replace("\n", "\r\n")
        current, updated = prepare.updated_manifest(original, "1.2.10")
        self.assertEqual(current, "1.2.9")
        self.assertEqual(updated, original.replace("1.2.9", "1.2.10"))
        for version in ("1.3.0", "2.0.0"):
            self.assertIn(version, prepare.updated_manifest(original, version)[1])

    def test_missing_and_blank_notes_stop_before_network_and_file_changes(self):
        self.notes.unlink()
        self.assert_rejected_without_changes("Missing file")
        for value in ("", " \n\t"):
            self.notes.write_text(value)
            self.assert_rejected_without_changes("notes are empty")
        self.assertEqual(self.remote_calls, [])

    def test_existing_local_tag_stops_without_network_or_mutation(self):
        self.git("tag", "-a", TAG, "-m", "Existing tag")
        self.assert_rejected_without_changes("Local tag .* already exists")
        self.assertEqual(self.remote_calls, [])

    def test_existing_remote_tag_stops_without_mutation(self):
        self.remote_response = subprocess.CompletedProcess([], 0, "{}", "")
        self.assert_rejected_without_changes("Remote tag .* already exists")

    def test_remote_errors_are_not_treated_as_a_missing_tag(self):
        for message in ("gh: Forbidden (HTTP 403)", "gh: failed (HTTP 500)", "error connecting to api.github.com"):
            with self.subTest(message=message):
                self.remote_response = subprocess.CompletedProcess([], 1, "", message)
                self.assert_rejected_without_changes("gh:|error connecting", error=RuntimeError)

    def test_manifest_edits_in_worktree_or_index_are_not_silently_committed(self):
        for kind in ("unstaged", "staged", "staged_only"):
            with self.subTest(kind=kind):
                self.manifest.write_bytes(MANIFEST)
                self.git("add", prepare.MANIFEST)
                self.manifest.write_bytes(MANIFEST.replace(b"0.16.0", b"0.17.0"))
                if kind != "unstaged":
                    self.git("add", prepare.MANIFEST)
                if kind == "staged_only":
                    self.manifest.write_bytes(MANIFEST)
                self.assert_rejected_without_changes("local or staged edits")
        self.assertEqual(self.remote_calls, [])

    def test_detached_head_and_merge_in_progress_are_rejected(self):
        self.git("switch", "--detach", self.head)
        self.assert_rejected_without_changes("HEAD is detached")
        self.git("switch", "main")
        (self.root / ".git/MERGE_HEAD").write_text(self.head + "\n")
        self.assert_rejected_without_changes("Finish the current merge")
        self.assertEqual(self.remote_calls, [])

    def test_symlink_notes_are_rejected(self):
        self.notes.unlink()
        self.notes.symlink_to(self.root / "README.md")
        self.assert_rejected_without_changes("regular file")

    def test_changed_head_during_remote_check_does_not_get_a_preparation_commit(self):
        def concurrent_commit():
            (self.root / "README.md").write_text("Concurrent edit\n")
            self.git("add", "README.md")
            self.git("commit", "-m", "Concurrent commit")
        self.during_remote = concurrent_commit
        with self.assertRaisesRegex(ValueError, "changed during validation"):
            prepare.run(self.args())
        self.assertEqual(self.manifest.read_bytes(), MANIFEST)
        self.assertEqual(self.git("log", "-1", "--format=%s"), "Concurrent commit")
        self.assertEqual(self.git("diff", "--cached"), "")

    def test_failed_commit_leaves_release_edits_and_unrelated_staging_for_inspection(self):
        (self.root / "README.md").write_text("Staged edit\n")
        self.git("add", "README.md")
        staged = self.git("diff", "--cached", "--", "README.md")
        hook = self.root / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o700)
        with self.assertRaisesRegex(RuntimeError, "finish the commit manually"):
            prepare.run(self.args())
        self.assertEqual(self.git("rev-parse", "HEAD"), self.head)
        self.assertEqual(self.manifest.read_bytes(), MANIFEST.replace(b'"1.2.2"', b'"1.2.3"'))
        self.assertEqual(self.git("diff", "--cached", "--", "README.md"), staged)
        self.assertIn(self.notes_relative, self.git("diff", "--cached", "--name-only").splitlines())
        self.assertEqual(self.git("tag", "--list"), "")

    def test_repeating_successful_preparation_does_not_make_another_commit(self):
        prepare.run(self.args())
        self.assert_rejected_without_changes("must be newer")
        self.assertEqual(len(self.remote_calls), 1)


if __name__ == "__main__":
    unittest.main()
