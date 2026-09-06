#!/usr/bin/env python3
"""Regression tests for the GitFrame AI review provenance hook."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "gitframe_ai_review_provenance.py"
PLUGIN_ROOT = SCRIPT.parent.parent
SPEC = importlib.util.spec_from_file_location("gitframe_ai_review_provenance", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load GitFrame AI review provenance hook")
hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hook)


class GitFrameAiReviewProvenanceTest(unittest.TestCase):
    def event(
        self,
        *,
        prompt: object = "$gitframe-ai-review main",
        model: object = "gpt-5.6-codex",
        event_name: object = "UserPromptSubmit",
    ) -> dict[str, object]:
        return {"hook_event_name": event_name, "prompt": prompt, "model": model}

    def run_script(self, payload: bytes) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT)],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_short_and_plugin_qualified_invocations_receive_exact_model(self) -> None:
        for prompt in (
            "$gitframe-ai-review main",
            "確認後に $gitframe:gitframe-ai-review を使ってください。",
        ):
            with self.subTest(prompt=prompt):
                response = hook.process_event(self.event(prompt=prompt))
                self.assertIsNotNone(response)
                context = response["hookSpecificOutput"]["additionalContext"]
                self.assertIn("producer name is codex", context)
                self.assertIn('"gpt-5.6-codex"', context)
                self.assertIn("--producer-model", context)

    def test_unrelated_and_lookalike_prompts_add_no_context(self) -> None:
        for prompt in (
            "普通のコードレビューをしてください",
            "gitframe-ai-reviewについて説明してください",
            "$gitframe-ai-reviewer main",
            "$other:gitframe-ai-review main",
        ):
            with self.subTest(prompt=prompt):
                self.assertIsNone(hook.process_event(self.event(prompt=prompt)))

    def test_invalid_event_or_model_adds_no_context(self) -> None:
        cases = (
            self.event(event_name="PreToolUse"),
            self.event(prompt=None),
            self.event(model=None),
            self.event(model=""),
            self.event(model="gpt\n5"),
            self.event(model="gpt\x1b5"),
            self.event(model="é" * 129),
            self.event(model="\ud800"),
        )
        for event in cases:
            with self.subTest(event=event):
                self.assertIsNone(hook.process_event(event))

    def test_command_emits_one_compact_response_and_fails_open(self) -> None:
        event = self.event(model="gpt-5.6-codex/high")
        completed = self.run_script(
            json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        )
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, b"")
        response = hook.process_event(event)
        expected = (
            json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        self.assertEqual(completed.stdout, expected)

        invalid_inputs = (
            b"not-json",
            b'{"hook_event_name":"UserPromptSubmit","model":"a","model":"b"}',
            b"{" + b" " * (hook.MAX_EVENT_BYTES + 1),
        )
        for payload in invalid_inputs:
            with self.subTest(size=len(payload)):
                completed = self.run_script(payload)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(completed.stdout, b"")
                self.assertEqual(completed.stderr, b"")

    def test_plugin_manifest_and_default_hook_discovery_are_wired(self) -> None:
        manifest = json.loads(
            (PLUGIN_ROOT / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["name"], "gitframe")
        self.assertEqual(manifest["skills"], "./skills/")
        self.assertNotIn("hooks", manifest)

        configuration = json.loads(
            (PLUGIN_ROOT / "hooks" / "hooks.json").read_text(encoding="utf-8")
        )
        command = configuration["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
        self.assertEqual(
            command,
            'python3 -I "$PLUGIN_ROOT/hooks/gitframe_ai_review_provenance.py"',
        )


if __name__ == "__main__":
    unittest.main()
