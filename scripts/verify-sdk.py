#!/usr/bin/env python3
"""Prototype Claude Agent SDK verifier entrypoint."""

from __future__ import annotations

import argparse
import asyncio
import glob
import json
import os
from pathlib import Path
import sys
from typing import Any


REQUIREMENTS = "scripts/requirements-sdk.txt"
TEMPLATE = Path("templates/verifier-prompt.md")
VERIFIER_IDENTITY = "Claude Agent SDK verifier <claude-agent-sdk@local>"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a prototype Claude Agent SDK verifier against a stage card and artefacts."
    )
    parser.add_argument("--stage-id", required=True, help="Stage id for the verifier artefact.")
    parser.add_argument("--card", required=True, help="Path to the stage card to verify.")
    parser.add_argument(
        "--artefact-glob",
        required=True,
        help="Glob for worker artefacts to include in the verifier prompt.",
    )
    parser.add_argument("--out", required=True, help="Path to write the verifier JSON artefact.")
    return parser.parse_args()


def fail_env(message: str) -> int:
    print(f"verify-sdk: {message}", file=sys.stderr)
    return 2


def load_sdk() -> tuple[Any, Any]:
    try:
        from claude_agent_sdk import ClaudeAgentOptions, query
    except ImportError as exc:
        raise RuntimeError(
            f"missing claude-agent-sdk; install with: python3 -m pip install -r {REQUIREMENTS}"
        ) from exc
    return ClaudeAgentOptions, query


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def numbered(path: Path, text: str) -> str:
    lines = text.splitlines()
    if not lines:
        return f"### {path}\n(empty)\n"
    body = "\n".join(f"{idx}: {line}" for idx, line in enumerate(lines, start=1))
    return f"### {path}\n{body}\n"


def find_artefacts(pattern: str) -> list[Path]:
    matches = [Path(item) for item in glob.glob(pattern, recursive=True)]
    return sorted(path for path in matches if path.is_file())


def render_template(stage_id: str, card: Path, out: Path) -> str:
    template = read_text(TEMPLATE)
    return (
        template.replace("<<stage-id>>", stage_id)
        .replace("<<stage-card-path>>", str(card))
        .replace("<<artefact-path>>", str(out))
        .replace("<<verifier-tier>>", VERIFIER_IDENTITY)
        .replace("<<orchestrator-identity>>", "verify-sdk.py")
        .replace("<<family-specific-notes-or-none>>", "None")
    )


def verifier_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "stage_id": {"type": "string"},
            "verifier_identity": {"type": "string"},
            "verifier_invocation": {"type": "string"},
            "ran_at": {"type": "string"},
            "criteria": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "id": {"type": "integer"},
                        "name": {"type": "string"},
                        "verdict": {"type": "string", "enum": ["PASS", "FAIL"]},
                        "evidence": {"type": "string"},
                    },
                    "required": ["id", "name", "verdict", "evidence"],
                },
            },
            "additional_findings": {"type": "string"},
            "overall": {"type": "string", "enum": ["PASS", "FAIL"]},
        },
        "required": [
            "stage_id",
            "verifier_identity",
            "verifier_invocation",
            "ran_at",
            "criteria",
            "additional_findings",
            "overall",
        ],
    }


def build_prompt(stage_id: str, card: Path, artefacts: list[Path], out: Path) -> str:
    rendered = render_template(stage_id, card, out)
    artefact_sections = "\n".join(numbered(path, read_text(path)) for path in artefacts)
    if not artefact_sections:
        artefact_sections = "(no artefacts matched the supplied glob)\n"

    return f"""{rendered}

## SDK wrapper instruction

This prototype wrapper, not the agent, writes `{out}`. Return exactly the JSON report matching the output contract. Do not ask to run tools. Evaluate only the stage card and artefact contents supplied below.

Use:

- `stage_id`: `{stage_id}`
- `verifier_identity`: `{VERIFIER_IDENTITY}`
- `verifier_invocation`: `scripts/verify-sdk.py --stage-id {stage_id} --card {card} --artefact-glob <redacted> --out {out}`

## Stage card with line numbers

{numbered(card, read_text(card))}

## Worker artefacts with line numbers

{artefact_sections}
"""


def validate_envelope(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict):
        raise ValueError("structured output is not a JSON object")
    expected = {
        "stage_id",
        "verifier_identity",
        "verifier_invocation",
        "ran_at",
        "criteria",
        "additional_findings",
        "overall",
    }
    actual = set(data)
    if actual != expected:
        missing = ", ".join(sorted(expected - actual)) or "none"
        extra = ", ".join(sorted(actual - expected)) or "none"
        raise ValueError(f"unexpected verifier JSON keys; missing={missing}; extra={extra}")
    if data["overall"] not in {"PASS", "FAIL"}:
        raise ValueError("overall must be PASS or FAIL")
    if not isinstance(data["criteria"], list):
        raise ValueError("criteria must be an array")
    for item in data["criteria"]:
        if not isinstance(item, dict):
            raise ValueError("criteria entries must be objects")
        if set(item) != {"id", "name", "verdict", "evidence"}:
            raise ValueError("criteria entries must contain id, name, verdict, evidence")
        if item["verdict"] not in {"PASS", "FAIL"}:
            raise ValueError("criteria verdict must be PASS or FAIL")
    return data


async def run_sdk(prompt: str, sdk: tuple[Any, Any]) -> dict[str, Any]:
    ClaudeAgentOptions, query = sdk
    options = ClaudeAgentOptions(
        allowed_tools=[],
        output_format={"type": "json_schema", "schema": verifier_schema()},
        cwd=str(Path.cwd()),
        setting_sources=[],
    )
    result_message = None
    async for message in query(prompt=prompt, options=options):
        if hasattr(message, "structured_output") or hasattr(message, "result"):
            result_message = message

    if result_message is None:
        raise ValueError("SDK returned no result message")
    structured = getattr(result_message, "structured_output", None)
    if structured is None:
        result = getattr(result_message, "result", None)
        if not result:
            raise ValueError("SDK returned no structured output")
        structured = json.loads(result)
    return validate_envelope(structured)


def main() -> int:
    args = parse_args()

    try:
        sdk = load_sdk()
    except RuntimeError as exc:
        print(f"verify-sdk: {exc}", file=sys.stderr)
        return 2

    try:
        anthropic_api_key = os.environ["ANTHROPIC_API_KEY"]
    except KeyError:
        return fail_env("missing ANTHROPIC_API_KEY; inject it with op-fetch before running")
    if not anthropic_api_key:
        return fail_env("missing ANTHROPIC_API_KEY; inject it with op-fetch before running")

    card = Path(args.card)
    out = Path(args.out)
    try:
        if not card.is_file():
            return fail_env(f"stage card not found: {card}")
        if not TEMPLATE.is_file():
            return fail_env(f"verifier prompt template not found: {TEMPLATE}")

        artefacts = find_artefacts(args.artefact_glob)
        prompt = build_prompt(args.stage_id, card, artefacts, out)
        envelope = asyncio.run(run_sdk(prompt, sdk))
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
        return 0 if envelope["overall"] == "PASS" else 1
    except RuntimeError as exc:
        print(f"verify-sdk: {exc}", file=sys.stderr)
        return 2
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"verify-sdk: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
