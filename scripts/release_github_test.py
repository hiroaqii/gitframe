"""Release orchestration tests: no real GitHub writes or workflow dispatches."""

import argparse
import contextlib
import copy
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("release_github", Path(__file__).with_name("release-github.py"))
github = importlib.util.module_from_spec(spec)
spec.loader.exec_module(github)
SHA = "a" * 40
OTHER_SHA = "b" * 40
TAG = "v1.2.3"


def published_release():
    assets = [{"name": f"gitframe-{TAG}-{platform}.tar.gz", "id": index, "size": 10,
               "state": "uploaded", "digest": "sha256:" + str(index) * 64}
              for index, platform in enumerate(github.release.PLATFORMS, 1)]
    checksums = "".join(f"{asset['digest'][7:]}  {asset['name']}\n" for asset in assets)
    assets.append({"name": "SHA256SUMS", "id": 3, "size": len(checksums), "state": "uploaded"})
    return {"tag_name": TAG, "draft": False, "prerelease": False, "assets": assets,
            "html_url": f"https://github.com/{github.REPO}/releases/tag/{TAG}"}, checksums


def workflow(event="workflow_dispatch", ref="main", **changes):
    result = {"id": 123, "head_sha": SHA, "event": event, "head_branch": ref, "run_attempt": 1,
              "status": "completed", "conclusion": "success", "html_url": "https://github.com/run/123"}
    result.update(changes)
    return result


class GitHubReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "build.zig.zon").write_text('.{ .version = "1.2.3" }')
        (self.root / ".github/release-notes").mkdir(parents=True)
        (self.root / f".github/release-notes/{TAG}.md").write_text("Release notes\n")
        root_patch = patch.object(github, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)

    def args(self, **changes):
        result = argparse.Namespace(branch="main", timeout=30, retry_failed=False, dry_run=False, preflight=False)
        for key, value in changes.items():
            setattr(result, key, value)
        return result

    def test_conflicting_local_and_remote_tags_are_never_replaced(self):
        for local, remote in ((OTHER_SHA, None), (SHA, OTHER_SHA)):
            with self.subTest(local=local, remote=remote), \
                    patch.object(github, "command", return_value=subprocess.CompletedProcess([], 0, local + "\n", "")) as cmd, \
                    patch.object(github, "remote_commit", return_value=remote):
                with self.assertRaisesRegex(ValueError, "another commit"):
                    github.check_tag(TAG, SHA)
                self.assertEqual(len(cmd.call_args_list), 1)

    def test_annotated_remote_tag_is_peeled(self):
        with patch.object(github, "api", side_effect=[
            {"object": {"type": "tag", "sha": OTHER_SHA}},
            {"object": {"type": "commit", "sha": SHA}},
        ]):
            self.assertEqual(github.remote_commit(f"tags/{TAG}"), SHA)

    def test_only_404_is_treated_as_absent(self):
        for code in (401, 403, 500):
            with self.subTest(code=code), patch.object(github.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 1, "", f"gh: failed (HTTP {code})")):
                with self.assertRaises(RuntimeError):
                    github.api("releases/tags/missing", missing_ok=True)
        with patch.object(github.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")):
            self.assertIsNone(github.api("releases/tags/missing", missing_ok=True))

    def test_run_selection_rejects_other_commits_events_and_refs(self):
        candidates = [workflow(), workflow(id=124, head_sha=OTHER_SHA), workflow(id=125, event="push"),
                      workflow(id=126, head_branch="other"), workflow(id=127)]
        with patch.object(github, "api", return_value={"workflow_runs": candidates}):
            self.assertEqual(github.find_run("workflow_dispatch", SHA, "main")["id"], 127)

    def test_success_requires_both_platform_jobs(self):
        for names in (github.BUILD_JOBS, github.BUILD_JOBS - {"Build macos-arm64"}):
            with self.subTest(names=names), patch.object(github, "find_run", return_value=workflow()), \
                    patch.object(github, "api", side_effect=[workflow(), {"jobs": [
                        {"name": name, "conclusion": "success"} for name in names]}]):
                if names == github.BUILD_JOBS:
                    github.wait_for_run("workflow_dispatch", SHA, "main", 30)
                else:
                    with self.assertRaisesRegex(ValueError, "Build macos-arm64"):
                        github.wait_for_run("workflow_dispatch", SHA, "main", 30)

    def test_failed_optional_preflight_stops_without_creating_tag(self):
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "api", return_value=None), \
                patch.object(github, "remote_commit", return_value=SHA), \
                patch.object(github, "wait_for_run", side_effect=RuntimeError("macOS failed")), \
                patch.object(github, "command") as cmd:
            with self.assertRaisesRegex(RuntimeError, "macOS failed"):
                github.run(self.args(preflight=True))
            cmd.assert_not_called()

    def test_branch_moving_before_tagging_stops_tag_creation(self):
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "api", return_value=None), \
                patch.object(github, "remote_commit", side_effect=[SHA, OTHER_SHA]), \
                patch.object(github, "wait_for_run"), patch.object(github, "command") as cmd:
            with self.assertRaisesRegex(ValueError, "changed before tagging"):
                github.run(self.args())
            cmd.assert_not_called()

    def test_unpushed_commit_stops_before_dispatch(self):
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "api", return_value=None), \
                patch.object(github, "remote_commit", return_value=OTHER_SHA), \
                patch.object(github, "wait_for_run") as wait:
            with self.assertRaisesRegex(ValueError, "Push this commit"):
                github.run(self.args())
            wait.assert_not_called()

    def test_default_release_only_waits_for_tag_workflow_and_tags_selected_commit(self):
        value, sums = published_release()
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "api", side_effect=[None, value, sums]), \
                patch.object(github, "remote_commit", return_value=SHA), \
                patch.object(github, "wait_for_run") as wait, patch.object(github, "command") as cmd:
            github.run(self.args())
            self.assertIn(unittest.mock.call("git", "tag", "-a", TAG, SHA, "-m", f"GitFrame {TAG}"), cmd.call_args_list)
            self.assertEqual(len(cmd.call_args_list), 2)
            wait.assert_called_once_with("push", SHA, TAG, 30, False)

    def test_optional_preflight_runs_before_tagging(self):
        value, sums = published_release()
        actions = []
        def wait(event, *args, **kwargs):
            actions.append(event)
        def command(*args, **kwargs):
            actions.append("tag" if args[:3] == ("git", "tag", "-a") else "push-tag")
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "api", side_effect=[None, value, sums]), \
                patch.object(github, "remote_commit", return_value=SHA), \
                patch.object(github, "wait_for_run", side_effect=wait), \
                patch.object(github, "command", side_effect=command):
            github.run(self.args(preflight=True))
        self.assertEqual(actions, ["workflow_dispatch", "tag", "push-tag", "push"])

    def test_default_release_failure_is_not_reported_as_published(self):
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "api", return_value=None), \
                patch.object(github, "remote_commit", return_value=SHA), \
                patch.object(github, "wait_for_run", side_effect=RuntimeError("macOS failed")) as wait, \
                patch.object(github, "command") as cmd, patch.object(github, "verify_release") as verify:
            with self.assertRaisesRegex(RuntimeError, "macOS failed"):
                github.run(self.args())
            wait.assert_called_once_with("push", SHA, TAG, 30, False)
            self.assertEqual(len(cmd.call_args_list), 2)
            verify.assert_not_called()

    def test_existing_remote_tag_resumes_without_dispatch_or_push(self):
        value, sums = published_release()
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(True, True)), \
                patch.object(github, "api", side_effect=[None, value, sums]), \
                patch.object(github, "remote_commit", return_value=SHA), \
                patch.object(github, "wait_for_run") as wait, patch.object(github, "command") as cmd:
            github.run(self.args(preflight=True))
            cmd.assert_not_called()
            wait.assert_called_once_with("push", SHA, TAG, 30, False)

    def test_published_release_is_verified_without_new_writes(self):
        value, sums = published_release()
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(False, True)), \
                patch.object(github, "api", side_effect=[value, sums]) as api, \
                patch.object(github, "wait_for_run") as wait, patch.object(github, "command") as cmd:
            github.run(self.args())
            self.assertTrue(all("data" not in call.kwargs for call in api.call_args_list))
            wait.assert_not_called()
            cmd.assert_not_called()

    def test_dry_run_does_not_dispatch_or_tag(self):
        with patch.object(github, "require_checkout", return_value=SHA), \
                patch.object(github, "release_tag_at", return_value=TAG), \
                patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "api", return_value=None) as api, \
                patch.object(github, "remote_commit", return_value=SHA), \
                patch.object(github, "wait_for_run") as wait, patch.object(github, "command") as cmd:
            github.run(self.args(dry_run=True))
            wait.assert_not_called()
            cmd.assert_not_called()
            self.assertTrue(all("data" not in call.kwargs for call in api.call_args_list))

    def test_dry_run_distinguishes_default_and_optional_preflight(self):
        for preflight, message in ((False, "one Release workflow"), (True, "preflight validation")):
            with self.subTest(preflight=preflight), \
                    patch.object(github, "require_checkout", return_value=SHA), \
                    patch.object(github, "release_tag_at", return_value=TAG), \
                    patch.object(github, "check_tag", return_value=(False, False)), \
                    patch.object(github, "api", return_value=None), \
                    patch.object(github, "remote_commit", return_value=SHA), \
                    patch.object(github, "wait_for_run") as wait, patch.object(github, "command") as cmd, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                github.run(self.args(dry_run=True, preflight=preflight))
                self.assertIn(message, output.getvalue())
                wait.assert_not_called()
                cmd.assert_not_called()

    def test_cli_defaults_to_one_run_and_accepts_preflight(self):
        for options, expected in (([], False), (["--preflight"], True)):
            with self.subTest(options=options), patch("sys.argv", ["release-github.py", *options]), \
                    patch.object(github, "run") as run:
                github.main()
                self.assertEqual(run.call_args.args[0].preflight, expected)

    def test_asset_validation_rejects_incomplete_or_mismatched_releases(self):
        original, sums = published_release()
        invalid = []
        for field in ("draft", "prerelease"):
            value = copy.deepcopy(original)
            value[field] = True
            invalid.append(value)
        value = copy.deepcopy(original)
        value["assets"].pop(0)
        invalid.append(value)
        value = copy.deepcopy(original)
        value["assets"][0]["digest"] = "sha256:" + "f" * 64
        invalid.append(value)
        for value in invalid:
            with self.subTest(value=value), patch.object(github, "api", return_value=sums):
                with self.assertRaises(ValueError):
                    github.verify_release(value, TAG)
        with patch.object(github, "api", return_value=sums + sums):
            with self.assertRaisesRegex(ValueError, "duplicate"):
                github.verify_release(original, TAG)

    def test_retry_waits_for_the_new_attempt(self):
        failed = workflow(conclusion="failure")
        success = workflow(run_attempt=2)
        jobs = {"jobs": [{"name": name, "conclusion": "success"} for name in github.BUILD_JOBS]}
        with patch.object(github, "find_run", return_value=failed), \
                patch.object(github, "api", side_effect=[None, failed, success, jobs]) as api, \
                patch.object(github.time, "sleep"):
            github.wait_for_run("workflow_dispatch", SHA, "main", 30, retry_failed=True)
            self.assertEqual(api.call_args_list[0], unittest.mock.call("actions/runs/123/rerun", data={}))

    def test_dispatch_and_wait_use_the_selected_branch_and_commit(self):
        jobs = {"jobs": [{"name": name, "conclusion": "success"} for name in github.BUILD_JOBS]}
        with patch.object(github, "find_run", side_effect=[None, workflow()]), \
                patch.object(github, "remote_commit", return_value=SHA), \
                patch.object(github, "api", side_effect=[None, workflow(), jobs]) as api, \
                patch.object(github.time, "sleep"):
            github.wait_for_run("workflow_dispatch", SHA, "main", 30, dispatch=True)
            self.assertEqual(api.call_args_list[0], unittest.mock.call("actions/workflows/release.yml/dispatches", data={"ref": "main"}))

    def test_tag_workflow_requires_a_successful_publish_job(self):
        run = workflow(event="push", ref=TAG)
        jobs = {"jobs": [{"name": name, "conclusion": "success"} for name in github.BUILD_JOBS]}
        jobs["jobs"].append({"name": "publish", "conclusion": "skipped"})
        with patch.object(github, "find_run", return_value=run), patch.object(github, "api", side_effect=[run, jobs]):
            with self.assertRaisesRegex(ValueError, "publish"):
                github.wait_for_run("push", SHA, TAG, 30)

    def test_wait_timeout_never_claims_success(self):
        pending = workflow(status="queued", conclusion=None)
        with patch.object(github, "find_run", return_value=pending), \
                patch.object(github, "api", return_value=pending), \
                patch.object(github.time, "monotonic", side_effect=[0, 0, 31]):
            with self.assertRaises(TimeoutError):
                github.wait_for_run("workflow_dispatch", SHA, "main", 30)


class CommittedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        root_patch = patch.object(github, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        self.git("init", "--initial-branch=main")
        self.git("remote", "add", "origin", f"https://github.com/{github.REPO}.git")
        (self.root / "build.zig.zon").write_text('.{ .version = "1.2.3" }')
        self.notes = self.root / f".github/release-notes/{TAG}.md"
        self.notes.parent.mkdir(parents=True)
        self.notes.write_text("Committed release notes\n")
        (self.root / "source.zig").write_text("// Committed source\n")
        self.git("add", ".")
        self.commit()
        self.sha = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return github.command("git", *args).stdout.strip()

    def commit(self):
        self.git("-c", "user.name=Release Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-m", "Fixture")

    def args(self):
        return argparse.Namespace(branch="main", timeout=30, retry_failed=False, dry_run=True, preflight=False)

    def test_dry_run_accepts_local_script_and_ignores_staged_and_worktree_metadata(self):
        (self.root / "scripts").mkdir()
        (self.root / "scripts/release-github.py").write_text("# Local operation script\n")
        (self.root / "build.zig.zon").write_text('.{ .version = "9.9.9" }')
        self.git("add", "build.zig.zon")
        self.notes.unlink()
        (self.root / "source.zig").write_text("// Local source edit\n")
        before = self.git("status", "--porcelain")
        def remote(ref):
            return self.sha if ref == "heads/main" else None
        with patch.object(github, "remote_commit", side_effect=remote), \
                patch.object(github, "api", return_value=None) as api, \
                patch.object(github, "wait_for_run") as wait:
            github.run(self.args())
            api.assert_called_once_with(f"releases/tags/{TAG}", missing_ok=True)
            wait.assert_not_called()
        self.assertEqual(self.git("status", "--porcelain"), before)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.sha)

    def test_local_notes_do_not_replace_missing_committed_notes(self):
        self.git("rm", "--cached", str(self.notes.relative_to(self.root)))
        self.commit()
        with patch.object(github, "api") as api:
            with self.assertRaisesRegex(ValueError, "committed release notes"):
                github.run(self.args())
            api.assert_not_called()
        self.assertTrue(self.notes.is_file())

    def test_local_notes_do_not_replace_blank_committed_notes(self):
        self.notes.write_text(" \n\t")
        self.git("add", ".")
        self.commit()
        self.notes.write_text("Local notes are ready\n")
        with self.assertRaisesRegex(ValueError, "empty release notes"):
            github.release_tag_at(self.git("rev-parse", "HEAD"))

    def test_uncommitted_edits_during_validation_do_not_block_fixed_commit(self):
        (self.root / "scripts").mkdir()
        (self.root / "scripts/release-github.py").write_text("# Untracked operation script\n")
        args = self.args()
        args.dry_run = False
        args.preflight = True
        def wait(event, sha, ref, *unused, **kwargs):
            self.assertEqual(sha, self.sha)
            (self.root / "source.zig").write_text("// Edited while Actions was running\n")
        real_command = github.command
        writes = []
        def command(*args, **kwargs):
            if args[:3] == ("git", "tag", "-a") or "push" in args:
                writes.append(args)
                return subprocess.CompletedProcess(args, 0, "", "")
            return real_command(*args, **kwargs)
        value, _ = published_release()
        with patch.object(github, "api", side_effect=[None, value]), \
                patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "remote_commit", return_value=self.sha), \
                patch.object(github, "wait_for_run", side_effect=wait), \
                patch.object(github, "verify_release") as verify, \
                patch.object(github, "command", side_effect=command):
            github.run(args)
            verify.assert_called_once_with(value, TAG)
        self.assertEqual(writes[0], ("git", "tag", "-a", TAG, self.sha, "-m", f"GitFrame {TAG}"))
        self.assertEqual(len(writes), 2)
        self.assertIn("Edited while Actions", (self.root / "source.zig").read_text())

    def test_new_local_commit_during_validation_still_stops_publication(self):
        args = self.args()
        args.dry_run = False
        args.preflight = True
        def wait(*unused, **kwargs):
            (self.root / "source.zig").write_text("// New commit\n")
            self.git("add", "source.zig")
            self.commit()
        with patch.object(github, "check_tag", return_value=(False, False)), \
                patch.object(github, "api", return_value=None), \
                patch.object(github, "remote_commit", return_value=self.sha), \
                patch.object(github, "wait_for_run", side_effect=wait):
            with self.assertRaisesRegex(ValueError, "changed before tagging"):
                github.run(args)
        self.assertEqual(self.git("tag", "--list"), "")


if __name__ == "__main__":
    unittest.main()
