#!/usr/bin/env python3
"""Submit and collect Anthropic batch retro-grades for completed stages."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any, Iterable


STATE = Path("state/state.yaml")
VERIFIER_SCHEMA = Path("schemas/verifier.json")
VERIFIER_TEMPLATE = Path("templates/verifier-prompt.md")
REPORT_TEMPLATE = Path("memory/retro-grade-template.md")
DRY_RUN_PAYLOAD = Path("/tmp/retro-grade-batch.jsonl")
MODEL = "claude-sonnet-4-6"
MAX_TOKENS = 4096
DEFAULT_LAST = 20
DEFAULT_TIMEOUT_SECONDS = 25 * 60 * 60


@dataclass(frozen=True)
class Stage:
    stage_id: str
    status: str
    verifier_artefact: str | None
    completed_at: str | None


@dataclass(frozen=True)
class StageRun:
    stage: Stage
    card_path: Path
    original_overall: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build, submit, poll, and report an Anthropic batch retro-grade."
    )
    parser.add_argument("--last", type=int, default=DEFAULT_LAST, help="Number of completed stages to grade.")
    parser.add_argument("--dry-run", action="store_true", help="Write the JSONL payload and exit.")
    parser.add_argument("--model", default=MODEL, help=f"Anthropic model for batch messages (default: {MODEL}).")
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=int(os.environ.get("AUTOMETTA_RETRO_GRADE_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS)),
        help="Hard wall-clock cap for polling a live batch.",
    )
    return parser.parse_args()


def load_anthropic() -> Any:
    try:
        from anthropic import Anthropic
    except ImportError as exc:
        raise RuntimeError(
            "missing anthropic; install with: python3 -m pip install -r scripts/requirements-sdk.txt"
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


def deliverable_paths(card_path: Path) -> list[Path]:
    paths: list[Path] = []
    in_deliverables = False
    for line in read_text(card_path).splitlines():
        if line.startswith("## "):
            in_deliverables = line.strip() == "## Deliverables"
            continue
        if not in_deliverables:
            continue
        for match in re.findall(r"`([^`]+)`", line):
            if any(token in match for token in ("<", ">", "*", "$", " ")):
                continue
            candidate = Path(match)
            if candidate.is_file():
                paths.append(candidate)
    return sorted(set(paths))


def parse_state(path: Path = STATE) -> list[Stage]:
    stages: list[dict[str, str | None]] = []
    current: dict[str, str | None] | None = None
    for raw in read_text(path).splitlines():
        if raw.startswith("  - id: "):
            if current is not None:
                stages.append(current)
            current = {"id": raw.split(":", 1)[1].strip().strip('"')}
            continue
        if current is None or not raw.startswith("    "):
            continue
        key, sep, value = raw.strip().partition(":")
        if not sep:
            continue
        value = value.strip()
        if value == "null":
            parsed: str | None = None
        else:
            parsed = value.strip('"')
        current[key] = parsed
    if current is not None:
        stages.append(current)

    parsed_stages: list[Stage] = []
    for item in stages:
        stage_id = item.get("id")
        status = item.get("status")
        if not stage_id or not status:
            continue
        parsed_stages.append(
            Stage(
                stage_id=stage_id,
                status=status,
                verifier_artefact=item.get("verifier_artefact"),
                completed_at=item.get("completed_at"),
            )
        )
    return parsed_stages


def card_for_stage(stage_id: str) -> Path:
    path = Path("examples/self-host") / f"{stage_id}.md"
    if path.is_file():
        return path
    matches = sorted(Path("examples/self-host").glob(f"*{stage_id}*.md"))
    if matches:
        return matches[0]
    raise FileNotFoundError(f"stage card not found for {stage_id}")


def original_overall(stage: Stage) -> str:
    if stage.verifier_artefact:
        artefact = Path(stage.verifier_artefact)
        if artefact.is_file():
            data = json.loads(read_text(artefact))
            overall = data.get("overall")
            if overall in {"PASS", "FAIL"}:
                return overall
            raise ValueError(f"{artefact}: overall must be PASS or FAIL")
    if stage.status == "completed":
        return "PASS"
    raise ValueError(f"{stage.stage_id}: no verifier artefact and status is {stage.status}")


def select_stage_runs(limit: int) -> list[StageRun]:
    if limit <= 0:
        raise ValueError("--last must be greater than zero")
    completed = [stage for stage in parse_state() if stage.status == "completed"]
    selected = completed[-limit:]
    runs: list[StageRun] = []
    for stage in selected:
        runs.append(
            StageRun(
                stage=stage,
                card_path=card_for_stage(stage.stage_id),
                original_overall=original_overall(stage),
            )
        )
    if len(runs) != limit:
        raise ValueError(f"requested {limit} completed stages, found {len(runs)}")
    return runs


def static_rubric() -> str:
    template = read_text(VERIFIER_TEMPLATE)
    schema = read_text(VERIFIER_SCHEMA)
    filled = (
        template.replace("<<verifier-tier>>", "retro-grade")
        .replace("<<orchestrator-identity>>", "scripts/retro-grade-batch.py")
        .replace("<<stage-id>>", "{stage_id}")
        .replace("<<stage-card-path>>", "{stage_card_path}")
        .replace("<<artefact-path>>", "{artefact_path}")
        .replace("<<family-specific-notes-or-none>>", "Return only JSON. Do not write files.")
    )
    return (
        filled
        + "\n## Current verifier JSON Schema\n\n```json\n"
        + schema
        + "\n```\n"
        + "\nFor retro-grade, emit the verifier envelope in the response body only. "
        + "Do not claim to have written state/verifiers, do not evaluate unlisted files, "
        + "and do not include prose outside JSON.\n"
    )


def request_for_stage(run: StageRun, model: str) -> dict[str, Any]:
    stage_id = run.stage.stage_id
    deliverables = deliverable_paths(run.card_path)
    if deliverables:
        deliverable_text = "\n".join(numbered(path, read_text(path)) for path in deliverables)
    else:
        deliverable_text = "(no current deliverable files were found from backticked paths in the Deliverables section)\n"
    variable = (
        "## Retro-grade target\n\n"
        f"- Stage id: `{stage_id}`\n"
        f"- Stage card: `{run.card_path}`\n"
        f"- Original overall: `{run.original_overall}`\n\n"
        "## Stage card with line numbers\n\n"
        f"{numbered(run.card_path, read_text(run.card_path))}\n"
        "## Current deliverable files with line numbers\n\n"
        f"{deliverable_text}\n"
    )
    return {
        "custom_id": stage_id,
        "params": {
            "model": model,
            "max_tokens": MAX_TOKENS,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": static_rubric()},
                        {"type": "text", "text": variable},
                    ],
                }
            ],
        },
    }


def write_jsonl(path: Path, requests: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(request, separators=(",", ":")) for request in requests) + "\n", encoding="utf-8")


def _get(obj: Any, name: str, default: Any = None) -> Any:
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def submit_batch(client: Any, requests: list[dict[str, Any]]) -> Any:
    return client.messages.batches.create(requests=requests)


def poll_batch(client: Any, batch_id: str, timeout_seconds: int) -> Any:
    deadline = time.time() + timeout_seconds
    delay = 15
    while True:
        batch = client.messages.batches.retrieve(batch_id)
        status = _get(batch, "processing_status")
        if status == "ended":
            return batch
        if time.time() >= deadline:
            raise TimeoutError(f"batch {batch_id} did not finish before timeout")
        time.sleep(delay)
        delay = min(delay * 2, 300)


def extract_json(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith("```"):
        first_newline = stripped.find("\n")
        if first_newline == -1:
            raise ValueError("malformed JSON code block")
        stripped = stripped[first_newline + 1 :]
        last_fence = stripped.rfind("```")
        if last_fence != -1:
            stripped = stripped[:last_fence].strip()
    data = json.loads(stripped)
    if not isinstance(data, dict):
        raise ValueError("batch result JSON is not an object")
    return data


def result_text(result: Any) -> tuple[str, dict[str, int]]:
    result_type = _get(result, "type")
    if result_type != "succeeded":
        raise RuntimeError(f"batch request did not succeed: {result_type}")
    message = _get(result, "message")
    content = _get(message, "content", [])
    if not content:
        raise RuntimeError("batch result has no message content")
    first = content[0]
    text = _get(first, "text")
    if not text:
        raise RuntimeError("batch result has no text content")
    usage = _get(message, "usage", {})
    return text, {
        "input_tokens": int(_get(usage, "input_tokens", 0) or 0),
        "output_tokens": int(_get(usage, "output_tokens", 0) or 0),
    }


def collect_results(client: Any, batch_id: str) -> dict[str, tuple[dict[str, Any], dict[str, int]]]:
    collected: dict[str, tuple[dict[str, Any], dict[str, int]]] = {}
    for item in client.messages.batches.results(batch_id):
        custom_id = _get(item, "custom_id")
        text, usage = result_text(_get(item, "result"))
        envelope = extract_json(text)
        collected[custom_id] = (envelope, usage)
    return collected


def markdown_table(rows: list[dict[str, str]]) -> str:
    if not rows:
        return "No disagreements found.\n"
    lines = [
        "| Stage | Original | Retro | Card |",
        "|---|---:|---:|---|",
    ]
    for row in rows:
        lines.append(
            f"| `{row['stage_id']}` | {row['original_overall']} | {row['retro_overall']} | `{row['card_path']}` |"
        )
    return "\n".join(lines) + "\n"


def render_report(
    *,
    date: str,
    batch_id: str,
    model: str,
    stage_count: int,
    drift_rows: list[dict[str, str]],
    input_tokens: int,
    output_tokens: int,
) -> str:
    template = read_text(REPORT_TEMPLATE)
    total_tokens = input_tokens + output_tokens
    replacements = {
        "<<date>>": date,
        "<<batch-id>>": batch_id,
        "<<model>>": model,
        "<<stage-count>>": str(stage_count),
        "<<drift-count>>": str(len(drift_rows)),
        "<<input-tokens>>": str(input_tokens),
        "<<output-tokens>>": str(output_tokens),
        "<<total-tokens>>": str(total_tokens),
        "<<drift-table>>": markdown_table(drift_rows),
    }
    for old, new in replacements.items():
        template = template.replace(old, new)
    return template


def report_path(date: str) -> Path:
    return Path("memory") / f"retro-grade-{date}.md"


def write_report(
    runs: list[StageRun],
    results: dict[str, tuple[dict[str, Any], dict[str, int]]],
    batch_id: str,
    model: str,
) -> Path:
    drift_rows: list[dict[str, str]] = []
    input_tokens = 0
    output_tokens = 0
    by_id = {run.stage.stage_id: run for run in runs}
    missing = set(by_id) - set(results)
    if missing:
        raise RuntimeError(f"batch result missing stage(s): {', '.join(sorted(missing))}")

    for stage_id, (envelope, usage) in results.items():
        run = by_id.get(stage_id)
        if run is None:
            raise RuntimeError(f"batch returned unexpected stage: {stage_id}")
        input_tokens += usage["input_tokens"]
        output_tokens += usage["output_tokens"]
        retro_overall = envelope.get("overall")
        if retro_overall not in {"PASS", "FAIL"}:
            raise RuntimeError(f"{stage_id}: retro overall must be PASS or FAIL")
        if retro_overall != run.original_overall:
            drift_rows.append(
                {
                    "stage_id": stage_id,
                    "original_overall": run.original_overall,
                    "retro_overall": retro_overall,
                    "card_path": str(run.card_path),
                }
            )

    today = datetime.now(timezone.utc).date().isoformat()
    path = report_path(today)
    path.write_text(
        render_report(
            date=today,
            batch_id=batch_id,
            model=model,
            stage_count=len(runs),
            drift_rows=drift_rows,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
        ),
        encoding="utf-8",
    )
    return path


def main() -> int:
    args = parse_args()
    try:
        runs = select_stage_runs(args.last)
        requests = [request_for_stage(run, args.model) for run in runs]
        write_jsonl(DRY_RUN_PAYLOAD, requests)
        if args.dry_run:
            print(f"retro-grade: wrote dry-run payload {DRY_RUN_PAYLOAD} ({len(requests)} requests)")
            return 0

        api_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if not api_key:
            print("retro-grade: missing ANTHROPIC_API_KEY; run via scripts/retro-grade.sh", file=sys.stderr)
            return 2
        Anthropic = load_anthropic()
        client = Anthropic(api_key=api_key)
        batch = submit_batch(client, requests)
        batch_id = _get(batch, "id")
        if not batch_id:
            raise RuntimeError("Anthropic Batch API did not return a batch id")
        try:
            poll_batch(client, batch_id, args.timeout_seconds)
        except TimeoutError as exc:
            print(f"retro-grade: {exc}; recover manually from batch_id={batch_id}", file=sys.stderr)
            return 1
        results = collect_results(client, batch_id)
        path = write_report(runs, results, batch_id, args.model)
        print(f"retro-grade: wrote {path}")
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"retro-grade: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
