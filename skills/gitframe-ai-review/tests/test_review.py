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
def enc(v): return (json.dumps(v,ensure_ascii=False,separators=(",",":"))+"\n").encode()
def sha(v): return "sha256:"+hashlib.sha256(v).hexdigest()
def log(name):
 p=os.environ["FAKE_LOG"]
 with open(p,"a",encoding="utf-8") as f: f.write(name+"\n")
cmd=sys.argv[1:]; name=" ".join(cmd[:2]) if cmd[:1]==["review-producer"] else cmd[0]; log(name)
target={"object_format":"sha1","source_kind":"branch_range","base_oid":"1"*40,"head_oid":"2"*40,"diff_base_oid":"1"*40}
if name=="review-capabilities":
 names=["ai-review.input","ai-review.producer","committed-review.artifact","committed-review.instructions","committed-review.projection","committed-review.target","review-store.prepare","review-store.publish"]
 if os.environ.get("FAKE_NO_TARGET_CAPABILITY")=="1": names.remove("committed-review.target")
 if os.environ.get("FAKE_NO_RESULT_CAPABILITY")!="1": names.append("review-store.result-read")
 capabilities=[]
 for n in names:
  version=2 if n=="committed-review.target" else 1
  if n=="committed-review.target" and os.environ.get("FAKE_TARGET_V1_CAPABILITY")=="1": version=1
  if n=="committed-review.target" and os.environ.get("FAKE_FUTURE_TARGET_CAPABILITY")=="1": version=3
  if n=="committed-review.target" and os.environ.get("FAKE_BOOLEAN_TARGET_CAPABILITY")=="1": version=True
  if n=="review-store.result-read" and os.environ.get("FAKE_BOOLEAN_RESULT_CAPABILITY")=="1": version=True
  if n=="review-store.result-read" and os.environ.get("FAKE_FUTURE_RESULT_CAPABILITY")=="1": version=2
  capabilities.append({"name":n,"versions":[version]})
 sys.stdout.buffer.write(enc({"schema_version":True if os.environ.get("FAKE_BOOLEAN_CAPABILITY_SCHEMA")=="1" else 1,"status":"ok","gitframe_version":"0.0.0-test","capabilities":capabilities}))
elif name=="review-target":
 mode=os.environ.get("FAKE_TARGET_MODE","")
 display={"base_label":"review-base","head_label":"feature"}
 if mode=="all_null": display={"base_label":None,"head_label":None}
 if mode=="base_only": display={"base_label":"review-base","head_label":None}
 if mode=="changed": display={"base_label":"renamed-base","head_label":"renamed-head"}
 if mode=="reordered_display": display={"head_label":"feature","base_label":"review-base"}
 if mode=="extra_display": display={"base_label":"review-base","head_label":"feature","extra":None}
 if mode=="invalid_text": display={"base_label":"bad\x1bname","head_label":"feature"}
 if mode=="long_text": display={"base_label":"x"*257,"head_label":"feature"}
 if mode=="invalid_type": display={"base_label":1,"head_label":"feature"}
 response={"schema_version":2,"status":"ok","target":target,"display":display}
 if mode=="schema_v1": response["schema_version"]=1
 if mode=="boolean_schema": response["schema_version"]=True
 if mode=="missing_display": response.pop("display")
 if mode=="reordered_response": response={"schema_version":2,"status":"ok","display":display,"target":target}
 sys.stdout.buffer.write(enc(response))
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
 data=sys.stdin.buffer.read(); header=json.loads(data.split(b"\n",1)[0]); manifest_doc={"artifact":"manifest"}
 if "display" in header: manifest_doc["display"]=header["display"]
 manifest=enc(manifest_doc); findings=b'{"artifact":"findings"}\n'
 out={"schema_version":1,"status":"ok","review_repository_id":header["review_repository_id"],"review_id":header["review_id"],"target":target,"producer":header["producer"],"created_at":"2026-08-27T00:00:00Z","finding_count":0,"manifest_sha256":sha(manifest),"findings_sha256":sha(findings),"manifest_size":len(manifest),"findings_size":len(findings)}
 sys.stdout.buffer.write(enc(out)+manifest+findings)
