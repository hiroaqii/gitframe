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
TARGET_SCHEMA = 2
SKILL_VERSION = "0.1.0"
CAPABILITIES = {
    "ai-review.input": 1,
    "ai-review.producer": 1,
    "committed-review.artifact": 1,
    "committed-review.instructions": 1,
    "committed-review.projection": 1,
    "committed-review.target": TARGET_SCHEMA,
    "review-store.prepare": 1,
    "review-store.publish": 1,
}
RESULT_CAPABILITY = "review-store.result-read"
RESULT_ERROR_CODES = frozenset({
    "expected_mismatch",
    "artifact_invalid",
    "review_not_found",
    "target_unavailable",
    "store_unavailable",
    "unsupported_platform",
    "unsupported_filesystem",
    "repository_invalid",
    "git_failed",
    "store_invalid",
    "binding_invalid",
    "io_failed",
    "root_changed",
    "binding_changed",
    "artifact_changed",
    "concurrent_conflict",
    "out_of_memory",
})
PREFIX = "gitframe-ai-review-"
MAX_UNITS = 256
MAX_UNIT = 256 * 1024
MAX_CANDIDATE = 256 * 1024
MAX_CANDIDATES = 16 * 1024 * 1024
MAX_EXPECTED_PUBLICATION = 4096
MAX_READ_REQUEST = 16 * 1024
MAX_READ_HEADER = 16 * 1024
MAX_RESULT = 16 * 1024 * 1024


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


def reject_json_constant(_value):
    raise ValueError("non-finite JSON number")


