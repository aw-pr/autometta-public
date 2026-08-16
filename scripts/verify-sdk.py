#!/usr/bin/env python3
"""Claude Agent SDK verifier entrypoint with Anthropic prompt caching."""

from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path
import sys
from typing import Any


REQUIREMENTS = "scripts/requirements-sdk.txt"
SCHEMA = Path("schemas/verifier.json")
TEMPLATE = Path("templates/verifier-prompt.md")
VERIFIER_IDENTITY = "Claude Agent SDK verifier <claude-agent-sdk@local>"
MODEL = "claude-sonnet-4-6"
MAX_TOKENS = 4096


def identity_for_model(model: str) -> str:
    if "opus-4-8" in model:
        return f"Claude Opus 4.8 (SDK) <{model}@local>"
    if "opus-4-7" in model:
        return f"Claude Opus 4.7 (SDK) <{model}@local>"
    if "opus-4" in model:
        return f"Claude Opus 4 (SDK) <{model}@local>"
    if "sonnet-4-6" in model:
        return f"Claude Sonnet 4.6 (SDK) <{model}@local>"
    if "sonnet-4" in model:
        return f"Claude Sonnet 4 (SDK) <{model}@local>"
    if "haiku" in model:
        return f"Claude Haiku (SDK) <{model}@local>"
    return f"Claude Agent SDK verifier ({model}) <{model}@local>"


# Capability ordering for the advisor precondition (issue #66714). The advisor
# must not be weaker than the request model; a request on claude-fable-5 with an
# advisor pinned to claude-opus-4-8 returns HTTP 400. Higher rank = stronger.
# Unknown ids rank at the workhorse (sonnet) level so an unrecognised id never
# silently outranks the advisor.
_CAPABILITY_RANK = {"haiku": 0, "sonnet": 1, "opus": 2, "fable": 3}
_UNKNOWN_RANK = _CAPABILITY_RANK["sonnet"]


class AdvisorOrderingError(ValueError):
    """Raised when the request model is stronger than its advisor (#66714)."""


def capability_rank(model: str) -> int:
    """Return a capability rank for a Claude model id (fable > opus > sonnet > haiku)."""
    lowered = model.lower()
    for marker, rank in _CAPABILITY_RANK.items():
        if marker in lowered:
            return rank
    return _UNKNOWN_RANK


def assert_advisor_ordering(request_model: str, advisor_model: str) -> None:
    """Reject a request model stronger than its advisor before any API call.

    The advisor must not be weaker than the request model (#66714). Enforcing
    the ordering locally turns the API's HTTP 400 into a clear, pre-flight error.
    """
    if capability_rank(request_model) > capability_rank(advisor_model):
        raise AdvisorOrderingError(
            f"advisor ordering: request model '{request_model}' is stronger than "
            f"advisor '{advisor_model}'; the advisor must not be weaker than the "
            f"request model (see docs/design/advisor-verifier.md #66714). "
            f"Put the cheap model on --model and the strong model on --advisor."
        )

# Stable guidance appended to the cacheable block so the block exceeds the
# ~1024-token minimum for Sonnet prompt caching.
_DISPATCH_CONTRACT_REMINDERS = """
## Dispatch contract reminders

These reminders are part of the cached rubric block.

- Evaluate the **dirty working tree** only, not a committed snapshot.
- Ground every verdict in concrete file:line evidence.
- Do not commit. Do not mutate any file outside the artefact path.
- The `overall` field must be "PASS" only when every criterion is "PASS".
- Return exactly one JSON object matching the artefact schema above.
  Do not wrap the JSON in prose or a markdown code block.
- Per-criterion verdicts are independent; evaluate each in isolation.
- Missing required files are evidence of FAIL, not evidence to skip.
"""


class InvalidEnvelope(ValueError):
    def __init__(self, message: str, data: Any):
        super().__init__(message)
        self.data = data


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
            "Notes from a handoff envelope whose status was partial, surfaced "
            "to the verifier as a checklist of the criteria the worker "
            "deferred. Goes in the per-stage variable block, never the "
            "cacheable static block, since it differs on every stage."
        ),
    )
    parser.add_argument(
        "--model",
        default=MODEL,
        help=f"Anthropic model to use for verification (default: {MODEL}).",
    )
    parser.add_argument(
        "--advisor",
        default=None,
        help=(
            "Optional stronger Anthropic advisor model consulted only at the "
            "decision point (e.g. claude-fable-5) while --model does the bulk "
            "reading. Must NOT be weaker than --model. SDK + api mode only. "
            "DATA RETENTION: the advisor receives the stage card and artefacts, "
            "which carry the org-wide 30-day retention commitment; do NOT point "
            "it at a repo whose artefacts contain personal data (see "
            "docs/design/advisor-verifier.md)."
        ),
    )
    return parser.parse_args()


def fail_env(message: str) -> int:
    print(f"verify-sdk: {message}", file=sys.stderr)
    return 2


