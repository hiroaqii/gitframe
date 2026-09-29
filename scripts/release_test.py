"""Checks for release failures that must prevent publishing incorrect assets."""

import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "build.zig.zon").write_text('.{ .version = "0.1.0" }')

    def archives(self, tag="v0.1.0"):
        for platform in release.PLATFORMS:
            archive = self.root / f"gitframe-{tag}-{platform}.tar.gz"
            archive.write_bytes(platform.encode())
            archive.with_name(archive.name + ".sha256").write_text(
                f"{release.sha256(archive)}  {archive.name}\n"
            )

    def test_tag_must_match_manifest(self):
        self.assertEqual(release.validate_tag("v0.1.0", self.root), "v0.1.0")
        for tag in ("v0.2.0", "0.1.0", "v0.1.0-rc.1", "v0.1.0\nanything"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag, self.root)

    def test_rejects_incorrect_binary_architecture(self):
        binary = self.root / "gitframe"
        header = bytearray(32)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", header, 18, 62)
        binary.write_bytes(header)
        release.check_binary(binary, "linux-x86_64")
        with self.assertRaises(ValueError):
            release.check_binary(binary, "macos-arm64")
        header[:4] = b"\xcf\xfa\xed\xfe"
        struct.pack_into("<I", header, 4, 0x0100000C)
        binary.write_bytes(header)
        release.check_binary(binary, "macos-arm64")
        with self.assertRaises(ValueError):
            release.check_binary(binary, "linux-x86_64")

    def test_checksums_require_both_platforms_and_unchanged_bytes(self):
        self.archives()
        release.checksums(self.root, "v0.1.0")
        self.assertEqual(len((self.root / "SHA256SUMS").read_text().splitlines()), 2)
        linux = self.root / "gitframe-v0.1.0-linux-x86_64.tar.gz"
        linux.write_bytes(b"changed after packaging")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            release.checksums(self.root, "v0.1.0")
        linux.unlink()
        with self.assertRaisesRegex(ValueError, "expected exactly"):
            release.checksums(self.root, "v0.1.0")

    def test_extra_archives_are_rejected(self):
        self.archives()
        (self.root / "gitframe-v0.0.9-linux-x86_64.tar.gz").write_bytes(b"stale")
        with self.assertRaisesRegex(ValueError, "expected exactly"):
            release.checksums(self.root, "v0.1.0")

    def test_archive_preserves_executable_mode_and_normalizes_metadata(self):
        stage = self.root / "gitframe-v0.1.0-linux-x86_64"
        stage.mkdir()
        (stage / "gitframe").write_bytes(b"binary")
        (stage / "LICENSE").write_text("license")
        first, second = self.root / "first.tar.gz", self.root / "second.tar.gz"
        release.make_archive(stage, first, 1234567890)
        release.make_archive(stage, second, 1234567890)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with tarfile.open(first) as bundle:
            self.assertEqual(bundle.getmember(f"{stage.name}/gitframe").mode, 0o755)
            self.assertEqual(bundle.getmember(f"{stage.name}/LICENSE").mode, 0o644)
            self.assertTrue(all(member.mtime == 1234567890 for member in bundle.getmembers()))

    def publish_fixture(self, tag="v0.1.0"):
        (self.root / "build.zig.zon").write_text(f'.{{ .version = "{tag[1:]}" }}')
        self.archives(tag)
        release.checksums(self.root, tag)
        notes = self.root / ".github/release-notes" / f"{tag}.md"
        notes.parent.mkdir(parents=True)
        notes.write_text(f"Release {tag}\n\n- Handle `quoted` text & 日本語.\n", encoding="utf-8")
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("release.py", "publish-release.sh"):
            shutil.copyfile(release.ROOT / "scripts" / name, scripts / name)
        executable_dir = self.root / "bin"
        executable_dir.mkdir()
        gh = executable_dir / "gh"
        gh.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
with Path(os.environ["FAKE_GH_LOG"]).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
command = sys.argv[2]
if command == "view":
    state = os.environ["FAKE_GH_STATE"]
    if state == "missing":
        sys.exit(1)
    print("true" if state == "draft" else "false")
if command == "upload" and os.environ.get("FAKE_GH_FAIL_UPLOAD") == "1":
    sys.exit(1)
if "--notes-file" in sys.argv:
    notes = Path(sys.argv[sys.argv.index("--notes-file") + 1])
    Path(os.environ["FAKE_GH_NOTES"]).write_bytes(notes.read_bytes())
''')
        gh.chmod(0o755)
        return {**os.environ, "PATH": f"{executable_dir}{os.pathsep}{os.environ['PATH']}",
                "FAKE_GH_LOG": str(self.root / "gh.log"), "FAKE_GH_STATE": "missing",
                "FAKE_GH_NOTES": str(self.root / "published-notes.md")}

    def gh_calls(self):
        log = self.root / "gh.log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def run_publish(self, env, tag="v0.1.0"):
        result = subprocess.run(["bash", "scripts/publish-release.sh", tag, str(self.root)],
                                cwd=self.root, env=env, capture_output=True, text=True)
        commands = [args[1] for args in self.gh_calls()]
        return result, commands

    def assert_published_notes(self, tag):
        notes = self.root / ".github/release-notes" / f"{tag}.md"
        self.assertEqual((self.root / "published-notes.md").read_bytes(), notes.read_bytes())
        for args in self.gh_calls():
            self.assertNotIn("--generate-notes", args)
            if args[1] in ("create", "edit"):
                self.assertIn("--notes-file", args)
                self.assertEqual(Path(args[args.index("--notes-file") + 1]), notes)

    def test_publish_uploads_everything_before_making_release_public(self):
        result, commands = self.run_publish(self.publish_fixture())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, ["view", "create", "upload", "edit"])
        self.assert_published_notes("v0.1.0")

    def test_later_release_uses_its_own_notes(self):
        env = self.publish_fixture("v0.1.1")
        (self.root / ".github/release-notes/v0.1.0.md").write_text("Old release notes")
        result, _ = self.run_publish(env, "v0.1.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_published_notes("v0.1.1")

    def test_missing_or_blank_notes_stop_before_github_calls(self):
        env = self.publish_fixture()
        notes = self.root / ".github/release-notes/v0.1.0.md"
        (notes.parent / "v0.0.9.md").write_text("Old release notes must not be reused")
        for content in (None, "", " \n\t"):
            with self.subTest(content=content):
                if content is None:
                    notes.unlink()
                else:
                    notes.write_text(content)
                result, commands = self.run_publish(env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("release notes", result.stderr)
                self.assertIn("v0.1.0.md", result.stderr)
                self.assertEqual(commands, [])

    def test_failed_upload_keeps_release_draft(self):
        env = self.publish_fixture()
        env["FAKE_GH_FAIL_UPLOAD"] = "1"
        result, commands = self.run_publish(env)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("edit", commands)

    def test_retry_resumes_draft_without_replacing_published_release(self):
        env = self.publish_fixture()
        env["FAKE_GH_STATE"] = "draft"
        result, commands = self.run_publish(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, ["view", "upload", "edit"])
        self.assert_published_notes("v0.1.0")
        (self.root / "gh.log").unlink()
        env["FAKE_GH_STATE"] = "published"
        result, commands = self.run_publish(env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, ["view"])


if __name__ == "__main__":
    unittest.main()
