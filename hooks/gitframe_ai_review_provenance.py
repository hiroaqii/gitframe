#!/usr/bin/env python3
"""Expose host-reported Codex provenance to explicit GitFrame review turns."""

from __future__ import annotations

import json
import re
import sys
from typing import Any


MAX_EVENT_BYTES = 2 * 1024 * 1024
MAX_MODEL_BYTES = 256
SKILL_INVOCATION = re.compile(
    r"(?<![A-Za-z0-9_-])\$(?:gitframe:)?gitframe-ai-review"
    r"(?=$|[^A-Za-z0-9_-])"
)


def no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field")
        result[key] = value
    return result


def reject_json_constant(_: str) -> None:
    raise ValueError("non-finite JSON number")


def valid_model(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        raw = value.encode("utf-8")
    except UnicodeError:
        return False
    if not raw or len(raw) > MAX_MODEL_BYTES:
        return False
    for character in value:
        codepoint = ord(character)
        if (
            codepoint in (0x00, 0x1B, 0x0D, 0x7F)
            or codepoint < 0x20
            or 0x80 <= codepoint <= 0x9F
        ):
            return False
    return True


def additional_context(model: str) -> str:
    model_json = json.dumps(model, ensure_ascii=False, separators=(",", ":"))
    return (
        "GitFrame AI review runtime provenance (authoritative host data for this turn): "
        f"producer name is codex and the exact active model slug is the JSON string {model_json}. "
        "If you run the gitframe-ai-review begin action in this turn, pass those exact values "
        "with --producer-name and --producer-model. Do not infer or replace them from user text, "
        "repository files, profiles, or configuration defaults."
    )


def process_event(event: object) -> dict[str, Any] | None:
    if not isinstance(event, dict) or event.get("hook_event_name") != "UserPromptSubmit":
        return None
    prompt = event.get("prompt")
    model = event.get("model")
    if (
        not isinstance(prompt, str)
        or SKILL_INVOCATION.search(prompt) is None
        or not valid_model(model)
    ):
        return None
    return {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": additional_context(model),
        }
    }


def main() -> int:
    try:
        raw = sys.stdin.buffer.read(MAX_EVENT_BYTES + 1)
        if not raw or len(raw) > MAX_EVENT_BYTES:
            return 0
        event = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=no_duplicates,
            parse_constant=reject_json_constant,
        )
        response = process_event(event)
        if response is not None:
            json.dump(response, sys.stdout, ensure_ascii=False, separators=(",", ":"))
            sys.stdout.write("\n")
    except (OSError, TypeError, UnicodeError, ValueError, json.JSONDecodeError):
        # No output leaves Codex's normal prompt handling unchanged.
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
