#!/usr/bin/env python3
"""Single-shot verifier caller for card 46's bake-off.

Every candidate in the bake-off — local Ollama weights and the cloud free
tiers — speaks an OpenAI-compatible chat-completions endpoint, so one caller
covers all of them: a base URL, an optional API-key env var name, and a
model id per candidate. This mirrors the shape deliverable 2 asks for
("one caller with a base URL and key name per provider covers both") and
extends it to local for the reason recorded in docs/verifier-bake-off.md:
free-tier caps force cloud candidates into single-shot mode, and running
local candidates through the same single-shot caller keeps the comparison
apples-to-apples (identical packaged evidence, identical scoring code)
rather than comparing an agentic local run against a single-shot cloud run.

Packaging is reused from verify-sdk.py rather than re-derived: same static
rubric block (schema, dispatch-contract reminders) and variable block
(numbered card + artefacts), loaded dynamically since verify-sdk.py's
filename is not an importable module name.

Route isolation: this script reads ONLY the one API-key env var its
provider needs (--api-key-env), never a hardcoded name, so a caller
dispatched via `op-fetch NAME=ref -- ...` can never reach for a name
op-fetch did not inject. No provider branch reads OPENAI_API_KEY or
ANTHROPIC_API_KEY.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
VERIFY_SDK_PATH = SCRIPT_DIR / "verify-sdk.py"
# Several free candidates (gpt-oss, Nemotron) are reasoning models whose
# hidden "thinking" tokens count against max_tokens before any content is
# emitted. A first pass at 4096 (verify-sdk.py's Claude-tuned figure)
# truncated Nemotron mid-JSON on the very first live call — completion_tokens
# hit 4096 exactly with no closing brace. 8192 plus damping the reasoning
# effort below (both providers that support it) is the fix that survived
# testing; see docs/verifier-bake-off.md.
MAX_TOKENS = 8192
# A distinctive UA. Groq fronts api.groq.com with Cloudflare, and Cloudflare's
# bot heuristics 403 the bare "Python-urllib/3.x" default signature with a
# body that looks like an auth failure ("error code: 1010") — nothing to do
# with the key. curl and a non-default UA both pass. Set on every request,
# not just Groq's, so the behaviour is uniform and the next provider that
# fronts with Cloudflare does not silently repeat the same debugging loop.
USER_AGENT = "autometta-verifier-bake-off/1.0"
# Local weights advertise 32k-128k context depending on model; Ollama's
# OpenAI-compatible endpoint otherwise falls back to a much smaller default
# window that truncates a stage card plus artefacts without any error,
# silently dropping evidence rather than failing closed.
LOCAL_NUM_CTX = 32768


def load_verify_sdk() -> Any:
    spec = importlib.util.spec_from_file_location("verify_sdk", VERIFY_SDK_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {VERIFY_SDK_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run one bake-off candidate over one benchmark stage via a single-shot OpenAI-compatible call."
    )
    parser.add_argument("--stage-id", required=True)
    parser.add_argument("--card", required=True, help="Path to the stage card (in the benchmark repo).")
    parser.add_argument(
        "--artefact-glob",
        required=True,
        help="Glob (relative to --repo-root) for deliverable files to package as evidence.",
    )
    parser.add_argument("--repo-root", required=True, help="Benchmark repo root; artefact globs resolve relative to this.")
    parser.add_argument("--out", required=True, help="Path to write the schema-shaped verdict JSON.")
    parser.add_argument("--meta-out", required=True, help="Path to write bake-off-only metadata (timing, tokens, provider).")
    parser.add_argument("--candidate", required=True, help="Candidate name, e.g. local/qwen3-coder:30b or openrouter/....")
    parser.add_argument("--provider", required=True, choices=["local", "groq", "openrouter"])
    parser.add_argument("--base-url", required=True, help="OpenAI-compatible base URL, e.g. http://localhost:11434/v1")
    parser.add_argument("--model", required=True, help="Model id as the provider expects it.")
    parser.add_argument(
        "--api-key-env",
        default="",
        help="Env var name holding this provider's API key. Empty for local (no key needed).",
    )
    parser.add_argument("--timeout-seconds", type=int, default=180)
    return parser.parse_args()


def fail_env(message: str) -> int:
    print(f"verifier-bake-off-caller: {message}", file=sys.stderr)
    return 2


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def extract_json_lenient(text: str) -> Any:
    """Parse JSON out of an open-weight model's response.

    verify-sdk.py's _extract_json only strips a fence when the response
    *starts* with one, which is enough for Claude but not for local/free
    candidates, which routinely preface the fence with a sentence of prose
    despite the static block's "no prose outside the JSON" instruction —
    that instruction-following gap is itself part of what "artefact
    discipline" measures, so failing to parse it would undercount every
    candidate that adds a preamble rather than score it accurately. Try, in
    order: verify-sdk's strict parse, a fenced block found anywhere in the
    text, then the outermost balanced {...} found by bracket counting.
    """
    stripped = text.strip()
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass

    fence_match = re.search(r"```(?:json)?\s*\n(.*?)```", stripped, re.DOTALL)
    if fence_match:
        try:
            return json.loads(fence_match.group(1).strip())
        except json.JSONDecodeError:
            pass

    start = stripped.find("{")
    if start != -1:
        depth = 0
        for idx in range(start, len(stripped)):
            char = stripped[idx]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    candidate = stripped[start : idx + 1]
                    return json.loads(candidate)
        raise ValueError("unbalanced braces: no matching close for the first '{'")

    raise ValueError("no JSON object found in response text")


class RateLimited(RuntimeError):
    """A provider's per-minute cap (requests or tokens) was hit.

    Distinguished from other failures so the caller can apply the card's
    stated rule — sleep and retry once within the same minute window,
    otherwise treat it as the daily stop — rather than just counting it as
    a candidate judgement failure.
    """


def estimate_tokens(text: str) -> int:
    """~3.3 characters/token. Code- and schema-heavy text (this prompt is
    both) tokenizes denser than the usual 4-chars/token prose rule of
    thumb; a first pass at /4 still underestimated Groq's own count enough
    to get a "too large" 413 at a computed max_tokens that looked safe.
    Deliberately biased to overestimate (-> a smaller max_tokens headroom)
    rather than risk it again. Only used for Groq's TPM budgeting."""
    return int(len(text) / 3.3)


