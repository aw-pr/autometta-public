#!/usr/bin/env python3
"""EXPERIMENT, do not productionise: a bounded persistent Claude SDK controller.

This is intentionally separate from the tick loop. It retains one Agent SDK
session while polling a synthetic state file, runs a worker and verifier for
each pending synthetic stage, and stops at a hard wall-clock deadline.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import signal
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_STATE = Path("tests/sdk-controller-experiment/state.yaml")
DEFAULT_CAP_SECONDS = 1_500
DEFAULT_MODEL = "sonnet"


@dataclass
class CommandResult:
    """The SDK-visible result of one agent-run shell command."""

    completed: bool
    exit_status: int | None
    transcript: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the bounded persistent Claude Agent SDK controller experiment."
    )
    parser.add_argument(
        "stages",
        metavar="STAGE",
        nargs="+",
        type=Path,
        help="synthetic stage markdown files to run in order",
    )
    parser.add_argument(
        "--state",
        type=Path,
        default=DEFAULT_STATE,
        help=f"synthetic state file (default: {DEFAULT_STATE})",
    )
    parser.add_argument(
        "--cap-seconds",
        type=int,
        default=DEFAULT_CAP_SECONDS,
        help=f"hard wall-clock cap in seconds (default: {DEFAULT_CAP_SECONDS})",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Claude model alias for the retained SDK session (default: {DEFAULT_MODEL})",
    )
    return parser.parse_args()


def extract_section(markdown: str, heading: str) -> str:
    marker = f"## {heading}\n"
    try:
        after_heading = markdown.split(marker, 1)[1]
    except IndexError as exc:
        raise ValueError(f"stage is missing {marker.strip()!r}") from exc
    try:
        fenced = after_heading.split("```sh\n", 1)[1].split("\n```", 1)[0]
    except IndexError as exc:
        raise ValueError(f"stage {heading!r} must contain a shell code block") from exc
    return fenced.strip()


def load_stage(path: Path) -> dict[str, str]:
    content = path.read_text(encoding="utf-8")
    title = next((line[2:].strip() for line in content.splitlines() if line.startswith("# ")), "")
    if not title:
        raise ValueError(f"stage {path} has no title")
    stage_id = f"23-sdk-exp-{path.stem.removeprefix('stage-').lower()}"
    return {
        "id": stage_id,
        "title": title,
        "worker_command": extract_section(content, "Worker command"),
        "verifier_command": extract_section(content, "Verifier command"),
    }


def initialise_state(stages: list[dict[str, str]]) -> dict[str, Any]:
    now = timestamp()
    return {
        "version": 1,
        "current_stage": None,
        "stages": [
            {
                "id": stage["id"],
                "status": "pending",
                "worker": "Claude Agent SDK experiment",
                "verifier": "Claude Agent SDK experiment",
                "started_at": None,
                "completed_at": None,
                "stall_marker": None,
            }
            for stage in stages
        ],
        "last_tick_at": now,
        "tick_count": 0,
        "clock_tick_budget_remaining": len(stages),
    }


def write_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    state["last_tick_at"] = timestamp()
    path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")


def timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def block_text(block: Any) -> str:
    """Keep the shell result, including failures, visible in the run log."""

    name = type(block).__name__
    if name == "TextBlock":
        return f"assistant stdout: {block.text}"
    if name == "ToolUseBlock":
        return f"tool invocation: {block.name} {json.dumps(block.input, sort_keys=True)}"
    if name == "ToolResultBlock":
        content = block.content
        if isinstance(content, list):
            content = json.dumps(content, sort_keys=True)
        stream = "stderr" if block.is_error else "stdout"
        return f"tool {stream}: {content or '(empty)'}"
    return f"{name}: {block}"


async def run_command(client: Any, prompt: str) -> CommandResult:
    """Run one command through the retained SDK session and expose its outcome."""

    await client.query(prompt)
    transcript: list[str] = []
    exit_status: int | None = None
    completed = True
    async for message in client.receive_response():
        content = getattr(message, "content", None)
        if content:
            for block in content:
                line = block_text(block)
                transcript.append(line)
                if (
                    type(block).__name__ == "ToolResultBlock"
                    and not bool(getattr(block, "is_error", False))
                    and "SDK_EXPERIMENT_EXIT_STATUS=" in line
                ):
                    value = line.rsplit("SDK_EXPERIMENT_EXIT_STATUS=", 1)[1].split()[0]
                    try:
                        exit_status = int(value)
                    except ValueError:
                        completed = False
        if bool(getattr(message, "is_error", False)):
            completed = False
            errors = getattr(message, "errors", None)
            if errors:
                transcript.append(f"SDK result stderr: {'; '.join(errors)}")
        result = getattr(message, "result", None)
        if result:
            transcript.append(f"SDK result stdout: {result}")
    return CommandResult(
        completed=completed and exit_status is not None,
        exit_status=exit_status,
        transcript=transcript,
    )


def command_prompt(role: str, command: str) -> str:
    return f"""You are the {role} in a deliberately minimal controller experiment.
