#!/usr/bin/env python3
"""
Developer-only non-interactive flow runner for real codex/claude wrappers.

Uses:
- codex exec --json / codex exec resume --json
- claude --print --output-format stream-json --verbose

This bypasses interactive TUI issues while still exercising real models and
session persistence / resume behavior.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WRAPPER_BIN = ROOT / "scripts" / "wrappers" / "bin"

DEFAULT_MODELS = {
    "claude": "claude-haiku-4-5",
    "codex": "gpt-5.1-codex-mini",
}

DEFAULT_MODEL_CANDIDATES = {
    "codex": [
        "gpt-5.1-codex-mini",
        "gpt-5.2-codex",
        "gpt-5.4-mini",
        "gpt-5.4",
    ],
}


def parse_jsonl(text: str) -> list[dict]:
    items: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            items.append(json.loads(line))
        except Exception:
            items.append({"decode_error": line})
    return items


def summarize_events(items: list[dict]) -> list[dict]:
    summary: list[dict] = []
    for item in items:
        row: dict = {"type": item.get("type")}
        if "thread_id" in item:
            row["thread_id"] = item.get("thread_id")
        if "session_id" in item:
            row["session_id"] = item.get("session_id")
        if item.get("type") == "error":
            row["message"] = item.get("message")
        if item.get("type") == "result":
            row["subtype"] = item.get("subtype")
            row["is_error"] = item.get("is_error")
            row["result"] = item.get("result")
            row["stop_reason"] = item.get("stop_reason")
        if item.get("type") == "turn.failed":
            error = item.get("error") or {}
            row["message"] = error.get("message")
        if item.get("type") == "item.completed":
            payload = item.get("item") or {}
            row["item_type"] = payload.get("type")
            row["text"] = payload.get("text")
        summary.append(row)
    return summary


def codex_run(model: str, prompt: str, resume_id: str | None = None) -> tuple[int, list[dict], str]:
    cmd = [str(WRAPPER_BIN / "codex"), "exec", "--json", "--model", model]
    if resume_id:
        cmd.extend(["resume", resume_id, prompt])
    else:
        cmd.append(prompt)
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=os.environ.copy(),
    )
    events = parse_jsonl(proc.stdout)
    session_id = resume_id or next((item.get("thread_id") for item in events if item.get("type") == "thread.started"), None) or ""
    return proc.returncode, events, session_id


def claude_run(model: str, prompt: str, resume_id: str | None = None) -> tuple[int, list[dict], str]:
    cmd = [
        str(WRAPPER_BIN / "claude"),
        "--print",
        "--verbose",
        "--output-format",
        "stream-json",
        "--include-hook-events",
        "--model",
        model,
    ]
    if resume_id:
        cmd.extend(["--resume", resume_id])
    cmd.append(prompt)
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=os.environ.copy(),
    )
    events = parse_jsonl(proc.stdout)
    session_id = resume_id or next((item.get("session_id") for item in events if item.get("type") == "system" and item.get("subtype") == "init"), None) or ""
    return proc.returncode, events, session_id


def run_flow(tool: str, model: str) -> int:
    run = claude_run if tool == "claude" else codex_run
    prompts = [
        "Reply with exactly FIRST.",
        "Reply with exactly SECOND.",
    ]

    report: dict = {"tool": tool, "model": model, "steps": []}

    code, events, session_id = run(model, prompts[0], None)
    report["steps"].append({
        "name": "fresh_prompt_1",
        "exit_code": code,
        "session_id": session_id,
        "events": summarize_events(events),
    })
    if code != 0 or not session_id:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 1

    code, events, _ = run(model, prompts[1], session_id)
    report["steps"].append({
        "name": "resume_prompt_2",
        "exit_code": code,
        "session_id": session_id,
        "events": summarize_events(events),
    })

    fresh_prompt = "Reply with exactly FRESH."
    code_fresh, fresh_events, fresh_session = run(model, fresh_prompt, None)
    report["steps"].append({
        "name": "fresh_after_resume",
        "exit_code": code_fresh,
        "session_id": fresh_session,
        "events": summarize_events(fresh_events),
    })

    code_hist, hist_events, _ = run(model, "Reply with exactly HISTORY.", session_id)
    report["steps"].append({
        "name": "resume_history_again",
        "exit_code": code_hist,
        "session_id": session_id,
        "events": summarize_events(hist_events),
    })

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if all(step["exit_code"] == 0 for step in report["steps"]) else 1


def run_flow_with_candidates(tool: str, explicit_model: str | None) -> int:
    if tool != "codex":
        return run_flow(tool, explicit_model or DEFAULT_MODELS[tool])

    candidates = [explicit_model] if explicit_model else DEFAULT_MODEL_CANDIDATES["codex"]
    attempts: list[dict] = []
    for model in candidates:
        report: dict = {"tool": tool, "model": model, "steps": []}
        prompts = [
            "Reply with exactly FIRST.",
            "Reply with exactly SECOND.",
        ]

        code, events, session_id = codex_run(model, prompts[0], None)
        report["steps"].append({
            "name": "fresh_prompt_1",
            "exit_code": code,
            "session_id": session_id,
            "events": summarize_events(events),
        })
        if code != 0 or not session_id:
            attempts.append(report)
            continue

        code, events, _ = codex_run(model, prompts[1], session_id)
        report["steps"].append({
            "name": "resume_prompt_2",
            "exit_code": code,
            "session_id": session_id,
            "events": summarize_events(events),
        })

        fresh_prompt = "Reply with exactly FRESH."
        code_fresh, fresh_events, fresh_session = codex_run(model, fresh_prompt, None)
        report["steps"].append({
            "name": "fresh_after_resume",
            "exit_code": code_fresh,
            "session_id": fresh_session,
            "events": summarize_events(fresh_events),
        })

        code_hist, hist_events, _ = codex_run(model, "Reply with exactly HISTORY.", session_id)
        report["steps"].append({
            "name": "resume_history_again",
            "exit_code": code_hist,
            "session_id": session_id,
            "events": summarize_events(hist_events),
        })

        if all(step["exit_code"] == 0 for step in report["steps"]):
            print(json.dumps(report, ensure_ascii=False, indent=2))
            return 0
        attempts.append(report)
    print(json.dumps({"tool": tool, "attempts": attempts}, ensure_ascii=False, indent=2))
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", choices=["claude", "codex"], required=True)
    parser.add_argument("--model", default=None)
    args = parser.parse_args()
    if args.tool == "codex":
        return run_flow_with_candidates(args.tool, args.model)
    model = args.model or DEFAULT_MODELS[args.tool]
    return run_flow(args.tool, model)


if __name__ == "__main__":
    raise SystemExit(main())
