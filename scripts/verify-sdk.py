#!/usr/bin/env python3
"""Claude Agent SDK verifier entrypoint with Anthropic prompt caching."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import glob
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any


# The verifier runs with cwd set to the subscriber's run worktree, not to the
# autometta root (spawn-verifier.sh: `cd "$work_dir" && python3 "$sdk_script"`).
# The template is deliberately cwd-relative -- a subscriber vendors its own
# copy and may fill its placeholders. The schema is not vendored and not
# customisable, so it has to be found next to this script or the SDK route
# dies on `verifier schema not found` in every repo but autometta itself.
AUTOMETTA_ROOT = Path(__file__).resolve().parent.parent
REQUIREMENTS = str(AUTOMETTA_ROOT / "scripts" / "requirements-sdk.txt")
SCHEMA = AUTOMETTA_ROOT / "schemas" / "verifier.json"
TEMPLATE = Path("templates/verifier-prompt.md")
VERIFIER_IDENTITY = "Claude Agent SDK verifier <claude-agent-sdk@local>"
MODEL = "claude-sonnet-5"
MAX_TOKENS = 4096
# Keep a broad fallback from consuming an unbounded portion of the verifier
# context. This applies to source bytes before line numbering expands them.
MAX_ARTEFACT_BYTES = 512 * 1024
_BINARY_MAGIC_PREFIXES = (
    b"\x89PNG\r\n\x1a\n",
    b"\xff\xd8\xff",
    b"GIF87a",
    b"GIF89a",
    b"%PDF-",
    b"PK\x03\x04",
)


def usage_field(usage: Any, name: str) -> int | None:
    """Return an optional usage field across SDK object and mapping shapes."""
    if usage is None:
        return None
    value = usage.get(name) if isinstance(usage, dict) else getattr(usage, name, None)
    return None if value is None else int(value)


def update_live_usage(input_tokens: int, output_tokens: int) -> None:
    """Best-effort atomically refresh this verifier's registry usage fields."""
    path = Path("state/active-agents") / f"{os.getpid()}.json"
    try:
        registry = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(registry, dict):
            raise ValueError("registry entry is not a JSON object")
        registry.update({
            "live_input_tokens": max(0, int(input_tokens)),
            "live_output_tokens": max(0, int(output_tokens)),
            "live_updated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        })
        descriptor, temporary = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=path.parent, text=True
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(registry, handle, indent=2)
                handle.write("\n")
            os.replace(temporary, path)
        except Exception:
            Path(temporary).unlink(missing_ok=True)
            raise
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"verify-sdk: could not update live usage registry: {exc}", file=sys.stderr)


def live_anthropic_usage(usage: Any, prior_input: int) -> tuple[int, int]:
    """Normalise an Anthropic usage signal, retaining input absent from deltas."""
    input_fields = (
        usage_field(usage, "input_tokens"),
        usage_field(usage, "cache_creation_input_tokens"),
        usage_field(usage, "cache_read_input_tokens"),
    )
    input_tokens = sum(value for value in input_fields if value is not None)
    if all(value is None for value in input_fields):
        input_tokens = prior_input
    output_tokens = usage_field(usage, "output_tokens") or 0
    return input_tokens, output_tokens


def identity_for_model(model: str) -> str:
    # This string is written into the verifier artefact, so it is git-style
    # attribution: it has to name the weights that did the judging. Superseded
    # ids stay in the table because an artefact from an older run must still
    # resolve to the identity it actually carried; only the current tier is
    # added on a model bump. An id that reaches none of these falls through to
    # the generic label, which is what claude-sonnet-5 and claude-opus-5 did
    # between the 2026-07-26 model bump and this fix -- a real verifier's work
    # filed under a name no shortlog can group.
    if "fable-5" in model:
        return f"Claude Fable 5 (SDK) <{model}@local>"
    if "opus-5" in model:
        return f"Claude Opus 5 (SDK) <{model}@local>"
    if "opus-4-8" in model:
        return f"Claude Opus 4.8 (SDK) <{model}@local>"
    if "opus-4-7" in model:
        return f"Claude Opus 4.7 (SDK) <{model}@local>"
    if "opus-4" in model:
        return f"Claude Opus 4 (SDK) <{model}@local>"
    if "sonnet-5" in model:
        return f"Claude Sonnet 5 (SDK) <{model}@local>"
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
        "--effort",
        default=None,
        help="Optional Anthropic effort level supplied by the card's Verifier effort field.",
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


# The two credentials a verifier route can carry. api mode injects
# ANTHROPIC_API_KEY; subscription mode injects the OAuth token `claude
# setup-token` mints, which the Agent SDK's Claude Code entitlement is gated
# behind. spawn-verifier.sh names exactly one of them per route, so only one is
# ever present in this process's env.
OAUTH_BETA_HEADER = "oauth-2025-04-20"


def resolve_auth() -> tuple[str, str] | None:
    """Return ``(kind, credential)`` for the client, or ``None`` if neither is set.

    ``kind`` is ``"api_key"`` for ANTHROPIC_API_KEY or ``"auth_token"`` for
    CLAUDE_CODE_OAUTH_TOKEN. The api key wins when both are somehow present so
    that a repo on the metered route keeps the credential it asked for.
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if api_key:
        return "api_key", api_key
    oauth_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if oauth_token:
        return "auth_token", oauth_token
    return None


def build_client(Anthropic: Any, auth_kind: str, credential: str) -> Any:
    """Construct the Anthropic client for whichever credential the route carried."""
    if auth_kind == "auth_token":
        return Anthropic(
            api_key=None,
            auth_token=credential,
            default_headers={"anthropic-beta": OAUTH_BETA_HEADER},
        )
    return Anthropic(api_key=credential)


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
    excluded: set[Path] = set()
    for part in (item.strip() for item in pattern.split(",")):
        if not part:
            continue
        paths = {Path(item) for item in glob.glob(part.lstrip("!"), recursive=True)}
        if part.startswith("!"):
            excluded.update(paths)
        else:
            matches.extend(paths)
    return sorted({path for path in matches if path.is_file() and path not in excluded})


def collect_artefact_sections(artefacts: list[Path]) -> str:
    """Return bounded, numbered text artefacts and notes for skipped files."""
    sections: list[str] = []
    collected_bytes = 0
    for path in artefacts:
        raw = path.read_bytes()
        if b"\0" in raw or raw.startswith(_BINARY_MAGIC_PREFIXES):
            sections.append(f"### {path}\n(skipped binary artefact)\n")
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            sections.append(f"### {path}\n(skipped artefact: not valid UTF-8)\n")
            continue
        if collected_bytes + len(raw) > MAX_ARTEFACT_BYTES:
            sections.append(
                f"(artefact collection stopped at {MAX_ARTEFACT_BYTES} bytes; "
                "remaining matched files omitted)\n"
            )
            break
        collected_bytes += len(raw)
        sections.append(numbered(path, text))
    return "\n".join(sections)


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
    artefact_sections = collect_artefact_sections(artefacts)
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
    auth_kind: str,
    credential: str,
    Anthropic: Any,
    validator: Any,
    model: str = MODEL,
    advisor: str | None = None,
    effort: str | None = None,
) -> dict[str, Any]:
    """Call the Anthropic API with a cached static block and return the validated envelope.

    When ``advisor`` is set, the cheap ``model`` reads the (cache-controlled)
    static block plus artefacts and drafts the verdicts, and the stronger
    advisor is consulted only at the decision point to finalise the envelope.
    The advisor consults over the same cached prefix, so its input is cached.
    """
    client = build_client(Anthropic, auth_kind, credential)
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
    if effort:
        create_kwargs["output_config"] = {"effort": effort}
    live_input = 0
    live_output = 0
    with client.messages.stream(**create_kwargs) as stream:
        for event in stream:
            event_usage = getattr(event, "usage", None)
            if event_usage is None:
                message = getattr(event, "message", None)
                event_usage = getattr(message, "usage", None)
            if event_usage is None:
                continue
            live_input, live_output = live_anthropic_usage(event_usage, live_input)
            update_live_usage(live_input, live_output)
        response = stream.get_final_message()
    usage = response.usage
    write = getattr(usage, "cache_creation_input_tokens", 0) or 0
    read = getattr(usage, "cache_read_input_tokens", 0) or 0
    inp = getattr(usage, "input_tokens", 0) or 0
    out = getattr(usage, "output_tokens", 0) or 0
    live_input, live_output = live_anthropic_usage(usage, live_input)
    update_live_usage(live_input, live_output)
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
    # only under the sdk transport, which spawn-verifier.sh gates to a route
    # carrying one of the two credentials resolved below.
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

    auth = resolve_auth()
    if auth is None:
        return fail_env(
            "missing ANTHROPIC_API_KEY and CLAUDE_CODE_OAUTH_TOKEN; inject one with "
            "op-fetch before running (api mode uses the key, subscription mode uses "
            "the token minted by `claude setup-token`)"
        )
    auth_kind, auth_credential = auth

    card = Path(args.card)
    out = Path(args.out)
    model = args.model
    advisor = args.advisor
    effort = args.effort
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
        envelope = run_sdk(
            static_block,
            variable_block,
            auth_kind,
            auth_credential,
            Anthropic,
            validator,
            model=model,
            advisor=advisor,
            effort=effort,
        )
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
