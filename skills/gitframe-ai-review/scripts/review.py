#!/usr/bin/env python3
"""Bounded, provider-neutral GitFrame AI review lifecycle driver."""

import argparse
import base64
import hashlib
import json
import os
import selectors
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

SCHEMA = 1
PRODUCER_NAME = "gitframe-ai-review"
SKILL_VERSION = "0.1.0"
CAPABILITIES = {
    "ai-review.input",
    "ai-review.producer",
    "committed-review.artifact",
    "committed-review.instructions",
    "committed-review.projection",
    "committed-review.target",
    "review-store.prepare",
    "review-store.publish",
}
PREFIX = "gitframe-ai-review-"
MAX_UNITS = 256
MAX_UNIT = 256 * 1024
MAX_CANDIDATE = 256 * 1024
MAX_CANDIDATES = 16 * 1024 * 1024


class Failure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class TerminalArgumentParser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        kwargs["add_help"] = False
        super().__init__(*args, **kwargs)

    def error(self, _message):
        raise Failure("invalid_arguments", "review driver arguments are invalid")


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def digest(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def repository_wire(path):
    raw = os.fsencode(path)
    if not raw or len(raw) > 4096 or b"\0" in raw:
        raise Failure("invalid_repository", "repository path is outside the supported bounds")
    return {"path_bytes_b64": base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")}


def repository_read_wire(path):
    raw = os.fsencode(path)
    if not raw or len(raw) > 4096 or b"\0" in raw:
        raise Failure("invalid_repository", "repository path is outside the supported bounds")
    return {"path_bytes_b64": base64.b64encode(raw).decode("ascii")}


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def strict_json(data, limit):
    if not data or len(data) > limit or not data.endswith(b"\n") or data.endswith(b"\n\n"):
        raise Failure("invalid_helper_output", "helper output is not one bounded JSON line")
    try:
        value = json.loads(data[:-1].decode("utf-8"), object_pairs_hook=no_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise Failure("invalid_helper_output", "helper output is not strict JSON") from error
    if not isinstance(value, dict) or encoded(value) != data:
        raise Failure("invalid_helper_output", "helper output is not canonical JSON")
    return value


def require_keys(value, keys):
    if list(value) != keys:
        raise Failure("invalid_helper_output", "helper terminal has unexpected fields")


def run(command, stdin, timeout, stdout_limit, stderr_limit=8192):
    try:
        child = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            shell=False, start_new_session=True, close_fds=True,
        )
    except OSError as error:
        return {"started": False, "error": str(error)}
    streams = selectors.DefaultSelector()
    for pipe, tag in ((child.stdout, "out"), (child.stderr, "err")):
        os.set_blocking(pipe.fileno(), False)
        streams.register(pipe, selectors.EVENT_READ, tag)
    offset = 0
    if stdin:
        os.set_blocking(child.stdin.fileno(), False)
        streams.register(child.stdin, selectors.EVENT_WRITE, "in")
    else:
        child.stdin.close()
    kept = {"out": bytearray(), "err": bytearray()}
    overflow = {"out": False, "err": False}
    limits = {"out": stdout_limit, "err": stderr_limit}
    deadline = time.monotonic() + timeout
    timed_out = False
    while streams.get_map() or child.poll() is None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            break
        if not streams.get_map():
            try:
                child.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                timed_out = True
            break
        for key, _ in streams.select(remaining):
            pipe, tag = key.fileobj, key.data
            if tag == "in":
                try:
                    count = os.write(pipe.fileno(), stdin[offset:offset + 65536])
                    offset += count
                except BrokenPipeError:
                    offset = len(stdin)
                if offset == len(stdin):
                    streams.unregister(pipe)
                    pipe.close()
            else:
                try:
                    chunk = os.read(pipe.fileno(), 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    streams.unregister(pipe)
                    pipe.close()
                    continue
                room = limits[tag] + 1 - len(kept[tag])
                if room > 0:
                    kept[tag].extend(chunk[:room])
                overflow[tag] |= len(kept[tag]) > limits[tag] or len(chunk) > room
    if timed_out:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    child.wait()
    for key in list(streams.get_map().values()):
        key.fileobj.close()
    streams.close()
    return {
        "started": True, "returncode": child.returncode, "timeout": timed_out,
        "stdout": bytes(kept["out"]), "stderr": bytes(kept["err"]),
        "overflow": overflow["out"] or overflow["err"],
    }


def helper(gitframe, action, request=b"", timeout=120, cap=16384):
    result = run([gitframe, *action], request, timeout, cap)
    if not result["started"]:
        raise Failure("helper_not_started", "GitFrame helper could not be started")
    if result["timeout"]:
        raise Failure("helper_timeout", "GitFrame helper timed out")
    if result["overflow"]:
        raise Failure("helper_output_limit", "GitFrame helper exceeded its output bound")
    if result["returncode"] != 0:
        try:
            terminal = strict_json(result["stdout"], cap)
            code = terminal.get("code") or terminal.get("error", {}).get("code")
        except Failure:
            code = None
        raise Failure(code or "helper_failed", "GitFrame helper rejected the request")
    return result["stdout"]


def parse_projection(data, target):
    try:
        newline = data.index(b"\n") + 1
    except ValueError as error:
        raise Failure("invalid_projection_frame", "projection frame has no header") from error
    header = strict_json(data[:newline], 2048)
    require_keys(header, ["schema_version", "status", "target", "patch_size"])
    if header["schema_version"] != SCHEMA or header["status"] != "ok" or header["target"] != target:
        raise Failure("invalid_projection_frame", "projection frame identity does not match")
    size = header["patch_size"]
    if not isinstance(size, int) or isinstance(size, bool) or size < 0 or size > 16 * 1024 * 1024:
        raise Failure("invalid_projection_frame", "projection size is invalid")
    if len(data) != newline + size:
        raise Failure("invalid_projection_frame", "projection frame length does not match")
    return data


def write_private(directory_fd, name, data):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(name, flags, 0o600, dir_fd=directory_fd)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(fd)
    finally:
        os.close(fd)


def validate_executable(path):
    if not os.path.isabs(path):
        raise Failure("invalid_gitframe", "gitframe must be an absolute executable path")
    path = os.path.abspath(path)
    info = os.stat(path)
    if not stat.S_ISREG(info.st_mode) or not os.access(path, os.X_OK):
        raise Failure("invalid_gitframe", "gitframe must be an executable regular file")
    return path


def validate_repository(path):
    if not os.path.isabs(path):
        raise Failure("invalid_repository", "repository must be an absolute directory")
    path = os.path.abspath(path)
    if not os.path.isdir(path):
        raise Failure("invalid_repository", "repository must be an absolute directory")
    return path


def begin(args):
    gitframe = validate_executable(args.gitframe)
    repository = validate_repository(args.repository)
    wire = repository_wire(repository)
    capabilities = strict_json(helper(gitframe, ["review-capabilities"], timeout=10), 16384)
    require_keys(capabilities, ["schema_version", "status", "gitframe_version", "capabilities"])
    offered = {item.get("name") for item in capabilities["capabilities"] if 1 in item.get("versions", [])}
    if capabilities["schema_version"] != SCHEMA or capabilities["status"] != "ok" or not CAPABILITIES <= offered:
        raise Failure("incompatible_gitframe", "GitFrame does not advertise every required v1 capability")
    head = args.head or "HEAD"
    target_doc = strict_json(helper(gitframe, ["review-target", "--repository", repository,
        "--source-kind", "branch_range", "--base", args.base, "--head", head]), 8192)
    require_keys(target_doc, ["schema_version", "status", "target"])
    if target_doc["schema_version"] != SCHEMA or target_doc["status"] != "ok":
        raise Failure("invalid_target", "review-target did not return a target")
    target = target_doc["target"]
    projection_request = encoded({"schema_version": SCHEMA, "repository": wire, "target": target})
    projection = parse_projection(helper(gitframe, ["review-projection"], projection_request,
        cap=16 * 1024 * 1024 + 2048), target)
    input_request = encoded({"schema_version": SCHEMA, "repository": wire, "target": target,
        "projection_frame_size": len(projection)}) + projection
    review_input = helper(gitframe, ["review-input"], input_request, cap=32 * 1024 * 1024)
    input_doc = strict_json(review_input, 32 * 1024 * 1024)
    require_keys(input_doc, ["schema_version", "status", "summary", "units"])
    if input_doc["schema_version"] != SCHEMA or input_doc["status"] != "ok":
        raise Failure("invalid_review_input", "review-input did not return a plan")
    units = input_doc["units"]
    if (not isinstance(units, list) or len(units) > MAX_UNITS
            or input_doc["summary"].get("unit_count") != len(units)):
        raise Failure("invalid_review_input", "review-input unit inventory does not match")
    if not units:
        return {"status": "no_changes", "schema_version": SCHEMA, "target": target, "unit_count": 0}
    prepared = strict_json(helper(gitframe, ["review-store-prepare"],
        encoded({"schema_version": SCHEMA, "repository": wire})), 4096)
    require_keys(prepared, ["status", "schema_version", "review_repository_id", "review_id"])
    if prepared["status"] != "ok" or prepared["schema_version"] != SCHEMA:
        raise Failure("prepare_failed", "review-store-prepare did not issue identifiers")
    workspace = tempfile.mkdtemp(prefix=PREFIX)
    os.chmod(workspace, 0o700)
    nonce = secrets.token_hex(32)
    producer = {"name": PRODUCER_NAME, "version": capabilities["gitframe_version"],
        "skill_version": SKILL_VERSION}
    inventory = []
    try:
        directory_fd = os.open(workspace, os.O_RDONLY | os.O_DIRECTORY)
        try:
            write_private(directory_fd, "input.json", review_input)
            for index, unit in enumerate(units, 1):
                unit_name = f"unit-{index:04d}.json"
                candidate_name = f"candidate-{index:04d}.json"
                unit_bytes = encoded(unit)
                if len(unit_bytes) > MAX_UNIT:
                    raise Failure("invalid_review_input", "review unit exceeds its finite bound")
                write_private(directory_fd, unit_name, unit_bytes)
                inventory.append({"unit_file": unit_name, "candidate_file": candidate_name,
                    "unit_sha256": digest(unit_bytes)})
            invocation = {"schema_version": SCHEMA, "gitframe": gitframe, "repository": repository,
                "temporary_root": os.path.dirname(workspace), "nonce_sha256": digest(bytes.fromhex(nonce)),
                "request": {"base": args.base, "head": head}, "target": target,
                "review_repository_id": prepared["review_repository_id"], "review_id": prepared["review_id"],
                "producer": producer, "input_size": len(review_input), "input_sha256": digest(review_input),
                "summary": input_doc["summary"], "units": inventory}
            write_private(directory_fd, "invocation.json", encoded(invocation))
        finally:
            os.close(directory_fd)
    except Exception:
        shutil.rmtree(workspace, ignore_errors=True)
        raise
    return {"status": "ready", "schema_version": SCHEMA, "workspace": workspace,
        "workspace_nonce": nonce, "review_repository_id": prepared["review_repository_id"],
        "review_id": prepared["review_id"], "target": target, "unit_count": len(units),
        "unit_files": [item["unit_file"] for item in inventory]}


def open_workspace(path, nonce):
    if (not os.path.isabs(path) or len(nonce) != 64
            or any(character not in "0123456789abcdef" for character in nonce)):
        raise Failure("invalid_handoff", "workspace handoff is invalid")
    try:
        bytes.fromhex(nonce)
        info = os.lstat(path)
    except (ValueError, OSError) as error:
        raise Failure("invalid_handoff", "workspace handoff is invalid") from error
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise Failure("invalid_workspace", "workspace ownership or mode is invalid")
    flags = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    directory_fd = os.open(path, flags)
    opened = os.fstat(directory_fd)
    if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
        os.close(directory_fd)
        raise Failure("invalid_workspace", "workspace changed while it was being opened")
    try:
        invocation = read_private(directory_fd, "invocation.json", 1024 * 1024)
        doc = strict_json(invocation, 1024 * 1024)
        keys = ["schema_version", "gitframe", "repository", "temporary_root", "nonce_sha256", "request",
            "target", "review_repository_id", "review_id", "producer", "input_size", "input_sha256",
            "summary", "units"]
        require_keys(doc, keys)
        units = doc["units"]
        if (doc["schema_version"] != SCHEMA or doc["temporary_root"] != os.path.dirname(path)
                or not os.path.basename(path).startswith(PREFIX)
                or doc["nonce_sha256"] != digest(bytes.fromhex(nonce))
                or not os.path.isabs(doc["gitframe"]) or not os.path.isabs(doc["repository"])
                or not isinstance(units, list) or not 1 <= len(units) <= 256):
            raise Failure("invalid_handoff", "workspace nonce or recorded authority does not match")
        for index, item in enumerate(units, 1):
            if (not isinstance(item, dict) or item != {"unit_file": f"unit-{index:04d}.json",
                    "candidate_file": f"candidate-{index:04d}.json", "unit_sha256": item.get("unit_sha256")} \
                    or not isinstance(item["unit_sha256"], str)):
                raise Failure("invalid_handoff", "workspace inventory is invalid")
    except Exception:
        os.close(directory_fd)
        raise
    return directory_fd, doc


def read_private(directory_fd, name, limit):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(name, flags, dir_fd=directory_fd)
    except OSError as error:
        raise Failure("missing_workspace_file", "required workspace file is missing") from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise Failure("unsafe_workspace_file", "workspace file ownership or mode is invalid")
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > limit:
            raise Failure("workspace_file_limit", "workspace file exceeds its bound")
        return bytes(data)
    finally:
        os.close(fd)


def parse_artifacts(data, invocation):
    try:
        newline = data.index(b"\n") + 1
    except ValueError as error:
        raise Failure("invalid_artifact_frame", "artifact frame has no header") from error
    header = strict_json(data[:newline], 16384)
    expected = ["schema_version", "status", "review_repository_id", "review_id", "target", "producer",
        "created_at", "finding_count", "manifest_sha256", "findings_sha256", "manifest_size", "findings_size"]
    require_keys(header, expected)
    if (header["schema_version"] != SCHEMA or header["status"] != "ok"
            or header["review_repository_id"] != invocation["review_repository_id"]
            or header["review_id"] != invocation["review_id"] or header["target"] != invocation["target"]
            or header["producer"] != invocation["producer"]):
        raise Failure("invalid_artifact_frame", "artifact identity does not match the handoff")
    manifest_size, findings_size = header["manifest_size"], header["findings_size"]
    if (not isinstance(manifest_size, int) or not isinstance(findings_size, int)
            or manifest_size < 1 or manifest_size > 256 * 1024
            or findings_size < 1 or findings_size > 16 * 1024 * 1024
            or len(data) != newline + manifest_size + findings_size):
        raise Failure("invalid_artifact_frame", "artifact lengths do not match")
    manifest = data[newline:newline + manifest_size]
    findings = data[newline + manifest_size:]
    if digest(manifest) != header["manifest_sha256"] or digest(findings) != header["findings_sha256"]:
        raise Failure("invalid_artifact_frame", "artifact digests do not match")
    return header, manifest, findings


def remove_workspace(path):
    try:
        shutil.rmtree(path)
        return None
    except OSError:
        return {"status": "residue", "message": "private workspace cleanup failed"}


def complete_admitted(directory_fd, invocation):
    try:
        review_input = read_private(directory_fd, "input.json", 32 * 1024 * 1024)
        if len(review_input) != invocation["input_size"] or digest(review_input) != invocation["input_sha256"]:
            raise Failure("invalid_workspace_input", "saved review input does not match the handoff")
        expected_candidates = {item["candidate_file"] for item in invocation["units"]}
        try:
            actual_candidates = {name for name in os.listdir(directory_fd)
                if name.startswith("candidate-") and name.endswith(".json")}
        except OSError as error:
            raise Failure("invalid_candidate_inventory", "candidate inventory is unavailable") from error
        if actual_candidates != expected_candidates:
            raise Failure("invalid_candidate_inventory", "candidate inventory does not match the handoff")
        candidates = []
        candidate_total = 0
        for item in invocation["units"]:
            unit = read_private(directory_fd, item["unit_file"], MAX_UNIT)
            if digest(unit) != item["unit_sha256"]:
                raise Failure("invalid_workspace_unit", "saved review unit does not match the handoff")
            candidate = read_private(directory_fd, item["candidate_file"], MAX_CANDIDATE)
            if not candidate:
                raise Failure("invalid_candidate", "candidate file is empty")
            candidate_total += len(candidate)
            if candidate_total > MAX_CANDIDATES:
                raise Failure("invalid_candidate", "candidate inventory exceeds its finite bound")
            candidates.append(candidate)
    finally:
        os.close(directory_fd)
    header = {"schema_version": SCHEMA, "repository": repository_wire(invocation["repository"]),
        "review_repository_id": invocation["review_repository_id"], "review_id": invocation["review_id"],
        "producer": invocation["producer"], "review_input_size": len(review_input),
        "candidate_sizes": [len(value) for value in candidates]}
    artifact_frame = helper(invocation["gitframe"], ["review-producer", "artifacts"],
        encoded(header) + review_input + b"".join(candidates), cap=17 * 1024 * 1024)
    artifact, manifest, findings = parse_artifacts(artifact_frame, invocation)
    publish_header = {"schema_version": SCHEMA, "repository": repository_wire(invocation["repository"]),
        "review_repository_id": invocation["review_repository_id"], "review_id": invocation["review_id"],
        "manifest_size": len(manifest), "findings_size": len(findings)}
    publish = run([invocation["gitframe"], "review-store-publish"],
        encoded(publish_header) + manifest + findings, 120, 4096)
    identity = {key: artifact[key] for key in ("review_repository_id", "target", "producer", "created_at",
        "finding_count", "manifest_sha256", "findings_sha256")}
    if (not publish["started"]):
        raise Failure("publish_not_started", "review-store-publish could not be started")
    unknown = publish["timeout"] or publish["overflow"] or publish["returncode"] < 0
    terminal = None
    if not unknown:
        try:
            terminal = strict_json(publish["stdout"], 4096)
            if publish["returncode"] == 0:
                expected = {"status": "ok", "schema_version": SCHEMA,
                    "review_repository_id": invocation["review_repository_id"], "review_id": invocation["review_id"]}
                unknown = list(terminal) != list(expected) or terminal != expected
            else:
                unknown = (list(terminal) != ["status", "schema_version", "code", "message"]
                    or terminal.get("status") != "error" or terminal.get("schema_version") != SCHEMA
                    or not isinstance(terminal.get("code"), str) or not isinstance(terminal.get("message"), str))
        except Failure:
            unknown = True
    if unknown:
        result = {"status": "outcome_unknown", "schema_version": SCHEMA,
            "repository": repository_read_wire(invocation["repository"]),
            "review_repository_id": invocation["review_repository_id"], "review_id": invocation["review_id"],
            "expected": identity}
    elif publish["returncode"] == 0:
        result = terminal
    else:
        result = {"status": "rejected", "schema_version": SCHEMA,
            "review_repository_id": invocation["review_repository_id"], "review_id": invocation["review_id"],
            "error": {"code": terminal.get("code", "publish_rejected"),
                "message": terminal.get("message", "publication was rejected")}}
    return result


def complete(args):
    directory_fd, invocation = open_workspace(args.workspace, args.workspace_nonce)
    try:
        try:
            result = complete_admitted(directory_fd, invocation)
        except Failure as error:
            result = {"status": "error", "schema_version": SCHEMA,
                "code": error.code, "message": error.message}
    finally:
        cleanup = remove_workspace(args.workspace)
    if cleanup:
        result["cleanup"] = cleanup
    return result


def parser():
    root = TerminalArgumentParser(description=__doc__)
    actions = root.add_subparsers(dest="action", required=True)
    start = actions.add_parser("begin")
    start.add_argument("--gitframe", required=True)
    start.add_argument("--repository", required=True)
    start.add_argument("--base", required=True)
    start.add_argument("--head")
    finish = actions.add_parser("complete")
    finish.add_argument("--workspace", required=True)
    finish.add_argument("--workspace-nonce", required=True)
    return root


def main():
    try:
        args = parser().parse_args()
        result = begin(args) if args.action == "begin" else complete(args)
        sys.stdout.buffer.write(encoded(result))
        return 0 if result["status"] in ("ready", "no_changes", "ok") else 1
    except Failure as error:
        sys.stdout.buffer.write(encoded({"status": "error", "schema_version": SCHEMA,
            "code": error.code, "message": error.message}))
        return 1
    except Exception:
        sys.stdout.buffer.write(encoded({"status": "error", "schema_version": SCHEMA,
            "code": "internal_error", "message": "review driver could not complete"}))
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
