import ast
import base64
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "scripts" / "review.py"
SPEC = importlib.util.spec_from_file_location("review", DRIVER)
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)

FAKE = r'''#!/usr/bin/env python3
import base64,binascii,hashlib,json,os,sys,uuid
def enc(v): return (json.dumps(v,separators=(",",":"))+"\n").encode()
def sha(v): return "sha256:"+hashlib.sha256(v).hexdigest()
def log(name):
 p=os.environ["FAKE_LOG"]
 with open(p,"a",encoding="utf-8") as f: f.write(name+"\n")
cmd=sys.argv[1:]; name=" ".join(cmd[:2]) if cmd[:1]==["review-producer"] else cmd[0]; log(name)
target={"object_format":"sha1","source_kind":"branch_range","base_oid":"1"*40,"head_oid":"2"*40,"diff_base_oid":"1"*40}
if name=="review-capabilities":
 names=["ai-review.input","ai-review.producer","committed-review.artifact","committed-review.instructions","committed-review.projection","committed-review.target","review-store.prepare","review-store.publish"]
 sys.stdout.buffer.write(enc({"schema_version":1,"status":"ok","gitframe_version":"0.0.0-test","capabilities":[{"name":n,"versions":[1]} for n in names]}))
elif name=="review-target": sys.stdout.buffer.write(enc({"schema_version":1,"status":"ok","target":target}))
elif name=="review-projection":
 patch=b"" if os.environ.get("FAKE_EMPTY")=="1" else b"diff"
 sys.stdout.buffer.write(enc({"schema_version":1,"status":"ok","target":target,"patch_size":len(patch)})+patch)
elif name=="review-input":
 empty=os.environ.get("FAKE_EMPTY")=="1"
 summary={"unit_count":0 if empty else 1}
 units=[] if empty else [{"unit_id":{"ordinal":1},"ordinal":1,"unit_count":1}]
 sys.stdout.buffer.write(enc({"schema_version":1,"status":"ok","summary":summary,"units":units}))
elif name=="review-store-prepare":
 sys.stdout.buffer.write(enc({"status":"ok","schema_version":1,"review_repository_id":"223e4567-e89b-42d3-a456-426614174000","review_id":str(uuid.uuid4())}))
elif name=="review-producer artifacts":
 data=sys.stdin.buffer.read(); header=json.loads(data.split(b"\n",1)[0]); manifest=b'{"artifact":"manifest"}\n'; findings=b'{"artifact":"findings"}\n'
 out={"schema_version":1,"status":"ok","review_repository_id":header["review_repository_id"],"review_id":header["review_id"],"target":target,"producer":header["producer"],"created_at":"2026-08-27T00:00:00Z","finding_count":0,"manifest_sha256":sha(manifest),"findings_sha256":sha(findings),"manifest_size":len(manifest),"findings_size":len(findings)}
 sys.stdout.buffer.write(enc(out)+manifest+findings)
elif name=="review-store-publish":
 data=sys.stdin.buffer.read(); header=json.loads(data.split(b"\n",1)[0]); path=os.path.join(os.environ["FAKE_STORE"],header["review_id"])
 try:
  fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,"wb") as f: f.write(data)
 except FileExistsError:
  sys.stdout.buffer.write(enc({"status":"error","schema_version":1,"code":"review_exists","message":"review already exists"})); sys.exit(73)
 if os.environ.get("FAKE_UNKNOWN")=="1": sys.stdout.buffer.write(b"not-json")
 else: sys.stdout.buffer.write(enc({"status":"ok","schema_version":1,"review_repository_id":header["review_repository_id"],"review_id":header["review_id"]}))
elif name=="review-store-read":
 try:
  request=json.loads(sys.stdin.buffer.read()); value=request["repository"]["path_bytes_b64"]
  raw=base64.b64decode(value.encode("ascii"),validate=True)
  expected_keys=["review_repository_id","target","producer","created_at","finding_count","manifest_sha256","findings_sha256"]
  if list(request)!=["schema_version","repository","review_id","expected"] or list(request["repository"])!=["path_bytes_b64"]: raise ValueError("shape")
  if list(request["expected"])!=expected_keys or base64.b64encode(raw).decode("ascii")!=value: raise ValueError("noncanonical")
  if raw!=os.fsencode(os.environ["FAKE_REPOSITORY"]): raise ValueError("repository")
  if request["schema_version"]!=1 or not os.path.isfile(os.path.join(os.environ["FAKE_STORE"],request["review_id"])): raise ValueError("absent")
  sys.stdout.buffer.write(enc({"status":"ok","schema_version":1,"review_id":request["review_id"],"lifecycle":"published","expected":request["expected"]}))
 except (binascii.Error,KeyError,TypeError,ValueError):
  sys.stdout.buffer.write(enc({"status":"error","schema_version":1,"code":"invalid_request","message":"invalid request"})); sys.exit(64)
'''


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repository = self.root / "repo"
        self.repository.mkdir()
        self.fake = self.root / "gitframe"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o700)
        self.log = self.root / "events"
        self.store = self.root / "store"
        self.store.mkdir()
        self.environment = dict(os.environ, FAKE_LOG=str(self.log), FAKE_STORE=str(self.store),
            FAKE_REPOSITORY=str(self.repository))

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, *arguments, extra=None):
        environment = dict(self.environment)
        environment.update(extra or {})
        completed = subprocess.run([sys.executable, "-I", str(DRIVER), *arguments],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, check=False)
        return completed, json.loads(completed.stdout)

    def start(self, extra=None):
        return self.invoke("begin", "--gitframe", str(self.fake), "--repository",
            str(self.repository), "--base", "main", extra=extra)

    def candidate(self, handoff):
        path = Path(handoff["workspace"]) / "candidate-0001.json"
        path.write_bytes(b'{"findings":[]}\n')
        path.chmod(0o600)

    def events(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_argument_failures_are_one_canonical_json_terminal_without_children(self):
        cases = [
            (),
            ("begin", "--gitframe", str(self.fake)),
            ("complete", "--workspace", "/nonexistent"),
            ("begin", "--gitframe", str(self.fake), "--repository", str(self.repository),
                "--base", "main", "--unknown"),
            ("--help",),
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                completed, result = self.invoke(*arguments)
                expected = {"status": "error", "schema_version": 1,
                    "code": "invalid_arguments", "message": "review driver arguments are invalid"}
                self.assertEqual((completed.returncode, completed.stderr, result), (1, b"", expected))
                self.assertEqual(completed.stdout, review.encoded(expected))
                self.assertEqual(self.events(), [])

    def test_normal_lifecycle_publishes_once_and_cleans(self):
        started, handoff = self.start()
        self.assertEqual((started.returncode, handoff["status"]), (0, "ready"))
        workspace = Path(handoff["workspace"])
        self.candidate(handoff)
        finished, result = self.invoke("complete", "--workspace", str(workspace),
            "--workspace-nonce", handoff["workspace_nonce"])
        self.assertEqual((finished.returncode, result["status"]), (0, "ok"))
        self.assertFalse(workspace.exists())
        self.assertEqual(self.events().count("review-producer artifacts"), 1)
        self.assertEqual(self.events().count("review-store-publish"), 1)

    def test_empty_plan_never_prepares_or_publishes(self):
        completed, result = self.start({"FAKE_EMPTY": "1"})
        self.assertEqual((completed.returncode, result["status"]), (0, "no_changes"))
        self.assertNotIn("review-store-prepare", self.events())
        self.assertNotIn("review-store-publish", self.events())

    def test_missing_candidate_is_prepublish_failure(self):
        _, handoff = self.start()
        workspace = Path(handoff["workspace"])
        completed, result = self.invoke("complete", "--workspace", handoff["workspace"],
            "--workspace-nonce", handoff["workspace_nonce"])
        self.assertEqual((completed.returncode, result["status"]), (1, "error"))
        self.assertFalse(workspace.exists())
        self.assertNotIn("review-producer artifacts", self.events())
        self.assertNotIn("review-store-publish", self.events())

    def test_extra_candidate_is_rejected_and_cleaned_before_artifacts(self):
        _, handoff = self.start()
        workspace = Path(handoff["workspace"])
        self.candidate(handoff)
        extra = workspace / "candidate-0002.json"
        extra.write_bytes(b'{"findings":[]}\n')
        extra.chmod(0o600)
        completed, result = self.invoke("complete", "--workspace", str(workspace),
            "--workspace-nonce", handoff["workspace_nonce"])
        self.assertEqual((completed.returncode, result["code"]), (1, "invalid_candidate_inventory"))
        self.assertFalse(workspace.exists())
        self.assertNotIn("review-producer artifacts", self.events())
        self.assertNotIn("review-store-publish", self.events())

    def test_candidate_aggregate_limit_stops_before_artifacts_and_cleans(self):
        begin_args = types.SimpleNamespace(gitframe=str(self.fake), repository=str(self.repository),
            base="main", head=None)
        with mock.patch.dict(os.environ, self.environment, clear=False):
            handoff = review.begin(begin_args)
            self.addCleanup(shutil.rmtree, handoff["workspace"], ignore_errors=True)
            self.candidate(handoff)
            with mock.patch.object(review, "MAX_CANDIDATES", 1):
                result = review.complete(types.SimpleNamespace(workspace=handoff["workspace"],
                    workspace_nonce=handoff["workspace_nonce"]))
        self.assertEqual((result["status"], result["code"]), ("error", "invalid_candidate"))
        self.assertFalse(Path(handoff["workspace"]).exists())
        self.assertNotIn("review-producer artifacts", self.events())
        self.assertNotIn("review-store-publish", self.events())

    def test_uppercase_nonce_is_not_an_admitted_complete(self):
        _, handoff = self.start()
        workspace = Path(handoff["workspace"])
        self.addCleanup(shutil.rmtree, workspace, ignore_errors=True)
        self.candidate(handoff)
        completed, result = self.invoke("complete", "--workspace", str(workspace),
            "--workspace-nonce", handoff["workspace_nonce"].upper())
        self.assertEqual((completed.returncode, result["code"]), (1, "invalid_handoff"))
        self.assertTrue(workspace.is_dir())
        self.assertNotIn("review-producer artifacts", self.events())
        self.assertNotIn("review-store-publish", self.events())

    def test_malformed_publish_terminal_is_unknown_without_retry(self):
        _, handoff = self.start()
        self.candidate(handoff)
        completed, result = self.invoke("complete", "--workspace", handoff["workspace"],
            "--workspace-nonce", handoff["workspace_nonce"], extra={"FAKE_UNKNOWN": "1"})
        self.assertEqual((completed.returncode, result["status"]), (1, "outcome_unknown"))
        self.assertEqual(result["review_id"], handoff["review_id"])
        self.assertIn("expected", result)
        self.assertEqual(review.repository_read_wire("/repo"), {"path_bytes_b64": "L3JlcG8="})
        encoded_repository = result["repository"]["path_bytes_b64"]
        self.assertEqual(base64.b64encode(base64.b64decode(encoded_repository, validate=True)).decode(),
            encoded_repository)
        self.assertEqual(base64.b64decode(encoded_repository, validate=True), os.fsencode(self.repository))
        request = {"schema_version": 1, "repository": result["repository"],
            "review_id": result["review_id"], "expected": result["expected"]}
        read = subprocess.run([str(self.fake), "review-store-read"], input=review.encoded(request),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.environment, check=False)
        self.assertEqual((read.returncode, json.loads(read.stdout)["lifecycle"]), (0, "published"))
        wrong_request = dict(request, repository=review.repository_wire(str(self.repository)))
        rejected = subprocess.run([str(self.fake), "review-store-read"],
            input=review.encoded(wrong_request), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=self.environment, check=False)
        self.assertEqual((rejected.returncode, json.loads(rejected.stdout)["code"]),
            (64, "invalid_request"))
        self.assertEqual(self.events().count("review-store-publish"), 1)
        self.assertEqual(self.events().count("review-store-read"), 2)
        self.assertFalse(Path(handoff["workspace"]).exists())
        self.assertTrue((self.store / handoff["review_id"]).is_file())

    def test_closed_child_pipes_do_not_disable_timeout(self):
        command = [sys.executable, "-I", "-c",
            "import os,time;os.close(1);os.close(2);time.sleep(30)"]
        started = time.monotonic()
        result = review.run(command, b"", 0.1, 64)
        self.assertTrue(result["timeout"])
        self.assertLess(time.monotonic() - started, 2)

    def test_cleanup_residue_preserves_terminal_and_next_begin_is_fresh(self):
        begin_args = types.SimpleNamespace(gitframe=str(self.fake), repository=str(self.repository),
            base="main", head=None)
        with mock.patch.dict(os.environ, self.environment, clear=False):
            first = review.begin(begin_args)
            self.addCleanup(shutil.rmtree, first["workspace"], ignore_errors=True)
            self.candidate(first)
            residue = {"status": "residue", "message": "private workspace cleanup failed"}
            with mock.patch.object(review, "remove_workspace", return_value=residue):
                result = review.complete(types.SimpleNamespace(workspace=first["workspace"],
                    workspace_nonce=first["workspace_nonce"]))
            second = review.begin(begin_args)
            self.addCleanup(shutil.rmtree, second["workspace"], ignore_errors=True)
        self.assertEqual((result["status"], result["cleanup"]), ("ok", residue))
        self.assertTrue(Path(first["workspace"]).is_dir())
        self.assertNotEqual(first["review_id"], second["review_id"])
        self.assertNotEqual(first["workspace"], second["workspace"])

    def test_same_id_duplicate_is_rejected_without_changing_stored_bytes(self):
        _, handoff = self.start()
        workspace = Path(handoff["workspace"])
        self.candidate(handoff)
        duplicate = workspace.with_name(workspace.name + "-duplicate")
        shutil.copytree(workspace, duplicate)
        first, first_result = self.invoke("complete", "--workspace", str(workspace),
            "--workspace-nonce", handoff["workspace_nonce"])
        stored = self.store / handoff["review_id"]
        before = stored.read_bytes()
        second, second_result = self.invoke("complete", "--workspace", str(duplicate),
            "--workspace-nonce", handoff["workspace_nonce"])
        self.assertEqual((first.returncode, first_result["status"]), (0, "ok"))
        self.assertEqual((second.returncode, second_result["status"]), (1, "rejected"))
        self.assertEqual(second_result["error"]["code"], "review_exists")
        self.assertEqual(stored.read_bytes(), before)
        self.assertFalse(duplicate.exists())

    def test_concurrent_reviews_use_distinct_workspaces_and_store_ids(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first, second = [future.result() for future in
                (pool.submit(self.start), pool.submit(self.start))]
        handoffs = [first[1], second[1]]
        for handoff in handoffs:
            self.candidate(handoff)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = [future.result() for future in [pool.submit(self.invoke, "complete",
                "--workspace", handoff["workspace"], "--workspace-nonce",
                handoff["workspace_nonce"]) for handoff in handoffs]]
        self.assertNotEqual(handoffs[0]["review_id"], handoffs[1]["review_id"])
        self.assertNotEqual(handoffs[0]["workspace"], handoffs[1]["workspace"])
        self.assertEqual([(completed.returncode, result["status"])
            for completed, result in results], [(0, "ok"), (0, "ok")])
        self.assertTrue(all((self.store / handoff["review_id"]).is_file() for handoff in handoffs))

    def test_package_inventory_frontmatter_and_relative_link(self):
        expected = {"SKILL.md", "references/protocol.md", "scripts/review.py", "tests/test_review.py"}
        actual = {str(path.relative_to(ROOT)) for path in ROOT.rglob("*")
            if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc"}
        self.assertEqual(actual, expected)
        skill = (ROOT / "SKILL.md").read_text()
        self.assertTrue(skill.startswith("---\nname: gitframe-ai-review\n"))
        self.assertTrue((ROOT / "references" / "protocol.md").is_file())
        self.assertIn("[`references/protocol.md`](references/protocol.md)", skill)
        imports = set()
        for node in ast.walk(ast.parse(DRIVER.read_text())):
            if isinstance(node, ast.Import):
                imports.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imports.add(node.module.split(".")[0])
        self.assertLessEqual(imports, sys.stdlib_module_names)


if __name__ == "__main__":
    unittest.main()
