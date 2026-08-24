#!/usr/bin/env python3
"""Score card 46's bake-off: compare each candidate's verdicts against the
frontier verdict already recorded for the same benchmark stage.

Per candidate, aggregated across every benchmark stage it produced a
schema-valid artefact for:

- FAIL recall: of the frontier's FAIL criteria, how many the candidate also
  failed. The number that matters — a verifier that misses real failures
  merges broken work.
- PASS agreement: of the frontier's PASS criteria, how many the candidate
  also passed.
- Artefact discipline: schema-valid JSON produced, as a fraction of attempts
  (including provider/network errors as failures to produce an artefact).
- Mean wall clock and request count per verification, from the caller's
  *.meta.json sidecars.

Criteria are matched by id: both the frontier verifier and every bake-off
candidate evaluate the same numbered acceptance criteria from the same
stage card, so criterion 3 in one artefact is criterion 3 in the other by
construction, not by fuzzy name matching.

Usage:
  scripts/verifier-bake-off-score.py --manifest examples/bake-off/manifest.json --bake-off-dir examples/bake-off
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Score bake-off candidate verdicts against frontier ground truth.")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--bake-off-dir", required=True)
    parser.add_argument("--format", choices=["json", "markdown"], default="markdown")
    return parser.parse_args()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def criteria_by_id(envelope: dict[str, Any]) -> dict[int, str]:
    return {int(c["id"]): c["verdict"] for c in envelope.get("criteria", [])}


def load_frontier(manifest: list[dict[str, Any]], autometta_root: Path) -> dict[str, dict[int, str]]:
    frontier: dict[str, dict[int, str]] = {}
    for stage in manifest:
        # frontier_artefact is a checked-in copy under examples/bake-off/frontier/
        # (this repo), not a path into the benchmark repo — see manifest.json's
        # $comment. Scoring must not require filesystem access to a sibling
        # checkout's gitignored state/verifiers/ to be re-derivable.
        artefact_path = autometta_root / stage["frontier_artefact"]
        if not artefact_path.is_file():
            print(f"warning: frontier artefact missing for {stage['stage_id']}: {artefact_path}")
            continue
        frontier[stage["stage_id"]] = criteria_by_id(read_json(artefact_path))
    return frontier


def score_candidate(
    candidate_dir: Path,
    stage_ids: list[str],
    frontier: dict[str, dict[int, str]],
) -> dict[str, Any]:
    attempts = 0
    schema_valid = 0
    fail_total = 0
    fail_recalled = 0
    pass_total = 0
    pass_agreed = 0
    overall_matches = 0
    overall_comparisons = 0
    elapsed_seconds: list[float] = []
    request_counts: list[int] = []
    stage_rows: list[dict[str, Any]] = []

    for stage_id in stage_ids:
        meta_path = candidate_dir / f"{stage_id}.meta.json"
        verdict_path = candidate_dir / f"{stage_id}.json"
        if not meta_path.is_file():
            continue  # not attempted for this candidate (e.g. cap reached)
        meta = read_json(meta_path)
        if meta.get("skipped"):
            continue
        attempts += 1
        elapsed_seconds.append(meta.get("elapsed_seconds", 0) or 0)
        request_counts.append(meta.get("request_count", 1) or 1)

        frontier_criteria = frontier.get(stage_id, {})
        if not verdict_path.is_file() or not meta.get("schema_ok"):
            stage_rows.append({"stage_id": stage_id, "schema_ok": False, "overall_match": None})
            continue
        schema_valid += 1
        candidate = read_json(verdict_path)
        candidate_criteria = criteria_by_id(candidate)

        stage_fail_total = stage_fail_recalled = stage_pass_total = stage_pass_agreed = 0
        for cid, frontier_verdict in frontier_criteria.items():
            candidate_verdict = candidate_criteria.get(cid)
            if frontier_verdict == "FAIL":
                fail_total += 1
                stage_fail_total += 1
                if candidate_verdict == "FAIL":
                    fail_recalled += 1
                    stage_fail_recalled += 1
            elif frontier_verdict == "PASS":
                pass_total += 1
                stage_pass_total += 1
                if candidate_verdict == "PASS":
                    pass_agreed += 1
                    stage_pass_agreed += 1

        frontier_overall = None
        overall_match = None
        candidate_overall = candidate.get("overall")
        stage_rows.append(
            {
                "stage_id": stage_id,
                "schema_ok": True,
                "candidate_overall": candidate_overall,
                "fail_recall": f"{stage_fail_recalled}/{stage_fail_total}" if stage_fail_total else "n/a",
                "pass_agreement": f"{stage_pass_agreed}/{stage_pass_total}" if stage_pass_total else "n/a",
                "elapsed_seconds": meta.get("elapsed_seconds"),
            }
        )

    return {
        "candidate": candidate_dir.name,
        "attempts": attempts,
        "schema_valid": schema_valid,
        "artefact_discipline": (schema_valid / attempts) if attempts else None,
        "fail_recall": (fail_recalled / fail_total) if fail_total else None,
        "fail_recall_fraction": f"{fail_recalled}/{fail_total}",
        "pass_agreement": (pass_agreed / pass_total) if pass_total else None,
        "pass_agreement_fraction": f"{pass_agreed}/{pass_total}",
        "mean_elapsed_seconds": (sum(elapsed_seconds) / len(elapsed_seconds)) if elapsed_seconds else None,
        "mean_request_count": (sum(request_counts) / len(request_counts)) if request_counts else None,
        "stages": stage_rows,
    }


def format_markdown(results: list[dict[str, Any]]) -> str:
    lines = [
        "| Candidate | Attempts | Artefact discipline | FAIL recall | PASS agreement | Mean wall clock (s) | Requests/verification |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in results:
        discipline = f"{row['artefact_discipline']:.0%}" if row["artefact_discipline"] is not None else "n/a"
        fail_recall = f"{row['fail_recall']:.0%} ({row['fail_recall_fraction']})" if row["fail_recall"] is not None else "n/a"
        pass_agreement = (
            f"{row['pass_agreement']:.0%} ({row['pass_agreement_fraction']})" if row["pass_agreement"] is not None else "n/a"
        )
        elapsed = f"{row['mean_elapsed_seconds']:.1f}" if row["mean_elapsed_seconds"] is not None else "n/a"
        requests = f"{row['mean_request_count']:.1f}" if row["mean_request_count"] is not None else "n/a"
        lines.append(
            f"| `{row['candidate']}` | {row['attempts']} | {discipline} | {fail_recall} | {pass_agreement} | {elapsed} | {requests} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest)
    manifest = read_json(manifest_path)["stages"]
    stage_ids = [s["stage_id"] for s in manifest]
    # manifest.json lives at examples/bake-off/manifest.json; frontier_artefact
    # paths are relative to the repo root two levels up.
    autometta_root = manifest_path.resolve().parent.parent.parent
    frontier = load_frontier(manifest, autometta_root)

    bake_off_dir = Path(args.bake_off_dir)
    candidate_dirs = sorted(p for p in bake_off_dir.iterdir() if p.is_dir())

    results = [score_candidate(d, stage_ids, frontier) for d in candidate_dirs]
    results = [r for r in results if r["attempts"] > 0]

    if args.format == "json":
        print(json.dumps(results, indent=2))
    else:
        print(format_markdown(results))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