GROQ_TPM_CEILING = 8000
# Safety margin below Groq's stated ceiling: the estimate above is
# approximate, not Groq's real tokenizer, so this absorbs the gap.
GROQ_TPM_TARGET = 7200
GROQ_MIN_COMPLETION_TOKENS = 768


class RequestTooLargeForProvider(RuntimeError):
    """Even the floor completion budget would not fit under the provider's
    per-minute token ceiling for this stage's evidence. Distinguished from
    RateLimited: retrying an inherently oversized request cannot succeed,
    so the caller should record this as a capacity finding and move on
    without wasting a 65s backoff on a request that will fail identically."""


def call_chat_completions(
    base_url: str,
    model: str,
    api_key: str | None,
    provider: str,
    system_text: str,
    user_text: str,
    timeout_seconds: int,
) -> tuple[dict[str, Any], float]:
    max_tokens = MAX_TOKENS
    if provider == "groq":
        # Groq's on-demand tier caps openai/gpt-oss-120b at 8000 tokens per
        # minute, and — confirmed on live 413s — that ceiling is judged
        # against (prompt tokens + requested max_tokens), not prompt tokens
        # alone. A fixed MAX_TOKENS that works for other providers gets a
        # request this size rejected outright before Groq does any work.
        # Reserve max_tokens as whatever headroom is left under the ceiling
        # instead, floored so a real answer (even a truncated one, which
        # still counts as an artefact-discipline data point) has a chance.
        prompt_estimate = estimate_tokens(system_text) + estimate_tokens(user_text)
        if prompt_estimate + GROQ_MIN_COMPLETION_TOKENS > GROQ_TPM_TARGET:
            raise RequestTooLargeForProvider(
                f"estimated prompt ~{prompt_estimate} tokens leaves no room under Groq's "
                f"{GROQ_TPM_CEILING}/min ceiling even at the {GROQ_MIN_COMPLETION_TOKENS}-token completion floor"
            )
        max_tokens = max(GROQ_MIN_COMPLETION_TOKENS, GROQ_TPM_TARGET - prompt_estimate)

    payload: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_text},
            {"role": "user", "content": user_text},
        ],
        "max_tokens": max_tokens,
    }
    if not api_key:
        # Local-only extension: Ollama's OpenAI-compatible endpoint accepts an
        # "options" passthrough to its native /api/chat options. Cloud
        # providers reject unknown fields on some models, so this is sent
        # only when there is no API key, i.e. only on the local route.
        payload["options"] = {"num_ctx": LOCAL_NUM_CTX}
    elif provider == "groq":
        # gpt-oss's hidden reasoning tokens count against max_tokens and
        # exhausted it on a live test before any JSON was emitted (see
        # MAX_TOKENS comment). Groq's own effort knob for gpt-oss.
        payload["reasoning_effort"] = "low"
    elif provider == "openrouter":
        # OpenRouter's unified reasoning-model knob; Nemotron truncated
        # mid-object at the default effort on a live test.
        payload["reasoning"] = {"effort": "low"}

    body = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json", "User-Agent": USER_AGENT}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    request = urllib.request.Request(f"{base_url}/chat/completions", data=body, headers=headers)
    start = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:2000]
        if exc.code == 429 or (exc.code == 413 and "tokens per minute" in detail.lower()):
            raise RateLimited(f"HTTP {exc.code} from {base_url}: {detail}") from None
        raise RuntimeError(f"HTTP {exc.code} from {base_url}: {detail}") from None
    elapsed = time.monotonic() - start
    return data, elapsed


