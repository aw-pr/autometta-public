#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s REPO RUN_ID finished|halted\n' "${0##*/}" >&2
  exit 2
fi

exec python3 -B - "$@" <<'PY'
from collections import defaultdict
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

import yaml


RUN_ID = re.compile(r"run-[0-9]{8}-[0-9]{6}")
STAGE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
COMMIT = re.compile(r"[0-9a-f]{7,40}|[0-9a-f]{64}")
STATUSES = (
    "pending", "in_progress", "completed", "awaiting", "failed",
    "stalled", "verifier_failed", "superseded",
)
ROLES = ("worker", "verifier")


def run_start(value):
    if isinstance(value, str) and RUN_ID.fullmatch(value):
        try:
            return datetime.strptime(value, "run-%Y%m%d-%H%M%S").replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


def timestamp(value):
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    if isinstance(value, datetime) and value.tzinfo is not None:
        return value
    return None


def object_or_empty(value):
    return value if isinstance(value, dict) else {}


def read_object(path):
    try:
        return object_or_empty(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return {}


def within_membership(stage, stamp):
    start = run_start(stage.get("run_id"))
    end = timestamp(stage.get("completed_at"))
    return (start is None or start <= stamp) and (end is None or stamp <= end)


def halt_boundary(budget, stages, run_id):
    stamp = timestamp(budget.get("halted_at"))
    if budget.get("halted") is not True or stamp is None:
        return None
    if stamp < run_start(run_id):
        return None
    tagged_run = budget.get("run_id")
    if tagged_run is not None:
        return stamp if tagged_run == run_id else None
    if all(stage.get("run_id") == run_id or not within_membership(stage, stamp)
           for stage in stages):
        return stamp
    return None


def dispatch_receipts(state_dir, budget, stage_ids):
    def is_requested(row):
        stage_id = row.get("stage_id")
        return isinstance(stage_id, str) and stage_id in stage_ids and row.get("role") in ROLES

    by_id = {}
    legacy = []
    try:
        with (state_dir / "cost-log.jsonl").open("rb") as ledger:
            for line in ledger:
                try:
                    row = object_or_empty(json.loads(line))
                except ValueError:
                    continue
                if not is_requested(row):
                    continue
                dispatch_id = row.get("dispatch_id")
                if isinstance(dispatch_id, str) and dispatch_id:
                    by_id.setdefault(dispatch_id, row)
                else:
                    legacy.append(row)
    except FileNotFoundError:
        pass

    # Interrupted-role accounting persists this receipt before replaying it to the ledger.
    for dispatch_id, row in object_or_empty(budget.get("dispatch_charges")).items():
        if isinstance(row, dict) and is_requested(row):
            ledger_row = by_id.get(dispatch_id, {})
            if row.get("run_id") is None and ledger_row.get("run_id") is not None:
                row = {**row, "run_id": ledger_row["run_id"]}
            by_id[dispatch_id] = row
    return [*legacy, *by_id.values()]


def attribution(row, stage, memberships, halt):
    if row.get("run_id") is not None:
        return row["run_id"] == stage["run_id"]
    stamp = timestamp(row.get("ts"))
    if stamp is None:
        return None
    if not within_membership(stage, stamp) or (halt is not None and stamp > halt):
        return False
    if any(other is not stage and within_membership(other, stamp) for other in memberships):
        return None
    return True


def token_total(row):
    if row.get("usage_status") == "unknown":
        return None
    counts = ([row["total_tokens"]] if "total_tokens" in row else
              [row.get(key) for key in ("input_tokens", "cached_input_tokens", "output_tokens")])
    return sum(counts) if all(type(count) is int and count >= 0 for count in counts) else None


def stage_usage(rows, stage, memberships, halt):
    workers = 0
    totals = []
    ambiguous_worker = False
    for row in rows:
        belongs = attribution(row, stage, memberships, halt)
        if belongs is False:
            continue
        if belongs is None:
            ambiguous_worker |= row["role"] == "worker"
            totals.append(None)
            continue
        workers += row["role"] == "worker"
        totals.append(token_total(row))
    attempts = workers if workers and not ambiguous_worker else None
    total = sum(totals) if totals and None not in totals else None
    return attempts, total


def verdict(state_dir, stage, memberships, halt):
    relative = f"state/verifiers/{stage['id']}.json"
    linked = stage.get("verifier_artefact")
    if linked is not None and linked != relative:
        return None
    path = state_dir / "verifiers" / f"{stage['id']}.json"
    report = read_object(path)
    overall = report.get("overall")
    if report.get("stage_id") != stage["id"] or overall not in ("PASS", "FAIL"):
        return None

    stamp = timestamp(report.get("ran_at"))
    verifier_start = timestamp(stage.get("verifier_started_at"))
    latest_start = verifier_start or timestamp(stage.get("started_at"))
    if stamp is not None and latest_start is not None and stamp < latest_start:
        return None
    if report.get("run_id") is not None:
        return overall if report["run_id"] == stage["run_id"] else None
    if stamp is None:
        if report.get("ran_at") is None and linked == relative and len(memberships) == 1:
            return overall
        return None
    if attribution({"ts": stamp}, stage, memberships, halt) is True:
        return overall
    return None


def landed_commit(stage, status):
    integration = object_or_empty(stage.get("integration"))
    if integration.get("state") == "merged":
        candidates = (integration.get("rebased_tip"), integration.get("head"), stage.get("commit"))
    elif status == "completed" and integration.get("state") is None:
        candidates = (stage.get("commit"),)
    else:
        return None
    return next((sha for sha in candidates if isinstance(sha, str) and COMMIT.fullmatch(sha)), None)


def render(repo, run_id, outcome):
    if run_start(run_id) is None:
        raise SystemExit("run-summary: invalid run identifier")
    if outcome not in ("finished", "halted"):
        raise SystemExit("run-summary: outcome must be finished or halted")

    state_dir = Path(repo) / "state"
    state = object_or_empty(yaml.safe_load((state_dir / "state.yaml").read_text(encoding="utf-8")))
    stages = state.get("stages")
    if not isinstance(stages, list) or not all(isinstance(stage, dict) for stage in stages):
        raise SystemExit("run-summary: invalid stage list")
    selected = {}
    memberships = defaultdict(list)
    for stage in stages:
        stage_id = stage.get("id")
        safe_id = isinstance(stage_id, str) and STAGE_ID.fullmatch(stage_id)
        if stage.get("run_id") == run_id:
            if not safe_id or stage_id in selected:
                raise SystemExit("run-summary: invalid or duplicate stage identifier")
            selected[stage_id] = stage
        if safe_id:
            memberships[stage_id].append(stage)
    if not selected:
        raise SystemExit("run-summary: unknown run")

    budget = read_object(state_dir / "budget.json")
    halt = halt_boundary(budget, stages, run_id) if outcome == "halted" else None
    rows = defaultdict(list)
    for row in dispatch_receipts(state_dir, budget, selected):
        rows[row["stage_id"]].append(row)

    report = []
    for stage_id, stage in selected.items():
        status = stage.get("status")
        if status is None:
            status = "pending"
        if status not in STATUSES:
            raise SystemExit("run-summary: invalid stage status")
        members = memberships[stage_id]
        attempts, tokens = stage_usage(rows[stage_id], stage, members, halt)
        report.append({
            "id": stage_id,
            "status": status,
            "verdict": verdict(state_dir, stage, members, halt),
            "worker_attempts": attempts,
            "retries": attempts - 1 if attempts is not None else None,
            "total_tokens": tokens,
            "landed_commit": landed_commit(stage, status),
        })
    return {"version": 1, "run_id": run_id, "outcome": outcome, "stages": report}


try:
    report = render(*sys.argv[1:])
except (OSError, ValueError, yaml.YAMLError):
    raise SystemExit("run-summary: could not read run evidence")
sys.stdout.buffer.write((json.dumps(report, separators=(",", ":")) + "\n").encode("utf-8"))
PY