elif name=="review-store-publish":
 data=sys.stdin.buffer.read(); header=json.loads(data.split(b"\n",1)[0]); path=os.path.join(os.environ["FAKE_STORE"],header["review_id"])
 publish_error=os.environ.get("FAKE_PUBLISH_ERROR")
 if publish_error:
  exits={"target_label_invalid":65,"local_time_unavailable":74,"run_name_collision":73}
  sys.stdout.buffer.write(enc({"status":"error","schema_version":1,"code":publish_error,"message":"publication naming failed"}));sys.exit(exits[publish_error])
 try:
  fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,"wb") as f: f.write(data)
 except FileExistsError:
  sys.stdout.buffer.write(enc({"status":"error","schema_version":1,"code":"review_exists","message":"review already exists"})); sys.exit(73)
 if os.environ.get("FAKE_UNKNOWN")=="1": sys.stdout.buffer.write(b"not-json")
 else: sys.stdout.buffer.write(enc({"status":"ok","schema_version":1,"review_repository_id":header["review_repository_id"],"review_id":header["review_id"]}))
elif name=="review-result-read":
 data=sys.stdin.buffer.read()
 request_path=os.environ.get("FAKE_REQUEST_LOG")
 if request_path:
  with open(request_path,"wb") as f: f.write(data)
 mode=os.environ.get("FAKE_RESULT_MODE","completed")
 if mode in ("error","boolean_error_schema","unknown_error"):
  sys.stderr.buffer.write(b"/secret/review-store/result.json\n")
  sys.stdout.buffer.write(enc({"status":"error","schema_version":True if mode=="boolean_error_schema" else 1,"code":"unexpected" if mode=="unknown_error" else "artifact_invalid","message":"hidden fake path"}));sys.exit(65)
 if mode=="oversized_error":
  sys.stdout.buffer.write(enc({"status":"error","schema_version":1,"code":"x"*20000,"message":"hidden fake path"}));sys.exit(65)
 if mode=="oversized": sys.stdout.buffer.write(b"x"*(16*1024*1024+16*1024+1));sys.exit(0)
 if mode=="malformed": sys.stdout.buffer.write(b"not-json");sys.exit(0)
 request=json.loads(data);review_id=request["review_id"]
 repository_id="223e4567-e89b-42d3-a456-426614174000";findings=sha(b"findings\n")
 zero=os.environ.get("FAKE_ZERO_FINDINGS")=="1";count=0 if zero else 3
 header={"status":"pending","schema_version":1,"review_repository_id":repository_id,"review_id":review_id,"target":target,"findings_sha256":findings,"finding_count":count}
 if mode=="boolean_header_schema": header["schema_version"]=True
 if mode=="pending": sys.stdout.buffer.write(enc(header));sys.exit(0)
 dispositions=[] if zero else [{"finding_id":"F-1","disposition":"accepted"},{"finding_id":"F-2","disposition":"dismissed"},{"finding_id":"F-3","disposition":"unreviewed"}]
 notes=[] if zero else [{"anchor":{"path_bytes_b64":"c3JjL21haW4uemln","display_path":"src/main.zig","side":"after","start_line":2,"end_line":2,"content_digest":"sha256:"+"0"*64,"quoted_text":"line\n"},"body":"確認してください。\n詳細","related_finding_ids":["F-1","F-2"]}]
 result={"schema_version":1,"review_id":review_id,"target":target,"findings_digest":findings,"result":os.environ.get("FAKE_DECISION","needs_changes"),"completed_at":"2026-08-29T00:00:00Z","summary":"要修正です。\n二行目","finding_dispositions":dispositions,"anchored_notes":notes}
 if mode=="boolean_result_schema": result["schema_version"]=True
 payload=enc(result)
 header["status"]="completed";header["result_sha256"]=sha(payload);header["result_size"]=len(payload)
 if mode=="wrong_identity": header["review_id"]="323e4567-e89b-42d3-a456-426614174000"
 if mode=="wrong_digest": header["result_sha256"]=sha(b"wrong")
 frame=enc(header)+payload
 if mode=="extra": frame+=b"x"
 sys.stdout.buffer.write(frame)
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