def main() -> int:
    args = parse_args()

    api_key = ""
    if args.api_key_env:
        api_key = os.environ.get(args.api_key_env, "")
        if not api_key:
            return fail_env(f"missing {args.api_key_env}; inject it with op-fetch before running")

    card = Path(args.card)
    out = Path(args.out)
    meta_out = Path(args.meta_out)

    if not card.is_file():
        return fail_env(f"stage card not found: {card}")

    try:
        verify_sdk = load_verify_sdk()
        Validator = verify_sdk.load_jsonschema()
    except RuntimeError as exc:
        print(f"verifier-bake-off-caller: {exc}", file=sys.stderr)
        return 2

    repo_root = Path(args.repo_root)
    cwd = Path.cwd()
    try:
        os.chdir(repo_root)
        artefacts = verify_sdk.find_artefacts(args.artefact_glob)
    finally:
        os.chdir(cwd)
    artefacts = [repo_root / p for p in artefacts]

    verifier_identity = f"Bake-off candidate: {args.candidate} <bake-off@local>"
    static_block = verify_sdk.build_static_block(verifier_identity=verifier_identity)
    variable_block = verify_sdk.build_variable_block(
        args.stage_id,
        card,
        artefacts,
        out,
        verifier_identity=verifier_identity,
    )
    validator = Validator(verify_sdk.verifier_schema())

    try:
        try:
            response, elapsed = call_chat_completions(
                args.base_url,
                args.model,
                api_key,
                args.provider,
                static_block,
                variable_block,
                args.timeout_seconds,
            )
        except RateLimited as exc:
            # The card's stated rule: a 429 (or, empirically, Groq's 413
            # tokens-per-minute variant) is the daily stop unless the cap is
            # a per-minute one, in which case wait out the window and retry
            # once before giving up on this (candidate, stage) pair.
            print(f"verifier-bake-off-caller: rate limited, waiting 65s and retrying once: {exc}", file=sys.stderr)
            time.sleep(65)
            response, elapsed = call_chat_completions(
                args.base_url,
                args.model,
                api_key,
                args.provider,
                static_block,
                variable_block,
                args.timeout_seconds,
            )
    except RequestTooLargeForProvider as exc:
        # No request was sent — this stage's packaged evidence alone does
        # not fit under the provider's per-minute token ceiling, at any
        # completion budget. A capacity finding, not a failed attempt.
        meta_out.parent.mkdir(parents=True, exist_ok=True)
        meta_out.write_text(
            json.dumps(
                {
                    "stage_id": args.stage_id,
                    "candidate": args.candidate,
                    "request_count": 0,
                    "parsed_ok": False,
                    "skipped": True,
                    "error": str(exc),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"verifier-bake-off-caller: {exc}", file=sys.stderr)
        return 3
    except (RuntimeError, urllib.error.URLError, TimeoutError) as exc:
        meta_out.parent.mkdir(parents=True, exist_ok=True)
        meta_out.write_text(
            json.dumps(
                {
                    "stage_id": args.stage_id,
                    "candidate": args.candidate,
                    "request_count": 1,
                    "parsed_ok": False,
                    "error": str(exc),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"verifier-bake-off-caller: request failed: {exc}", file=sys.stderr)
        return 1

    choices = response.get("choices") or []
    text = ""
    if choices:
        text = (choices[0].get("message") or {}).get("content") or ""
    usage = response.get("usage") or {}

    meta_out.parent.mkdir(parents=True, exist_ok=True)
    parsed_ok = False
    schema_ok = False
    error_detail = ""
    envelope: dict[str, Any] | None = None
    try:
        raw = extract_json_lenient(text)
        parsed_ok = True
        # The metadata fields are bake-off bookkeeping, not part of the
        # candidate's judgement (criteria/overall), so they are stamped
        # deterministically here rather than trusted from whatever the model
        # echoed back from the prompt (which some candidates paraphrase or
        # invent, e.g. copying the stage card's authored date into ran_at).
        if isinstance(raw, dict):
            raw["stage_id"] = args.stage_id
            raw["verifier_identity"] = verifier_identity
            raw["verifier_invocation"] = (
                f"scripts/verifier-bake-off.sh run --candidate {args.candidate} --stage {args.stage_id}"
            )
            raw["ran_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        envelope = verify_sdk.validate_envelope(raw, validator)
        schema_ok = True
    except verify_sdk.InvalidEnvelope as exc:
        error_detail = str(exc)
        invalid_path = Path(str(out) + ".invalid.json")
        invalid_path.parent.mkdir(parents=True, exist_ok=True)
        invalid_path.write_text(json.dumps(exc.data, indent=2) + "\n", encoding="utf-8")
    except (ValueError, json.JSONDecodeError) as exc:
        error_detail = str(exc)

    meta_out.write_text(
        json.dumps(
            {
                "stage_id": args.stage_id,
                "candidate": args.candidate,
                "base_url": args.base_url,
                "model": args.model,
                "elapsed_seconds": round(elapsed, 2),
                "request_count": 1,
                "prompt_tokens": usage.get("prompt_tokens"),
                "completion_tokens": usage.get("completion_tokens"),
                "total_tokens": usage.get("total_tokens"),
                "parsed_ok": parsed_ok,
                "schema_ok": schema_ok,
                "error": error_detail,
                "raw_text_len": len(text),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    if not schema_ok or envelope is None:
        print(f"verifier-bake-off-caller: artefact discipline failure: {error_detail or 'no parseable JSON'}", file=sys.stderr)
        return 3

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
    return 0 if envelope["overall"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