def strict_json(data, limit):
    if not data or len(data) > limit or not data.endswith(b"\n") or data.endswith(b"\n\n"):
        raise Failure("invalid_helper_output", "helper output is not one bounded JSON line")
    try:
        value = json.loads(data[:-1].decode("utf-8"), object_pairs_hook=no_duplicates,
            parse_constant=reject_json_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise Failure("invalid_helper_output", "helper output is not strict JSON") from error
    if not isinstance(value, dict) or encoded(value) != data:
        raise Failure("invalid_helper_output", "helper output is not canonical JSON")
    return value


def require_keys(value, keys):
    if list(value) != keys:
        raise Failure("invalid_helper_output", "helper terminal has unexpected fields")


def canonical_uuid_v4(value):
    if (not isinstance(value, str) or len(value) != 36
            or value[8] != "-" or value[13] != "-" or value[18] != "-" or value[23] != "-"):
        return False
    compact = value.replace("-", "")
    return (len(compact) == 32 and all(character in "0123456789abcdef" for character in compact)
        and value[14] == "4" and value[19] in "89ab")


def canonical_digest(value):
    return (isinstance(value, str) and len(value) == 71 and value.startswith("sha256:")
        and all(character in "0123456789abcdef" for character in value[7:]))


def schema_v1(value):
    return type(value) is int and value == SCHEMA


def validate_target(value):
    keys = ["object_format", "source_kind", "base_oid", "head_oid", "diff_base_oid"]
    if not isinstance(value, dict) or list(value) != keys:
        raise ValueError("target shape")
    width = {"sha1": 40, "sha256": 64}.get(value["object_format"])
    if width is None or value["source_kind"] != "branch_range":
        raise ValueError("target kind")
    for key in ("base_oid", "head_oid", "diff_base_oid"):
        oid = value[key]
        if (not isinstance(oid, str) or len(oid) != width
                or any(character not in "0123456789abcdef" for character in oid)):
            raise ValueError("target object ID")


def validate_display(value, allow_empty):
    if not isinstance(value, dict) or list(value) != ["base_label", "head_label"]:
        raise ValueError("display shape")
    for label in value.values():
        if label is not None:
            validate_text(label, 256, False)
    if not allow_empty and value["base_label"] is None and value["head_label"] is None:
        raise ValueError("empty display")


def require_capabilities(document, required, message):
    try:
        if (not isinstance(document, dict)
                or list(document) != ["schema_version", "status", "gitframe_version", "capabilities"]
                or not schema_v1(document["schema_version"]) or document["status"] != "ok"):
            raise ValueError("capability terminal")
        validate_text(document["gitframe_version"], 256, False)
        entries = document["capabilities"]
        if not isinstance(entries, list) or len(entries) > 64:
            raise ValueError("capability collection")
        offered = {}
        previous = None
        for item in entries:
            if not isinstance(item, dict) or list(item) != ["name", "versions"]:
                raise ValueError("capability shape")
            name = item["name"]
            validate_text(name, 128, False)
            if previous is not None and name <= previous:
                raise ValueError("capability order")
            previous = name
            versions = item["versions"]
            if not isinstance(versions, list) or not versions or len(versions) > 16:
                raise ValueError("capability versions")
            last = 0
            for version in versions:
                if type(version) is not int or not 1 <= version <= 65535 or version <= last:
                    raise ValueError("capability version")
                last = version
            offered[name] = versions
        if any(version not in offered.get(name, ()) for name, version in required.items()):
            raise ValueError("missing capability")
    except (KeyError, TypeError, UnicodeError, ValueError) as error:
        raise Failure("incompatible_gitframe", message) from error


def target_snapshot(document):
    try:
        if (not isinstance(document, dict)
                or list(document) != ["schema_version", "status", "target", "display"]
                or type(document["schema_version"]) is not int
                or document["schema_version"] != TARGET_SCHEMA or document["status"] != "ok"):
            raise ValueError("target terminal")
        validate_target(document["target"])
        validate_display(document["display"], True)
    except (KeyError, TypeError, UnicodeError, ValueError) as error:
        raise Failure("invalid_target", "review-target did not return a valid target snapshot") from error
    display = document["display"]
    return document["target"], display if any(label is not None for label in display.values()) else None


def validate_text(value, maximum, multiline):
    if not isinstance(value, str):
        raise ValueError("text type")
    raw = value.encode("utf-8")
    if not raw or len(raw) > maximum:
        raise ValueError("text bound")
    for character in value:
        codepoint = ord(character)
        if (codepoint in (0x00, 0x1b, 0x0d, 0x7f) or 0x80 <= codepoint <= 0x9f
                or (codepoint < 0x20 and not (multiline and character in "\n\t"))):
            raise ValueError("text control")


def producer_argument(value):
    try:
        validate_text(value, 256, False)
    except (TypeError, UnicodeError, ValueError) as error:
        raise argparse.ArgumentTypeError("invalid producer metadata") from error
    return value


def validate_timestamp(value):
    if (not isinstance(value, str) or len(value) != 20 or value[4] != "-" or value[7] != "-"
            or value[10] != "T" or value[13] != ":" or value[16] != ":" or value[19] != "Z"):
        raise ValueError("timestamp shape")
    pieces = (value[0:4], value[5:7], value[8:10], value[11:13], value[14:16], value[17:19])
    if any(not piece.isascii() or not piece.isdecimal() for piece in pieces):
        raise ValueError("timestamp decimal")
    year, month, day, hour, minute, second = (int(piece) for piece in pieces)
    leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    days = (31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    if (year == 0 or not 1 <= month <= 12 or not 1 <= day <= days[month - 1]
            or hour > 23 or minute > 59 or second > 59):
        raise ValueError("timestamp value")


def validate_producer(value):
    order = ["name", "model", "version", "skill_version"]
    if (not isinstance(value, dict) or "name" not in value
            or list(value) != [key for key in order if key in value]):
        raise ValueError("producer shape")
    for field in value.values():
        validate_text(field, 256, False)


def parse_expected_publication(text):
    failure = Failure("invalid_expected_publication", "expected publication identity is invalid")
    if text is None:
        return None
    try:
        raw = text.encode("utf-8")
        if not raw or len(raw) > MAX_EXPECTED_PUBLICATION:
            raise ValueError("expected bound")
        value = json.loads(text, object_pairs_hook=no_duplicates, parse_constant=reject_json_constant)
        keys = ["review_repository_id", "target", "producer", "created_at", "finding_count",
            "manifest_sha256", "findings_sha256"]
        if not isinstance(value, dict) or list(value) != keys or encoded(value)[:-1] != raw:
            raise ValueError("expected shape")
        if not canonical_uuid_v4(value["review_repository_id"]):
            raise ValueError("repository ID")
        validate_target(value["target"])
        validate_producer(value["producer"])
        validate_timestamp(value["created_at"])
        count = value["finding_count"]
        if not isinstance(count, int) or isinstance(count, bool) or not 0 <= count <= 4096:
            raise ValueError("finding count")
        if not canonical_digest(value["manifest_sha256"]) or not canonical_digest(value["findings_sha256"]):
            raise ValueError("digest")
        return value
    except (KeyError, TypeError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise failure from error


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


def helper(gitframe, action, request=b"", timeout=120, cap=16384, error_codes=None):
    result = run([gitframe, *action], request, timeout, cap)
    if not result["started"]:
        raise Failure("helper_not_started", "GitFrame helper could not be started")
    if result["timeout"]:
        raise Failure("helper_timeout", "GitFrame helper timed out")
    if result["overflow"]:
        raise Failure("helper_output_limit", "GitFrame helper exceeded its output bound")
    if result["returncode"] != 0:
        code = None
        try:
            error_cap = min(cap, MAX_READ_HEADER) if error_codes is not None else cap
            terminal = strict_json(result["stdout"], error_cap)
            if error_codes is None:
                code = terminal.get("code") or terminal.get("error", {}).get("code")
            else:
                require_keys(terminal, ["status", "schema_version", "code", "message"])
                if (terminal["status"] == "error" and schema_v1(terminal["schema_version"])
                        and isinstance(terminal["code"], str)
                        and isinstance(terminal["message"], str)
                        and terminal["code"] in error_codes):
                    code = terminal["code"]
        except (KeyError, TypeError, Failure):
            pass
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
    require_capabilities(capabilities, CAPABILITIES,
        "GitFrame does not advertise the required review capability versions")
    head = args.head or "HEAD"
    target_doc = strict_json(helper(gitframe, ["review-target", "--repository", repository,
        "--source-kind", "branch_range", "--base", args.base, "--head", head]), 8192)
    target, display = target_snapshot(target_doc)
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
    producer = {"name": args.producer_name}
    if args.producer_model is not None:
        producer["model"] = args.producer_model
    if args.producer_version is not None:
        producer["version"] = args.producer_version
    producer["skill_version"] = SKILL_VERSION
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
                "request": {"base": args.base, "head": head}, "target": target}
            if display is not None:
                invocation["display"] = display
            invocation.update({
                "review_repository_id": prepared["review_repository_id"], "review_id": prepared["review_id"],
                "producer": producer, "input_size": len(review_input), "input_sha256": digest(review_input),
                "summary": input_doc["summary"], "units": inventory})
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


def invalid_result_frame():
    return Failure("invalid_result_frame", "GitFrame result frame is invalid")


def validate_result_frame(data, review_id, expected):
    failure = invalid_result_frame()
    try:
        newline = data.index(b"\n", 0, MAX_READ_HEADER) + 1
    except ValueError as error:
        raise failure from error
    try:
        header = strict_json(data[:newline], MAX_READ_HEADER)
        common = ["status", "schema_version", "review_repository_id", "review_id", "target",
            "findings_sha256", "finding_count"]
        completed = common + ["result_sha256", "result_size"]
        if list(header) not in (common, completed) or header["status"] not in ("pending", "completed"):
            raise ValueError("header shape")
        if ((header["status"] == "pending" and list(header) != common)
                or (header["status"] == "completed" and list(header) != completed)
                or not schema_v1(header["schema_version"])
                or not canonical_uuid_v4(header["review_repository_id"])
                or header["review_id"] != review_id or not canonical_uuid_v4(header["review_id"])
                or not canonical_digest(header["findings_sha256"])):
            raise ValueError("header identity")
        validate_target(header["target"])
        count = header["finding_count"]
        if not isinstance(count, int) or isinstance(count, bool) or not 0 <= count <= 4096:
            raise ValueError("finding count")
        if expected is not None and (header["review_repository_id"] != expected["review_repository_id"]
                or header["target"] != expected["target"]
                or header["findings_sha256"] != expected["findings_sha256"]
                or count != expected["finding_count"]):
            raise ValueError("expected identity")
        if header["status"] == "pending":
            if len(data) != newline:
                raise ValueError("pending payload")
            return data

        size = header["result_size"]
        if (not isinstance(size, int) or isinstance(size, bool) or not 1 <= size <= MAX_RESULT
                or len(data) != newline + size or not canonical_digest(header["result_sha256"])):
            raise ValueError("result length")
        payload = data[newline:]
        if digest(payload) != header["result_sha256"]:
            raise ValueError("result digest")
        result = strict_json(payload, MAX_RESULT)
        result_keys = ["schema_version", "review_id", "target", "findings_digest", "result",
            "completed_at"]
        if "summary" in result:
            result_keys.append("summary")
        result_keys.extend(["finding_dispositions", "anchored_notes"])
        if (list(result) != result_keys or not schema_v1(result["schema_version"])
                or result["review_id"] != review_id or result["target"] != header["target"]
                or result["findings_digest"] != header["findings_sha256"]
                or result["result"] not in ("approved", "needs_changes", "canceled")):
            raise ValueError("result identity")
        validate_target(result["target"])
        validate_timestamp(result["completed_at"])
        if "summary" in result:
            validate_text(result["summary"], 65536, True)
        dispositions = result["finding_dispositions"]
        notes = result["anchored_notes"]
        if (not isinstance(dispositions, list) or len(dispositions) != count
                or not isinstance(notes, list) or len(notes) > 4096):
            raise ValueError("result collections")
        for disposition in dispositions:
            if (not isinstance(disposition, dict)
                    or list(disposition) != ["finding_id", "disposition"]
                    or disposition["disposition"] not in ("accepted", "dismissed", "unreviewed")):
                raise ValueError("result disposition")
        return data
    except (KeyError, TypeError, UnicodeError, ValueError, Failure) as error:
        raise failure from error


def read_result(args):
    gitframe = validate_executable(args.gitframe)
    repository = validate_repository(args.repository)
    if not canonical_uuid_v4(args.review_id):
        raise Failure("invalid_review_id", "review ID is invalid")
    expected = parse_expected_publication(args.expected_publication_json)
    request = {"schema_version": SCHEMA, "repository": repository_read_wire(repository),
        "review_id": args.review_id}
    if expected is not None:
        request["expected"] = expected
    request_bytes = encoded(request)
    if not request_bytes or len(request_bytes) > MAX_READ_REQUEST:
        raise Failure("invalid_expected_publication", "expected publication identity is invalid")

    capabilities = strict_json(helper(gitframe, ["review-capabilities"], timeout=10,
        error_codes=frozenset()), MAX_READ_HEADER)
    require_capabilities(capabilities, {RESULT_CAPABILITY: 1},
        "GitFrame does not advertise result-read v1")
    frame = helper(gitframe, ["review-result-read"], request_bytes,
        cap=MAX_READ_HEADER + MAX_RESULT, error_codes=RESULT_ERROR_CODES)
    return validate_result_frame(frame, args.review_id, expected)


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
            "target"]
        if "display" in doc:
            keys.append("display")
        keys.extend(["review_repository_id", "review_id", "producer", "input_size", "input_sha256",
            "summary", "units"])
        require_keys(doc, keys)
        try:
            validate_target(doc["target"])
            if "display" in doc:
                validate_display(doc["display"], False)
        except (KeyError, TypeError, UnicodeError, ValueError) as error:
            raise Failure("invalid_handoff", "workspace target snapshot is invalid") from error
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
        "producer": invocation["producer"]}
    if "display" in invocation:
        header["display"] = {key: value for key, value in invocation["display"].items()
            if value is not None}
    header.update({"review_input_size": len(review_input),
        "candidate_sizes": [len(value) for value in candidates]}
    )
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
    start.add_argument("--producer-name", required=True, type=producer_argument)
    start.add_argument("--producer-model", type=producer_argument)
    start.add_argument("--producer-version", type=producer_argument)
    start.add_argument("--head")
    finish = actions.add_parser("complete")
    finish.add_argument("--workspace", required=True)
    finish.add_argument("--workspace-nonce", required=True)
    reader = actions.add_parser("read-result")
    reader.add_argument("--gitframe", required=True)
    reader.add_argument("--repository", required=True)
    reader.add_argument("--review-id", required=True)
    reader.add_argument("--expected-publication-json")
    return root


def main():
    try:
        args = parser().parse_args()
        if args.action == "read-result":
            sys.stdout.buffer.write(read_result(args))
            return 0
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