def load_jsonschema() -> Any:
    try:
        from jsonschema import Draft202012Validator
    except ImportError as exc:
        raise RuntimeError(
            f"missing jsonschema; install with: python3 -m pip install -r {REQUIREMENTS}"
        ) from exc
    return Draft202012Validator


def load_anthropic() -> Any:
    try:
        from anthropic import Anthropic
    except ImportError as exc:
        raise RuntimeError(
            f"missing anthropic; install with: python3 -m pip install -r {REQUIREMENTS}"
        ) from exc
    return Anthropic


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def numbered(path: Path, text: str) -> str:
    lines = text.splitlines()
    if not lines:
        return f"### {path}\n(empty)\n"
    body = "\n".join(f"{idx}: {line}" for idx, line in enumerate(lines, start=1))
    return f"### {path}\n{body}\n"


def find_artefacts(pattern: str) -> list[Path]:
    matches: list[Path] = []
    for part in (item.strip() for item in pattern.split(",")):
        if not part:
            continue
        matches.extend(Path(item) for item in glob.glob(part, recursive=True))
    return sorted({path for path in matches if path.is_file()})


def verifier_schema() -> dict[str, Any]:
    return json.loads(read_text(SCHEMA))


def build_static_block(verifier_identity: str = VERIFIER_IDENTITY) -> str:
    """Return the cacheable portion of the prompt.

    Contains the verifier rubric (template prose with constant placeholders
    filled), the artefact JSON schema, and the dispatch contract reminders.
    This block is identical across all stages dispatched in the same session,
    so it benefits from Anthropic's prompt caching once the TTL window is warm.
    """
    template = read_text(TEMPLATE)
    filled = (
        template
        .replace("<<verifier-tier>>", verifier_identity)
        .replace("<<orchestrator-identity>>", "verify-sdk.py")
        .replace("<<family-specific-notes-or-none>>", "None")
        # Replace stage-specific placeholders with descriptive labels so the
        # block remains valid prose without per-stage content.
        .replace("<<stage-id>>", "{stage_id}")
        .replace("<<stage-card-path>>", "{stage_card_path}")
        .replace("<<artefact-path>>", "{artefact_path}")
    )
    schema_text = read_text(SCHEMA)
    return (
        filled
        + "\n## Artefact output schema\n\n"
        + "The JSON report must validate against this schema:\n\n"
        + "```json\n"
        + schema_text
        + "```\n"
        + _DISPATCH_CONTRACT_REMINDERS
    )


def build_variable_block(
    stage_id: str,
    card: Path,
    artefacts: list[Path],
    out: Path,
    verifier_identity: str = VERIFIER_IDENTITY,
    worker_notes: str | None = None,
) -> str:
    """Return the per-stage, non-cached portion of the prompt."""
    artefact_sections = "\n".join(numbered(path, read_text(path)) for path in artefacts)
    if not artefact_sections:
        artefact_sections = "(no artefacts matched the supplied glob)\n"

    # The static block's family-specific-notes slot is fixed at "None" so the
    # cacheable prefix stays byte-identical across stages. A partial worker
    # envelope is per-stage by definition, so it belongs here instead.
    partial_section = ""
    if worker_notes:
        partial_section = (
            "## Worker self-reported incomplete acceptance\n\n"
            "The handoff envelope for this stage carried `status: partial`. That is "
            "the worker's annotation, not a verdict: acceptability is yours to decide. "
            "Treat the criteria it names as your checklist and verify each one "
            "yourself rather than inheriting the worker's judgement about them.\n\n"
            f"Worker notes: {worker_notes}\n\n"
        )

    return (
        "## Stage-specific context\n\n"
        f"- Stage id: `{stage_id}`\n"
        f"- Stage card: `{card}`\n"
        f"- Verifier artefact path: `{out}`\n"
        f"- Verifier identity: `{verifier_identity}`\n"
        f"- Verifier invocation: `scripts/verify-sdk.py --stage-id {stage_id} "
        f"--card {card} --artefact-glob <redacted> --out {out}`\n\n"
        f"{partial_section}"
        "## Stage card with line numbers\n\n"
        f"{numbered(card, read_text(card))}\n"
        "## Worker artefacts with line numbers\n\n"
        f"{artefact_sections}"
    )


def validate_envelope(data: Any, validator: Any) -> dict[str, Any]:
    if not isinstance(data, dict):
        raise InvalidEnvelope("structured output is not a JSON object", data)
    errors = sorted(validator.iter_errors(data), key=lambda err: list(err.path))
    if errors:
        err = errors[0]
        where = ".".join(str(part) for part in err.path) or "<root>"
        raise InvalidEnvelope(f"{where}: {err.message}", data)
    return data