Use Bash to run the command below exactly once. Do not change it and do not
make any other file changes. Capture its exit status, standard output, and
standard error in the Bash tool result. The final Bash command must print
`SDK_EXPERIMENT_EXIT_STATUS=<status>` and return zero so this controller can
observe the command result rather than infer it from prose.

```sh
set +e
{{
{command}
}}
status=$?
printf 'SDK_EXPERIMENT_EXIT_STATUS=%s\n' "$status"
exit 0
```"""


def log_transcript(stage_id: str, role: str, result: CommandResult) -> None:
    status = "unknown" if result.exit_status is None else str(result.exit_status)
    print(f"{stage_id}: {role} exit_status={status} sdk_completed={result.completed}")
    for line in result.transcript:
        print(f"{stage_id}: {role}: {line}")


async def run(args: argparse.Namespace) -> int:
    if args.cap_seconds < 1:
        raise ValueError("--cap-seconds must be positive")
    stages = [load_stage(path) for path in args.stages]
    state = initialise_state(stages)
    write_state(args.state, state)
    stop_requested = asyncio.Event()

    def request_stop() -> None:
        stop_requested.set()

    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, request_stop)

    # Import only after argument parsing so --help remains dependency-free.
    from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

    options = ClaudeAgentOptions(
        tools=["Bash"],
        allowed_tools=["Bash"],
        permission_mode="bypassPermissions",
        cwd=Path.cwd(),
        model=args.model,
        max_turns=3,
        extra_args={"dangerously-skip-permissions": None},
    )

    async def run_session() -> None:
        async with ClaudeSDKClient(options=options) as client:
            for stage, record in zip(stages, state["stages"], strict=True):
                if stop_requested.is_set():
                    break

                state["current_stage"] = stage["id"]
                record["status"] = "in_progress"
                record["started_at"] = timestamp()
                state["tick_count"] += 1
                write_state(args.state, state)
                print(f"{stage['id']}: worker dispatched")

                worker = asyncio.create_task(
                    run_command(client, command_prompt("worker", stage["worker_command"]))
                )
                stop = asyncio.create_task(stop_requested.wait())
                done, _ = await asyncio.wait(
                    {worker, stop}, return_when=asyncio.FIRST_COMPLETED
                )
                stop.cancel()
                if stop in done:
                    worker.cancel()
                    record["status"] = "failed"
                    record["completed_at"] = timestamp()
                    record["stall_marker"] = "SIGTERM/SIGINT observed while worker was in progress"
                    state["current_stage"] = None
                    write_state(args.state, state)
                    print(f"{stage['id']}: failed: interrupted")
                    break

                worker_result = worker.result()
                log_transcript(stage["id"], "worker", worker_result)
                if not worker_result.completed or worker_result.exit_status != 0:
                    record["status"] = "failed"
                    record["completed_at"] = timestamp()
                    record["stall_marker"] = (
                        "worker failure: "
                        f"exit_status={worker_result.exit_status}, sdk_completed={worker_result.completed}"
                    )
                    state["current_stage"] = None
                    write_state(args.state, state)
                    print(f"{stage['id']}: failed: worker")
                    continue

                print(f"{stage['id']}: verifier dispatched")
                verifier_result = await run_command(
                    client, command_prompt("verifier", stage["verifier_command"])
                )
                log_transcript(stage["id"], "verifier", verifier_result)
                if not verifier_result.completed or verifier_result.exit_status != 0:
                    record["status"] = "failed"
                    record["stall_marker"] = (
                        "verifier failure: "
                        f"exit_status={verifier_result.exit_status}, sdk_completed={verifier_result.completed}"
                    )
                    print(f"{stage['id']}: failed: verifier")
                else:
                    record["status"] = "completed"
                    print(f"{stage['id']}: completed")
                record["completed_at"] = timestamp()
                state["current_stage"] = None
                write_state(args.state, state)

    print(
        f"SDK session started with model {args.model!r} "
        f"and hard cap {args.cap_seconds}s"
    )
    try:
        await asyncio.wait_for(run_session(), timeout=args.cap_seconds)
    except TimeoutError:
        active = next((record for record in state["stages"] if record["status"] == "in_progress"), None)
        if active is not None:
            active["status"] = "failed"
            active["completed_at"] = timestamp()
            active["stall_marker"] = "hard wall-clock cap reached"
        state["current_stage"] = None
        write_state(args.state, state)
        print("hard wall-clock cap reached; in-progress stage is recorded as failed")
        return 124

    if stop_requested.is_set():
        print("SDK session stopped by signal; in-progress stage is recorded as failed")
        return 143
    return 0 if all(record["status"] == "completed" for record in state["stages"]) else 1


def main() -> int:
    try:
        return asyncio.run(run(parse_args()))
    except (OSError, ValueError) as exc:
        print(f"controller-sdk-experiment: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
