#!/usr/bin/env python3
"""Codex SDK verifier entrypoint using the local Codex agent harness."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any


REQUIREMENTS = "scripts/requirements-sdk.txt"
DEFAULT_MODEL = "gpt-5.6-terra"
VERIFIER_IDENTITY = "Codex SDK verifier <openai-codex@local>"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a Codex SDK verifier against a stage card and artefacts."
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
        help="Notes from a partial worker handoff envelope, included in the per-stage prompt block.",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Codex model to use for verification (default: {DEFAULT_MODEL}).",
    )
    parser.add_argument(
        "--effort",
        default=None,
        help="Declared verifier effort, recorded in the prompt until the SDK exposes it as a thread option.",
    )
    return parser.parse_args()


def load_shared() -> Any:
    """Reuse the Claude SDK verifier's canonical rubric and schema handling."""
    path = Path(__file__).with_name("verify-sdk.py")
    spec = importlib.util.spec_from_file_location("autometta_verify_sdk", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load shared verifier helpers: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_codex() -> tuple[Any, Any]:
    try:
        from openai_codex import Codex, Sandbox
    except ImportError as exc:
        raise RuntimeError(
            f"missing openai-codex; install with: python3 -m pip install -r {REQUIREMENTS}"
        ) from exc
    return Codex, Sandbox


def usage_value(usage: Any, name: str) -> int:
    """Read a ThreadTokenUsage field without coupling to an SDK minor release."""
    if usage is None:
        return 0
    if isinstance(usage, dict):
        value = usage.get(name, 0)
    else:
        value = getattr(usage, name, 0)
    return int(value or 0)


def log_usage(usage: Any) -> None:
    """Emit both a comparable SDK line and the established Codex budget marker."""
    input_tokens = usage_value(usage, "input_tokens")
    cached_input_tokens = usage_value(usage, "cached_input_tokens")
    output_tokens = usage_value(usage, "output_tokens")
    total_tokens = usage_value(usage, "total_tokens")
    if not total_tokens:
        total_tokens = input_tokens + output_tokens
    print(
        "usage: "
        f"input={input_tokens} cached={cached_input_tokens} "
        f"output={output_tokens} total={total_tokens}",
        file=sys.stderr,
    )
    print("tokens used", file=sys.stderr)
    print(total_tokens, file=sys.stderr)


def run_sdk(prompt: str, model: str) -> tuple[str, Any]:
    Codex, Sandbox = load_codex()
    with Codex() as codex:
        thread = codex.thread_start(model=model, sandbox=Sandbox.read_only)
        result = thread.run(prompt)
    return result.final_response, getattr(result, "usage", None)


def main() -> int:
    args = parse_args()
    try:
        shared = load_shared()
        Validator = shared.load_jsonschema()
    except RuntimeError as exc:
        print(f"verify-sdk-openai: {exc}", file=sys.stderr)
        return 2

    card = Path(args.card)
    out = Path(args.out)
    try:
        if not card.is_file():
            print(f"verify-sdk-openai: stage card not found: {card}", file=sys.stderr)
            return 2
        artefacts = shared.find_artefacts(args.artefact_glob)
        static_block = shared.build_static_block(verifier_identity=VERIFIER_IDENTITY)
        variable_block = shared.build_variable_block(
            args.stage_id,
            card,
            artefacts,
            out,
            verifier_identity=VERIFIER_IDENTITY,
            worker_notes=args.worker_notes,
        ).replace("scripts/verify-sdk.py", "scripts/verify-sdk-openai.py")
        if args.effort:
            variable_block += f"\n- Declared verifier effort: `{args.effort}`\n"
        validator = Validator(shared.verifier_schema())
        text, usage = run_sdk(f"{static_block}\n\n{variable_block}", args.model)
        log_usage(usage)
        envelope = shared.validate_envelope(shared._extract_json(text), validator)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
        return 0 if envelope["overall"] == "PASS" else 1
    except shared.InvalidEnvelope as exc:
        invalid_path = Path(str(out) + ".invalid.json")
        invalid_path.parent.mkdir(parents=True, exist_ok=True)
        invalid_path.write_text(json.dumps(exc.data, indent=2) + "\n", encoding="utf-8")
        print(f"verify-sdk-openai: {exc}; wrote {invalid_path}", file=sys.stderr)
        return 3
    except RuntimeError as exc:
        print(f"verify-sdk-openai: {exc}", file=sys.stderr)
        return 2
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"verify-sdk-openai: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