REVIEW_ID = "123e4567-e89b-42d3-a456-426614174000"
TARGET = {"object_format": "sha1", "source_kind": "branch_range", "base_oid": "1" * 40,
    "head_oid": "2" * 40, "diff_base_oid": "1" * 40}
DISPLAY = {"base_label": "review-base", "head_label": "feature"}
FINDINGS_DIGEST = review.digest(b"findings\n")
PRODUCER_ARGS = ("--producer-name", "codex", "--producer-model", "gpt-test",
    "--producer-version", "codex-test")
PRODUCER = {"name": "codex", "model": "gpt-test", "version": "codex-test",
    "skill_version": "0.1.0"}
EXPECTED = {"review_repository_id": "223e4567-e89b-42d3-a456-426614174000",
    "target": TARGET, "producer": {"name": "test", "model": "fixture", "version": "1",
        "skill_version": "0.1.0"}, "created_at": "2026-08-29T00:00:00Z", "finding_count": 3,
    "manifest_sha256": review.digest(b"manifest\n"), "findings_sha256": FINDINGS_DIGEST}


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
        self.request_log = self.root / "request"
        self.store = self.root / "store"
        self.store.mkdir()
        self.environment = dict(os.environ, FAKE_LOG=str(self.log), FAKE_STORE=str(self.store),
            FAKE_REPOSITORY=str(self.repository), FAKE_REQUEST_LOG=str(self.request_log))

    def tearDown(self):
        self.temp.cleanup()

    def invoke_raw(self, *arguments, extra=None):
        environment = dict(self.environment)
        environment.update(extra or {})
        return subprocess.run([sys.executable, "-I", str(DRIVER), *arguments],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, check=False)

    def invoke(self, *arguments, extra=None):
        completed = self.invoke_raw(*arguments, extra=extra)
        return completed, json.loads(completed.stdout)

    def start(self, extra=None, producer_args=PRODUCER_ARGS):
        return self.invoke("begin", "--gitframe", str(self.fake), "--repository",
            str(self.repository), "--base", "main", *producer_args, extra=extra)

    def candidate(self, handoff):
        path = Path(handoff["workspace"]) / "candidate-0001.json"
        path.write_bytes(b'{"findings":[]}\n')
        path.chmod(0o600)

    def events(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def read_result(self, expected=None, extra=None, review_id=REVIEW_ID):
        arguments = ["read-result", "--gitframe", str(self.fake), "--repository",
            str(self.repository), "--review-id", review_id]
        if expected is not None:
            arguments.extend(["--expected-publication-json", expected])
        return self.invoke_raw(*arguments, extra=extra)

    def split_frame(self, data):
        header, payload = data.split(b"\n", 1)
        return json.loads(header), payload

    def stored_manifest(self, review_id):
        header, payload = self.split_frame((self.store / review_id).read_bytes())
        size = header["manifest_size"]
        return json.loads(payload[:size])

    def test_argument_failures_are_one_canonical_json_terminal_without_children(self):
        cases = [
            (),
            ("begin", "--gitframe", str(self.fake)),
            ("complete", "--workspace", "/nonexistent"),
            ("read-result", "--gitframe", str(self.fake), "--repository", str(self.repository)),
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

    def test_begin_records_exact_caller_provenance_without_gitframe_version(self):
        completed, handoff = self.start()
        self.assertEqual((completed.returncode, handoff["status"]), (0, "ready"))
        workspace = Path(handoff["workspace"])
        self.addCleanup(shutil.rmtree, workspace, ignore_errors=True)
        invocation = json.loads((workspace / "invocation.json").read_bytes())
        self.assertEqual(invocation["producer"], PRODUCER)
        self.assertEqual(invocation["display"], DISPLAY)
        self.assertEqual(list(invocation)[list(invocation).index("target") + 1], "display")
        self.assertNotIn("0.0.0-test", invocation["producer"].values())

        completed, handoff = self.start(producer_args=("--producer-name", "claude-code"))
        self.assertEqual((completed.returncode, handoff["status"]), (0, "ready"))
        workspace = Path(handoff["workspace"])
        self.addCleanup(shutil.rmtree, workspace, ignore_errors=True)
        invocation = json.loads((workspace / "invocation.json").read_bytes())
        self.assertEqual(invocation["producer"], {
            "name": "claude-code", "skill_version": "0.1.0"})

    def test_begin_requires_target_v2_and_strict_capability_membership(self):
        cases = ({"FAKE_TARGET_V1_CAPABILITY": "1"}, {"FAKE_NO_TARGET_CAPABILITY": "1"},
            {"FAKE_BOOLEAN_TARGET_CAPABILITY": "1"}, {"FAKE_FUTURE_TARGET_CAPABILITY": "1"})
        for extra in cases:
            with self.subTest(extra=extra):
                self.log.unlink(missing_ok=True)
                completed, result = self.start(extra)
                self.assertEqual((completed.returncode, result["code"]),
                    (1, "incompatible_gitframe"))
                self.assertEqual(self.events(), ["review-capabilities"])

    def test_begin_rejects_invalid_target_v2_display_before_projection(self):
        modes = ("schema_v1", "boolean_schema", "missing_display", "reordered_response",
            "reordered_display", "extra_display", "invalid_text", "long_text", "invalid_type")
        for mode in modes:
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                completed, result = self.start({"FAKE_TARGET_MODE": mode})
                self.assertEqual((completed.returncode, result["code"]), (1, "invalid_target"))
                self.assertEqual(self.events(), ["review-capabilities", "review-target"])

    def test_begin_rejects_missing_or_invalid_provenance_before_children(self):
        base = ("begin", "--gitframe", str(self.fake), "--repository",
            str(self.repository), "--base", "main")
        cases = [base, base + ("--producer-name",),
            base + ("--producer-name", "codex", "--producer-model")]
        for flag in ("--producer-name", "--producer-model", "--producer-version"):
            prefix = base if flag == "--producer-name" else base + ("--producer-name", "codex")
            cases.extend(prefix + (flag, value) for value in ("", "bad\x1bvalue", "x" * 257))
        expected = {"status": "error", "schema_version": 1,
            "code": "invalid_arguments", "message": "review driver arguments are invalid"}
        for arguments in cases:
            with self.subTest(arguments=arguments[:8], size=len(arguments[-1])):
                completed, result = self.invoke(*arguments)
                self.assertEqual((completed.returncode, completed.stderr, result), (1, b"", expected))
                self.assertEqual(completed.stdout, review.encoded(expected))
                self.assertEqual(self.events(), [])

    def test_read_result_pending_is_one_exact_read_without_retry_or_mutation(self):
        completed = self.read_result(extra={"FAKE_RESULT_MODE": "pending"})
        header, payload = self.split_frame(completed.stdout)
        self.assertEqual((completed.returncode, completed.stderr, payload), (0, b"", b""))
        self.assertEqual(header, {"status": "pending", "schema_version": 1,
            "review_repository_id": EXPECTED["review_repository_id"], "review_id": REVIEW_ID,
            "target": TARGET, "findings_sha256": FINDINGS_DIGEST, "finding_count": 3})
        self.assertEqual(completed.stdout, review.encoded(header))
        request = json.loads(self.request_log.read_bytes())
        self.assertEqual(list(request), ["schema_version", "repository", "review_id"])
        self.assertEqual(base64.b64decode(request["repository"]["path_bytes_b64"], validate=True),
            os.fsencode(self.repository))
        self.assertEqual(self.events(), ["review-capabilities", "review-result-read"])

    def test_read_result_preserves_all_decisions_zero_findings_and_unicode_notes(self):
        anchor = {"path_bytes_b64": "c3JjL21haW4uemln", "display_path": "src/main.zig",
            "side": "after", "start_line": 2, "end_line": 2,
            "content_digest": "sha256:" + "0" * 64, "quoted_text": "line\n"}
        dispositions = [{"finding_id": "F-1", "disposition": "accepted"},
            {"finding_id": "F-2", "disposition": "dismissed"},
            {"finding_id": "F-3", "disposition": "unreviewed"}]
        notes = [{"anchor": anchor, "body": "確認してください。\n詳細",
            "related_finding_ids": ["F-1", "F-2"]}]
        for decision in ("approved", "needs_changes", "canceled"):
            with self.subTest(decision=decision):
                self.log.unlink(missing_ok=True)
                completed = self.read_result(extra={"FAKE_DECISION": decision})
                header, payload = self.split_frame(completed.stdout)
                expected_result = {"schema_version": 1, "review_id": REVIEW_ID, "target": TARGET,
                    "findings_digest": FINDINGS_DIGEST, "result": decision,
                    "completed_at": "2026-08-29T00:00:00Z", "summary": "要修正です。\n二行目",
                    "finding_dispositions": dispositions, "anchored_notes": notes}
                expected_payload = review.encoded(expected_result)
                expected_header = {"status": "completed", "schema_version": 1,
                    "review_repository_id": EXPECTED["review_repository_id"], "review_id": REVIEW_ID,
                    "target": TARGET, "findings_sha256": FINDINGS_DIGEST, "finding_count": 3,
                    "result_sha256": review.digest(expected_payload), "result_size": len(expected_payload)}
                self.assertEqual((completed.returncode, completed.stderr), (0, b""))
                self.assertEqual((header, payload), (expected_header, expected_payload))
                self.assertEqual(completed.stdout, review.encoded(expected_header) + expected_payload)
                self.assertEqual(self.events(), ["review-capabilities", "review-result-read"])

        self.log.unlink(missing_ok=True)
        completed = self.read_result(extra={"FAKE_ZERO_FINDINGS": "1"})
        header, payload = self.split_frame(completed.stdout)
        result = json.loads(payload)
        self.assertEqual((completed.returncode, header["finding_count"],
            result["finding_dispositions"], result["anchored_notes"]), (0, 0, [], []))
        self.assertEqual(self.events(), ["review-capabilities", "review-result-read"])

    def test_read_result_validates_and_forwards_complete_expected_identity(self):
        expected_text = review.encoded(EXPECTED)[:-1].decode()
        completed = self.read_result(expected=expected_text)
        self.assertEqual((completed.returncode, completed.stderr), (0, b""))
        request = json.loads(self.request_log.read_bytes(), object_pairs_hook=review.no_duplicates)
        self.assertEqual(list(request), ["schema_version", "repository", "review_id", "expected"])
        self.assertEqual(request["expected"], EXPECTED)
        self.assertEqual(self.request_log.read_bytes(), review.encoded(request))
        self.assertEqual(self.events(), ["review-capabilities", "review-result-read"])

    def test_invalid_expected_identity_boundaries_start_no_child(self):
        expected_text = review.encoded(EXPECTED)[:-1].decode()
        reordered = dict(list(EXPECTED.items())[1:] + list(EXPECTED.items())[:1])
        cases = [
            "",
            "{",
            '{"review_repository_id":"223e4567-e89b-42d3-a456-426614174000","review_repository_id":"223e4567-e89b-42d3-a456-426614174000"}',
            '{"review_repository_id":"223e4567-e89b-42d3-a456-426614174000"}',
            expected_text[:-1] + ',"unknown":1}',
            "null",
            json.dumps(reordered, ensure_ascii=False, separators=(",", ":")),
            json.dumps(EXPECTED, ensure_ascii=False),
            expected_text.replace('{"name":"test"', '{"name":null', 1),
            "x" * 4096,
            "x" * 4097,
            "é" * 2048,
            "é" * 2048 + "x",
        ]
        expected_terminal = {"status": "error", "schema_version": 1,
            "code": "invalid_expected_publication",
            "message": "expected publication identity is invalid"}
        for value in cases:
            with self.subTest(size=len(value.encode("utf-8")), prefix=value[:20]):
                self.log.unlink(missing_ok=True)
                self.request_log.unlink(missing_ok=True)
                completed = self.read_result(expected=value)
                self.assertEqual((completed.returncode, completed.stderr, json.loads(completed.stdout)),
                    (1, b"", expected_terminal))
                self.assertEqual(completed.stdout, review.encoded(expected_terminal))
                self.assertEqual(self.events(), [])
                self.assertFalse(self.request_log.exists())

        args = types.SimpleNamespace(gitframe=str(self.fake), repository=str(self.repository),
            review_id=REVIEW_ID, expected_publication_json="\ud800")
        with mock.patch.object(review, "helper") as child:
            with self.assertRaises(review.Failure) as failure:
                review.read_result(args)
        self.assertEqual(failure.exception.code, "invalid_expected_publication")
        child.assert_not_called()

        args.expected_publication_json = expected_text
        with mock.patch.object(review, "MAX_READ_REQUEST", 1), mock.patch.object(review, "helper") as child:
            with self.assertRaises(review.Failure) as failure:
                review.read_result(args)
        self.assertEqual(failure.exception.code, "invalid_expected_publication")
        child.assert_not_called()

    def test_read_result_requires_only_its_action_capability(self):
        for extra in ({"FAKE_NO_RESULT_CAPABILITY": "1"},
                {"FAKE_FUTURE_RESULT_CAPABILITY": "1"},
                {"FAKE_BOOLEAN_RESULT_CAPABILITY": "1"},
                {"FAKE_BOOLEAN_CAPABILITY_SCHEMA": "1"}):
            with self.subTest(extra=extra):
                self.log.unlink(missing_ok=True)
                completed = self.read_result(extra=extra)
                result = json.loads(completed.stdout)
                self.assertEqual((completed.returncode, result["code"]), (1, "incompatible_gitframe"))
                self.assertEqual(self.events(), ["review-capabilities"])

        self.log.unlink(missing_ok=True)
        completed = self.read_result(extra={"FAKE_RESULT_MODE": "pending"})
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(self.events(), ["review-capabilities", "review-result-read"])

    def test_read_result_failures_are_bounded_sanitized_and_never_retried(self):
        cases = {
            "error": "artifact_invalid",
            "boolean_error_schema": "helper_failed",
            "unknown_error": "helper_failed",
            "malformed": "invalid_result_frame",
            "wrong_identity": "invalid_result_frame",
            "wrong_digest": "invalid_result_frame",
            "extra": "invalid_result_frame",
            "oversized": "helper_output_limit",
            "oversized_error": "helper_failed",
            "boolean_header_schema": "invalid_result_frame",
            "boolean_result_schema": "invalid_result_frame",
        }
        for mode, code in cases.items():
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                completed = self.read_result(extra={"FAKE_RESULT_MODE": mode})
                result = json.loads(completed.stdout)
                self.assertEqual((completed.returncode, completed.stderr, result["status"], result["code"]),
                    (1, b"", "error", code))
                self.assertNotIn(b"/secret/", completed.stdout)
                self.assertLess(len(completed.stdout), 256)
                self.assertEqual(self.events(), ["review-capabilities", "review-result-read"])

        mismatched = dict(EXPECTED, finding_count=2)
        self.log.unlink(missing_ok=True)
        completed = self.read_result(expected=review.encoded(mismatched)[:-1].decode())
        self.assertEqual((completed.returncode, json.loads(completed.stdout)["code"]),
            (1, "invalid_result_frame"))
        self.assertEqual(self.events(), ["review-capabilities", "review-result-read"])

    def test_read_result_rejects_noncanonical_review_ids_before_children(self):
        for review_id in (REVIEW_ID.upper(), "123e4567-e89b-12d3-a456-426614174000",
                "123e4567-e89b-42d3-7456-426614174000", "partial"):
            with self.subTest(review_id=review_id):
                self.log.unlink(missing_ok=True)
                completed = self.read_result(review_id=review_id)
                self.assertEqual((completed.returncode, json.loads(completed.stdout)["code"]),
                    (1, "invalid_review_id"))
                self.assertEqual(self.events(), [])

    def test_normal_lifecycle_publishes_once_and_cleans(self):
        started, handoff = self.start()
        self.assertEqual((started.returncode, handoff["status"]), (0, "ready"))
        workspace = Path(handoff["workspace"])
        self.candidate(handoff)
        finished, result = self.invoke("complete", "--workspace", str(workspace),
            "--workspace-nonce", handoff["workspace_nonce"],
            extra={"FAKE_TARGET_MODE": "changed"})
        self.assertEqual((finished.returncode, result["status"]), (0, "ok"))
        self.assertFalse(workspace.exists())
        self.assertEqual(self.stored_manifest(handoff["review_id"]),
            {"artifact": "manifest", "display": DISPLAY})
        self.assertEqual(self.events().count("review-producer artifacts"), 1)
        self.assertEqual(self.events().count("review-store-publish"), 1)

    def test_publication_naming_failures_are_preserved_without_retry(self):
        for code in ("target_label_invalid", "local_time_unavailable", "run_name_collision"):
            with self.subTest(code=code):
                self.log.unlink(missing_ok=True)
                _, handoff = self.start()
                workspace = Path(handoff["workspace"])
                self.candidate(handoff)
                completed, result = self.invoke("complete", "--workspace", str(workspace),
                    "--workspace-nonce", handoff["workspace_nonce"],
                    extra={"FAKE_PUBLISH_ERROR": code})
                self.assertEqual((completed.returncode, result["status"], result["error"]["code"]),
                    (1, "rejected", code))
                self.assertEqual(self.events().count("review-store-publish"), 1)
                self.assertFalse(workspace.exists())
                self.assertFalse((self.store / handoff["review_id"]).exists())

    def test_nullable_display_is_omitted_or_forwarded_without_repair(self):
        cases = {
            "all_null": (None, {"artifact": "manifest"}),
            "base_only": ({"base_label": "review-base", "head_label": None},
                {"artifact": "manifest", "display": {"base_label": "review-base"}}),
        }
        for mode, (invocation_display, manifest) in cases.items():
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                _, handoff = self.start({"FAKE_TARGET_MODE": mode})
                workspace = Path(handoff["workspace"])
                invocation = json.loads((workspace / "invocation.json").read_bytes())
                if invocation_display is None:
                    self.assertNotIn("display", invocation)
                else:
                    self.assertEqual(invocation["display"], invocation_display)
                self.candidate(handoff)
                completed, result = self.invoke("complete", "--workspace", str(workspace),
                    "--workspace-nonce", handoff["workspace_nonce"],
                    extra={"FAKE_TARGET_MODE": "changed"})
                self.assertEqual((completed.returncode, result["status"]), (0, "ok"))
                self.assertEqual(self.stored_manifest(handoff["review_id"]), manifest)

    def test_corrupt_workspace_display_stops_before_artifacts(self):
        _, handoff = self.start()
        workspace = Path(handoff["workspace"])
        invocation_path = workspace / "invocation.json"
        invocation = json.loads(invocation_path.read_bytes())
        invocation["display"] = {"base_label": None, "head_label": None}
        invocation_path.write_bytes(review.encoded(invocation))
        self.candidate(handoff)
        completed, result = self.invoke("complete", "--workspace", str(workspace),
            "--workspace-nonce", handoff["workspace_nonce"])
        self.assertEqual((completed.returncode, result["code"]), (1, "invalid_handoff"))
        self.assertTrue(workspace.is_dir())
        self.addCleanup(shutil.rmtree, workspace, ignore_errors=True)
        self.assertNotIn("review-producer artifacts", self.events())
        self.assertNotIn("review-store-publish", self.events())

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
            base="main", head=None, producer_name="codex", producer_model=None,
            producer_version=None)
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
        noncanonical_repository = (encoded_repository[:-1] if encoded_repository.endswith("=")
            else encoded_repository + "=")
        wrong_request = dict(request, repository={"path_bytes_b64": noncanonical_repository})
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
            base="main", head=None, producer_name="codex", producer_model=None,
            producer_version=None)
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