def _extract_json(text: str) -> Any:
    """Parse JSON from a response that may be wrapped in a markdown code block."""
    stripped = text.strip()
    if stripped.startswith("```"):
        # Strip opening fence (```json or ```)
        first_newline = stripped.find("\n")
        if first_newline == -1:
            raise ValueError("malformed code block: no newline after fence")
        stripped = stripped[first_newline + 1:]
        # Strip closing fence
        last_fence = stripped.rfind("```")
        if last_fence != -1:
            stripped = stripped[:last_fence].strip()
    return json.loads(stripped)


def run_sdk(
    static_block: str,
    variable_block: str,
    api_key: str,
    Anthropic: Any,
    validator: Any,
    model: str = MODEL,
    advisor: str | None = None,
) -> dict[str, Any]:
    """Call the Anthropic API with a cached static block and return the validated envelope.

    When ``advisor`` is set, the cheap ``model`` reads the (cache-controlled)
    static block plus artefacts and drafts the verdicts, and the stronger
    advisor is consulted only at the decision point to finalise the envelope.
    The advisor consults over the same cached prefix, so its input is cached.
    """
    client = Anthropic(api_key=api_key)
    create_kwargs: dict[str, Any] = {
        "model": model,
        "max_tokens": MAX_TOKENS,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": static_block,
                        "cache_control": {"type": "ephemeral"},
                    },
                    {
                        "type": "text",
                        "text": variable_block,
                    },
                ],
            }
        ],
    }
    if advisor:
        # Confine the frontier model to the decision point. Passed via extra_body
        # so the default (no-advisor) call is byte-identical to before.
        create_kwargs["extra_body"] = {
            "advisor": {"type": "advisor_20260301", "model": advisor}
        }
    response = client.messages.create(**create_kwargs)
    usage = response.usage
    write = getattr(usage, "cache_creation_input_tokens", 0) or 0
    read = getattr(usage, "cache_read_input_tokens", 0) or 0
    inp = getattr(usage, "input_tokens", 0) or 0
    out = getattr(usage, "output_tokens", 0) or 0
    print(f"cache: write={write} read={read} input={inp} output={out}", file=sys.stderr)
    print(f"Total tokens: {inp + out}", file=sys.stderr)
    if advisor:
        advisor_usage = getattr(usage, "advisor", None)
        adv_in = adv_out = 0
        if isinstance(advisor_usage, dict):
            adv_in = advisor_usage.get("input_tokens", 0) or 0
            adv_out = advisor_usage.get("output_tokens", 0) or 0
        elif advisor_usage is not None:
            adv_in = getattr(advisor_usage, "input_tokens", 0) or 0
            adv_out = getattr(advisor_usage, "output_tokens", 0) or 0
        print(f"advisor: model={advisor} input={adv_in} output={adv_out}", file=sys.stderr)

    if not response.content:
        raise ValueError("API returned no content")
    text = response.content[0].text
    data = _extract_json(text)
    return validate_envelope(data, validator)


def main() -> int:
    args = parse_args()

    # Enforce the #66714 precondition first, before any import or API call: the
    # advisor must not be weaker than the request model. This path is reached
    # only under the sdk transport, which spawn-verifier.sh already gates to
    # auth.claude.mode: api (ANTHROPIC_API_KEY required below).
    if args.advisor:
        try:
            assert_advisor_ordering(args.model, args.advisor)
        except AdvisorOrderingError as exc:
            return fail_env(str(exc))

    try:
        Anthropic = load_anthropic()
        Validator = load_jsonschema()
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
    model = args.model
    advisor = args.advisor
    verifier_identity = identity_for_model(model)

    try:
        if not card.is_file():
            return fail_env(f"stage card not found: {card}")
        if not TEMPLATE.is_file():
            return fail_env(f"verifier prompt template not found: {TEMPLATE}")
        if not SCHEMA.is_file():
            return fail_env(f"verifier schema not found: {SCHEMA}")

        artefacts = find_artefacts(args.artefact_glob)
        static_block = build_static_block(verifier_identity=verifier_identity)
        variable_block = build_variable_block(
            args.stage_id,
            card,
            artefacts,
            out,
            verifier_identity=verifier_identity,
            worker_notes=args.worker_notes,
        )
        validator = Validator(verifier_schema())
        envelope = run_sdk(static_block, variable_block, anthropic_api_key, Anthropic, validator, model=model, advisor=advisor)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
        return 0 if envelope["overall"] == "PASS" else 1
    except RuntimeError as exc:
        print(f"verify-sdk: {exc}", file=sys.stderr)
        return 2
    except InvalidEnvelope as exc:
        invalid_path = Path(str(out) + ".invalid.json")
        invalid_path.parent.mkdir(parents=True, exist_ok=True)
        invalid_path.write_text(json.dumps(exc.data, indent=2) + "\n", encoding="utf-8")
        print(f"verify-sdk: {exc}; wrote {invalid_path}", file=sys.stderr)
        return 3
    except ValueError as exc:
        print(f"verify-sdk: {exc}", file=sys.stderr)
        return 1
    except (OSError, json.JSONDecodeError) as exc:
        print(f"verify-sdk: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
