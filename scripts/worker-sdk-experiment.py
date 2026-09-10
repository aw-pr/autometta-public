#!/usr/bin/env python3
"""EXPERIMENT, do not productionise: Claude Agent SDK worker prototype.

This apparatus deliberately has no tick or LaunchAgent integration.  It runs
one synthetic worker in a throwaway directory, caps wall-clock time, and
records the SDK transcript plus a scratch-only liveness entry.
"""

from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from typing import Any


DEFAULT_CAP_SECONDS = 900
WORKER_IDENTITY = "Claude Agent SDK experiment <claude-agent-sdk@local>"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run one synthetic worker through the Claude Agent SDK."
    )
    parser.add_argument("--stage", required=True, type=Path, help="Synthetic stage card.")
    parser.add_argument(
        "--scratch",
        type=Path,
        default=None,
        help="Throwaway scoped worktree. A temporary directory is used when omitted.",
    )
    parser.add_argument("--log", type=Path, required=True, help="Transcript log path.")
    parser.add_argument("--model", default="sonnet", help="Claude model alias.")
    parser.add_argument(
        "--wall-clock-seconds",
        type=int,
        default=DEFAULT_CAP_SECONDS,
        help=f"Hard cap in seconds, at most 1800 (default: {DEFAULT_CAP_SECONDS}).",
    )
    return parser.parse_args()


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def append_log(path: Path, message: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(message.rstrip() + "\n")


def inside(path: str | Path, scope: Path) -> bool:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = scope / candidate
    try:
        candidate.resolve(strict=False).relative_to(scope.resolve())
    except ValueError:
        return False
    return True


def update_live_usage(registry: Path, usage: Any) -> None:
    """Write the card-91-shaped live totals to the scratch-only registry."""
    if not isinstance(usage, dict):
        return
    input_tokens = usage.get("input_tokens")
    output_tokens = usage.get("output_tokens")
    if input_tokens is None and output_tokens is None:
        return
    data = json.loads(registry.read_text(encoding="utf-8"))
    data.update(
        {
            "live_input_tokens": int(input_tokens or 0),
            "live_output_tokens": int(output_tokens or 0),
            "live_updated_at": now(),
        }
    )
    temporary = registry.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    temporary.replace(registry)


def validate_handoff(path: Path, expected_status: str) -> tuple[bool, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return False, f"handoff invalid: {exc}"
    required = {"stage_id", "status", "deliverables", "notes", "worker_identity"}
    if not required <= data.keys():
        return False, "handoff missing required worker-envelope fields"
    if data["status"] != expected_status:
        return False, f"handoff status is {data['status']!r}, expected {expected_status!r}"
    if not isinstance(data["deliverables"], list) or not isinstance(data["notes"], str):
        return False, "handoff has invalid deliverables or notes fields"
    return True, "handoff validates against the worker-envelope shape"


async def run(args: argparse.Namespace, scratch: Path) -> int:
    try:
        from claude_agent_sdk import (
            AssistantMessage,
            ClaudeAgentOptions,
            ClaudeSDKClient,
            PermissionResultAllow,
            PermissionResultDeny,
            ResultMessage,
            TextBlock,
            ToolUseBlock,
        )
    except ImportError as exc:
        print(f"worker-sdk-experiment: missing claude-agent-sdk: {exc}", file=sys.stderr)
        return 2

    stage = args.stage.resolve()
    if not stage.is_file():
        print(f"worker-sdk-experiment: stage card not found: {stage}", file=sys.stderr)
        return 2
    scratch.mkdir(parents=True, exist_ok=True)
    staged_card = scratch / "stage.md"
    shutil.copyfile(stage, staged_card)
    registry = scratch / "observability" / "active-agents" / f"{os.getpid()}.json"
    registry.parent.mkdir(parents=True, exist_ok=True)
    registry.write_text(
        json.dumps(
            {
                "pid": os.getpid(),
                "role": "worker",
                "family": "claude",
                "identity": WORKER_IDENTITY,
                "card_path": "stage.md",
                "log_path": str(args.log),
                "start_time": now(),
                "budget_seconds": args.wall_clock_seconds,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    async def can_use_tool(name: str, tool_input: dict[str, Any], _context: Any) -> Any:
        path = tool_input.get("file_path") or tool_input.get("path")
        if name in {"Write", "Edit", "Read", "Glob", "Grep"} and path and not inside(path, scratch):
            message = f"REFUSED out-of-scope {name}: {path} is outside scoped worktree {scratch}"
            append_log(args.log, message)
            return PermissionResultDeny(message=message)
        if name == "Bash":
            message = "REFUSED Bash: this prototype permits file tools only inside the scoped worktree"
            append_log(args.log, message)
            return PermissionResultDeny(message=message)
        return PermissionResultAllow()

    async def prompt_stream() -> Any:
        yield {
            "type": "user",
            "message": {
                "role": "user",
                "content": (
                    "You are a synthetic Autometta worker. Read stage.md in full. "
                    "Follow its requested deliverables and write its handoff yourself. "
                    "You may use only file tools and must remain inside the current worktree. "
                    "If a requested path is refused, write the in-tree handoff with status fail "
                    "and quote the refusal in its notes. Do not claim a refused file exists."
                ),
            },
            "parent_tool_use_id": None,
            "session_id": "default",
        }

    config_dir = scratch / ".claude-config"
    config_dir.mkdir(exist_ok=True)
    # op-fetch is the caller-owned auth boundary.  It may supply the
    # subscription OAuth token in this inherited environment; this prototype
    # neither reads credentials from disk nor resolves any secret itself.
    environment = dict(os.environ)
    environment["CLAUDE_CONFIG_DIR"] = str(config_dir)
    options = ClaudeAgentOptions(
        allowed_tools=["Read", "Write", "Edit", "Glob", "Grep"],
        cwd=scratch,
        env=environment,
        model=args.model,
        max_turns=12,
        can_use_tool=can_use_tool,
        setting_sources=[],
    )
    append_log(args.log, f"SDK worker started model={args.model} cap_seconds={args.wall_clock_seconds}")
    result: Any = None
    try:
        async with ClaudeSDKClient(options=options) as client:
            await client.query(prompt_stream())
            async with asyncio.timeout(args.wall_clock_seconds):
                async for message in client.receive_response():
                    if isinstance(message, AssistantMessage):
                        update_live_usage(registry, message.usage)
                        for block in message.content:
                            if isinstance(block, ToolUseBlock):
                                append_log(args.log, f"tool use: {block.name} {block.input}")
                            elif isinstance(block, TextBlock):
                                append_log(args.log, f"assistant: {block.text}")
                    elif isinstance(message, ResultMessage):
                        result = message
                        update_live_usage(registry, message.usage)
                        append_log(
                            args.log,
                            f"result: error={message.is_error} turns={message.num_turns} "
                            f"stop_reason={message.stop_reason}",
                        )
    except TimeoutError:
        append_log(args.log, "result: hard wall-clock cap reached")
        return 124
    except Exception as exc:
        append_log(args.log, f"result: SDK failure: {type(exc).__name__}: {exc}")
        return 1

    stage_text = staged_card.read_text(encoding="utf-8")
    expected_status = "fail" if "Expected handoff status: fail" in stage_text else "pass"
    handoff = scratch / "handoff.json"
    valid, reason = validate_handoff(handoff, expected_status)
    append_log(args.log, reason)
    if not valid:
        return 1
    if expected_status == "pass" and not (scratch / "deliverable.txt").is_file():
        append_log(args.log, "deliverable missing: deliverable.txt")
        return 1
    if expected_status == "fail" and "REFUSED out-of-scope Write" not in args.log.read_text(encoding="utf-8"):
        append_log(args.log, "expected out-of-scope refusal was not observed")
        return 1
    return 0 if result is not None and not result.is_error else 1


def main() -> int:
    args = parse_args()
    if not 1 <= args.wall_clock_seconds <= 1800:
        print("worker-sdk-experiment: --wall-clock-seconds must be 1..1800", file=sys.stderr)
        return 2
    scratch = args.scratch or Path(tempfile.mkdtemp(prefix="autometta-worker-sdk-"))
    return asyncio.run(run(args, scratch.resolve()))


if __name__ == "__main__":
    raise SystemExit(main())
