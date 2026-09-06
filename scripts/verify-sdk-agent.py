#!/usr/bin/env python3
"""Claude Agent SDK verifier entrypoint, authenticated with the subscription route."""

from __future__ import annotations

import argparse
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any


REQUIREMENTS = "scripts/requirements-sdk.txt"
# This entrypoint is the agent-sdk surface: it imports claude_agent_sdk, the
# Claude Code harness as a library, and authenticates the way the `claude`
# binary does -- on CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY, whichever
# op-fetch placed in this process's env. It is not the api-sdk
# (scripts/verify-sdk.py, which imports `anthropic` and calls the raw
# Messages API), whatever a filename saying "sdk" might suggest -- see
# docs/sdk-verifier.md for why that ambiguity is load-bearing.
VERIFIER_IDENTITY = "Claude Agent SDK verifier <claude-agent-sdk@local>"
MODEL = "claude-sonnet-5"


def load_shared() -> Any:
    """Reuse the api-sdk verifier's rubric, schema and envelope handling.

    Loading the module only runs its top-level code -- `anthropic` is
    imported lazily inside its load_anthropic(), which this entrypoint never
    calls, so this stays true to "imports claude_agent_sdk, not anthropic".
    """
    path = Path(__file__).resolve().with_name("verify-sdk.py")
    spec = importlib.util.spec_from_file_location("autometta_verify_sdk", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load shared verifier helpers: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_agent_sdk() -> Any:
    try:
        import claude_agent_sdk
    except ImportError as exc:
        raise RuntimeError(
            f"missing claude-agent-sdk; install with: python3 -m pip install -r {REQUIREMENTS}"
        ) from exc
    return claude_agent_sdk


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a Claude Agent SDK verifier against a stage card and artefacts."
    )
    parser.add_argument("--stage-id", required=True, help="Stage id for the verifier artefact.")
    parser.add_argument("--card", required=True, help="Path to the stage card to verify.")
    parser.add_argument(
        "--artefact-glob",
        required=True,
        help="Glob for worker artefacts to include in the verifier prompt.",
    )
    parser.add_argument("--out", required=True, help="Path to write the verifier JSON artefact.")
    parser.add_argument(
        "--worker-notes",
        default=None,
        help=(
            "Notes from a dispatch envelope whose status was partial, surfaced "
            "to the verifier as a checklist of the criteria the worker "
            "deferred."
        ),
    )
    parser.add_argument(
        "--model",
        default=MODEL,
        help=f"Claude model to use for verification (default: {MODEL}).",
    )
    parser.add_argument(
        "--effort",
        default=None,
        help="Optional Claude effort level supplied by the card's Verifier effort field.",
    )
    return parser.parse_args()


def fail_env(message: str) -> int:
    print(f"verify-sdk-agent: {message}", file=sys.stderr)
    return 2


async def run_agent_sdk(
    agent_sdk: Any,
    shared: Any,
    prompt: str,
    model: str,
    effort: str | None,
    schema: dict[str, Any],
) -> Any:
    """Drive one stateless Agent SDK turn and return the final ResultMessage.

    ``tools=[]`` sends the CLI ``--tools ""``: no filesystem, network or Bash
    access. This entrypoint reasons over the prompt text alone, the same
    contract verify-sdk.py has with the raw Messages API -- it does not give
    the verifier the filesystem-browsing access card 98's worker prototype
    grants a worker, which is out of scope here. ``output_format`` asks the
    CLI for schema-conformant structured output directly (its own
    ``--json-schema`` flag) rather than parsing JSON out of prose.
    """
    options = agent_sdk.ClaudeAgentOptions(
        model=model,
        effort=effort,
        tools=[],
        max_turns=1,
        setting_sources=[],
        output_format={"type": "json_schema", "schema": schema},
    )
    result: Any = None
    live_input = 0
    async for message in agent_sdk.query(prompt=prompt, options=options):
        if isinstance(message, agent_sdk.ResultMessage):
            result = message
            live_input, live_output = shared.live_anthropic_usage(message.usage, live_input)
            shared.update_live_usage(live_input, live_output)
    return result


def main() -> int:
    args = parse_args()

    try:
        agent_sdk = load_agent_sdk()
        shared = load_shared()
        Validator = shared.load_jsonschema()
    except RuntimeError as exc:
        return fail_env(str(exc))

    card = Path(args.card)
    out = Path(args.out)
    model = args.model
    effort = args.effort

    try:
        if not card.is_file():
            return fail_env(f"stage card not found: {card}")
        if not shared.TEMPLATE.is_file():
            return fail_env(f"verifier prompt template not found: {shared.TEMPLATE}")
        if not shared.SCHEMA.is_file():
            return fail_env(f"verifier schema not found: {shared.SCHEMA}")

        artefacts = shared.find_artefacts(args.artefact_glob)
        static_block = shared.build_static_block(verifier_identity=VERIFIER_IDENTITY)
        variable_block = shared.build_variable_block(
            args.stage_id,
            card,
            artefacts,
            out,
            verifier_identity=VERIFIER_IDENTITY,
            worker_notes=args.worker_notes,
        ).replace("scripts/verify-sdk.py", "scripts/verify-sdk-agent.py")
        schema = shared.verifier_schema()
        validator = Validator(schema)
        prompt = f"{static_block}\n\n{variable_block}"

        result = asyncio.run(run_agent_sdk(agent_sdk, shared, prompt, model, effort, schema))

        if result is None:
            raise ValueError("Agent SDK turn produced no result message")
        input_tokens, output_tokens = shared.live_anthropic_usage(result.usage, 0)
        print(f"Total tokens: {input_tokens + output_tokens}", file=sys.stderr)
        if result.is_error:
            raise ValueError(
                f"Agent SDK turn returned an error: subtype={result.subtype} "
                f"stop_reason={result.stop_reason}"
            )

        data = result.structured_output
        if data is None:
            data = shared._extract_json(result.result or "")
        envelope = shared.validate_envelope(data, validator)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
        return 0 if envelope["overall"] == "PASS" else 1
    except RuntimeError as exc:
        print(f"verify-sdk-agent: {exc}", file=sys.stderr)
        return 2
    except shared.InvalidEnvelope as exc:
        invalid_path = Path(str(out) + ".invalid.json")
        invalid_path.parent.mkdir(parents=True, exist_ok=True)
        invalid_path.write_text(json.dumps(exc.data, indent=2) + "\n", encoding="utf-8")
        print(f"verify-sdk-agent: {exc}; wrote {invalid_path}", file=sys.stderr)
        return 3
    except ValueError as exc:
        print(f"verify-sdk-agent: {exc}", file=sys.stderr)
        return 1
    except (OSError, json.JSONDecodeError) as exc:
        print(f"verify-sdk-agent: {exc}", file=sys.stderr)
        return 1
    except agent_sdk.ClaudeSDKError as exc:
        print(f"verify-sdk-agent: agent sdk transport failure: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
