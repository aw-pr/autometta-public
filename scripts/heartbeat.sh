#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# heartbeat.sh: walk state/active-agents/, check liveness, log mtime
# staleness, and budget overrun. Surface findings to state/heartbeat.json.
# Move dead entries to state/recent-agents/ with outcome=exited.
#
# This is a watchdog, not a gate. It never kills, retries, or escalates.
# Exit is always 0 so it cannot break a tick.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The installed-build comparison walks and hashes both trees. It belongs to
# the controller, not an individual subscriber, so tick.sh obtains it once
# and passes the same sanitised JSON to each per-repo heartbeat. Keeping the
# calculation here also leaves direct heartbeat.sh calls self-contained.
build_check_json() {
  local build_checked_at build_check build_check_output build_check_rc
  build_checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  build_check="$(jq -nc --arg checked_at "$build_checked_at" \
    '{status:"unreadable",stale:false,installed_sha:null,checkout_sha:null,checked_at:$checked_at}')"
  set +e
  build_check_output="$("$script_dir/check-installed-build.sh" --json 2>/dev/null)"
  build_check_rc=$?
  set -e
  if [[ "$build_check_rc" -le 2 ]] \
    && printf '%s' "$build_check_output" | jq -e '
      (.status == "current" or .status == "stale" or .status == "unreadable") and
      (.stale | type == "boolean") and
      ((.installed_sha == null) or (.installed_sha | type == "string")) and
      ((.checkout_sha == null) or (.checkout_sha | type == "string")) and
      (.checked_at | type == "string")' >/dev/null 2>&1; then
    build_check="$(printf '%s' "$build_check_output" | jq -c '.')"
  fi
  printf '%s\n' "$build_check"
}

if [[ "${1:-}" == "--build-check-json" && $# -eq 1 ]]; then
  build_check_json
  exit 0
fi

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <repo_root>\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"
active_dir="$repo_root/state/active-agents"
recent_dir="$repo_root/state/recent-agents"
heartbeat_path="$repo_root/state/heartbeat.json"
cost_log_path="$repo_root/state/cost-log.jsonl"
# Deprecated for one release: PHAT_CONTROLLER_HEARTBEAT_STALL.
stall_seconds="${AUTOMETTA_HEARTBEAT_STALL:-${PHAT_CONTROLLER_HEARTBEAT_STALL:-300}}"
outlier_window="${AUTOMETTA_OUTLIER_BASELINE_WINDOW:-10}"
outlier_min_samples="${AUTOMETTA_OUTLIER_MIN_SAMPLES:-5}"
outlier_multiple="${AUTOMETTA_OUTLIER_MULTIPLE:-10}"
# The warning multiple observes; this one acts. Set above the largest spend a
# legitimate stage has ever recorded -- 19,502,742 against a 1.64M median, or
# 11.9x -- so a long-but-honest stage is never killed for being slow. Stage 73
# reached 22.2x on 2026-09-02 and ran for 41 minutes past its warning because
# nothing was listening. 0 disables the kill and restores observe-only.
outlier_kill_multiple="${AUTOMETTA_OUTLIER_KILL_MULTIPLE:-15}"

mkdir -p "$active_dir" "$recent_dir"

# Build the heartbeat report in a tmp file, atomic-rename at end.
tmp_report="$(mktemp)"
tmp_usage="$(mktemp)"
cleanup() {
  rm -f "$tmp_report" "$tmp_usage"
}
trap cleanup EXIT

# The budget parser is the one family-aware reader for a running dispatch's
# transcript. Read it once per live agent at heartbeat cadence, then hand the
# small totals map to the report builder below.
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"
printf '[]\n' > "$tmp_usage"
for agent_path in "$active_dir"/*.json; do
  [[ -f "$agent_path" ]] || continue
  registration="$(jq -c '.' "$agent_path" 2>/dev/null || true)"
  [[ -n "$registration" ]] || continue
  pid="$(printf '%s' "$registration" | jq -r '.pid // empty')"
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  kill -0 "$pid" 2>/dev/null || continue
  working_dir="$(printf '%s' "$registration" | jq -r '.working_dir // empty')"
  family="$(printf '%s' "$registration" | jq -r '.family // empty')"
  started_at="$(printf '%s' "$registration" | jq -r '.started_at // empty')"
  [[ -n "$working_dir" && -n "$family" ]] || continue
  since_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$started_at" '+%s' 2>/dev/null \
    || date -u -d "$started_at" '+%s' 2>/dev/null || printf 0)"
  triple="$(budget_parse_dispatch_tokens_from_transcript \
    "$working_dir" "$since_epoch" "$family" 2>/dev/null || true)"
  [[ -n "$triple" ]] || continue
  IFS=' ' read -r live_input live_cached live_output <<<"$triple"
  if ! [[ "$live_input" =~ ^[0-9]+$ && "$live_cached" =~ ^[0-9]+$ && "$live_output" =~ ^[0-9]+$ ]]; then
    continue
  fi
  live_total=$((live_input + live_cached + live_output))
  jq --argjson pid "$pid" --argjson total "$live_total" \
    '. + [{pid:$pid,total_tokens:$total}]' "$tmp_usage" > "${tmp_usage}.next"
  mv "${tmp_usage}.next" "$tmp_usage"
done

python3 - "$active_dir" "$recent_dir" "$tmp_report" "$stall_seconds" \
  "$cost_log_path" "$tmp_usage" "$outlier_window" "$outlier_min_samples" \
  "$outlier_multiple" "$outlier_kill_multiple" <<'PY'
import json
import os
import signal
import statistics
import subprocess
import sys
import time

(
    active_dir, recent_dir, out_path, stall_str, cost_log_path, usage_path,
    window_str, min_samples_str, multiple_str, kill_multiple_str,
) = sys.argv[1:]

try:
    stall_seconds = int(stall_str)
except ValueError:
    stall_seconds = 300
try:
    baseline_window = max(1, int(window_str))
except ValueError:
    baseline_window = 10
try:
    min_samples = max(1, int(min_samples_str))
except ValueError:
    min_samples = 5
try:
    warning_multiple = max(1.0, float(multiple_str))
except ValueError:
    warning_multiple = 10.0
try:
    kill_multiple = max(0.0, float(kill_multiple_str))
except ValueError:
    kill_multiple = 15.0
now = int(time.time())

comparable_by_role = {}
try:
    with open(cost_log_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            role = row.get("role")
            total = row.get("total_tokens")
            status = row.get("usage_status")
            if (
                not isinstance(role, str)
                or status not in ("recorded", "total_only")
                or not isinstance(total, int)
                or isinstance(total, bool)
                or total < 0
            ):
                continue
            comparable_by_role.setdefault(role, []).append(total)
except OSError:
    pass

baselines = {}
for role, all_totals in comparable_by_role.items():
    totals = all_totals[-baseline_window:]
    baseline = statistics.median(totals) if len(totals) >= min_samples else None
    baselines[role] = {
        "comparable_rows": len(totals),
        "median_tokens": baseline,
    }

try:
    with open(usage_path, "r", encoding="utf-8") as fh:
        live_usage = {
            row["pid"]: row["total_tokens"]
            for row in json.load(fh)
            if isinstance(row.get("pid"), int)
            and isinstance(row.get("total_tokens"), int)
        }
except (OSError, ValueError):
    live_usage = {}

entries = []
for name in sorted(os.listdir(active_dir)):
    if not name.endswith(".json"):
        continue
    path = os.path.join(active_dir, name)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        continue

    pid = doc.get("pid")
    alive = False
    if isinstance(pid, int):
        try:
            os.kill(pid, 0)
            alive = True
        except OSError:
            alive = False

    flags = []
    log_path = doc.get("log_path") or ""
    family = doc.get("family") or ""
    if log_path and os.path.exists(log_path):
        try:
            mtime = int(os.path.getmtime(log_path))
            # 'silent' is only meaningful for streaming families.
            # claude -p emits its log at completion, so a Claude agent
            # is legitimately silent for the entire run. Use over-budget
            # as the only stuck signal for the claude family.
            if family != "claude" and now - mtime > stall_seconds:
                flags.append("silent")
            doc["log_size"] = os.path.getsize(log_path)
            doc["log_mtime_age_seconds"] = now - mtime
        except OSError:
            pass

    started_at = doc.get("started_at")
    elapsed = None
    if started_at:
        try:
            import datetime
            ts = datetime.datetime.strptime(started_at, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc
            )
            elapsed = now - int(ts.timestamp())
            doc["elapsed_seconds"] = elapsed
        except ValueError:
            pass

    budget = doc.get("budget_seconds") or 0
    if isinstance(budget, int) and budget > 0 and elapsed is not None and elapsed > budget:
        flags.append("over-budget")

    live_total = live_usage.get(pid)
    role = doc.get("role") or "unknown"
    baseline_info = baselines.get(role) or {
        "comparable_rows": 0,
        "median_tokens": None,
    }
    baseline = baseline_info["median_tokens"]
    if live_total is not None:
        doc["live_total_tokens"] = live_total
    if baseline is not None:
        doc["baseline_median_tokens"] = baseline
        doc["baseline_sample_size"] = baseline_info["comparable_rows"]
    if (
        alive
        and live_total is not None
        and isinstance(baseline, (int, float))
        and baseline > 0
        and live_total >= baseline * warning_multiple
    ):
        multiple = live_total / baseline
        flags.append("token-outlier")
        doc["token_outlier"] = {
            "baseline_median_tokens": baseline,
            "baseline_sample_size": baseline_info["comparable_rows"],
            "live_total_tokens": live_total,
            "multiple": round(multiple, 1),
            "role": role,
        }
        stage = doc.get("stage_id") or os.path.basename(
            doc.get("card_path") or "unknown"
        ).rsplit(".", 1)[0]
        if kill_multiple > 0 and multiple >= kill_multiple:
            # Terminate the dispatch rather than narrate it. The worktree is
            # left standing, so the work survives for the reaper to preserve;
            # what stops is the spending. Children first, then the wrapper, so
            # the model process does not outlive the script that owns it.
            killed = False
            try:
                subprocess.run(["pkill", "-TERM", "-P", str(pid)], check=False)
                os.kill(int(pid), signal.SIGTERM)
                killed = True
            except (OSError, ValueError) as error:
                print(
                    "WARNING: token outlier: %s %s pid=%s at %.1fx could not be "
                    "terminated (%s); it is still running"
                    % (stage, role, pid, multiple, error)
                )
            if killed:
                flags.append("token-outlier-killed")
                doc["token_outlier"]["killed_at"] = "%dZ" % now
                doc["token_outlier"]["kill_multiple"] = kill_multiple
                doc["outcome"] = "killed-token-outlier"
                print(
                    "KILLED: token outlier: %s %s pid=%s live_tokens=%d "
                    "baseline_median=%s multiple=%.1fx exceeded kill threshold "
                    "%.1fx; work left in the run worktree"
                    % (stage, role, pid, live_total, baseline, multiple,
                       kill_multiple)
                )
        else:
            print(
                "WARNING: token outlier: %s %s pid=%s live_tokens=%d "
                "baseline_median=%s multiple=%.1fx; below the %.1fx kill "
                "threshold, agent remains running"
                % (stage, role, pid, live_total, baseline, multiple,
                   kill_multiple)
            )

    doc["alive"] = alive
    doc["flags"] = flags

    if not alive:
        # Move to recent-agents with outcome=exited; the real outcome
        # gets set by the tick reaper if it has better information.
        doc.setdefault("outcome", "exited")
        doc["exited_at"] = "%dZ" % now
        # Re-stamp using ISO format
        import datetime as dt2
        doc["exited_at"] = dt2.datetime.fromtimestamp(now, tz=dt2.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        stage = doc.get("card_path") or ""
        slug = os.path.basename(stage).rsplit(".", 1)[0] or "unknown"
        target = os.path.join(recent_dir, "%d-%s.json" % (pid or 0, slug))
        try:
            with open(target, "w", encoding="utf-8") as fh:
                json.dump(doc, fh, indent=2, sort_keys=True)
                fh.write("\n")
            os.remove(path)
        except OSError:
            pass
        continue

    entries.append(doc)

report = {
    "checked_at": "%sZ" % time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)),
    "stall_threshold_seconds": stall_seconds,
    "outlier_policy": {
        "baseline_window": baseline_window,
        "minimum_comparable_rows": min_samples,
        "warning_multiple": warning_multiple,
        "kill_multiple": kill_multiple,
    },
    "baselines": baselines,
    "active_count": len(entries),
    "entries": entries,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

# Build drift is intentionally checked at heartbeat cadence. A production tree
# walk takes seconds, so polling it on every 5s display refresh would make the
# observability seam slower than its own refresh interval. Exit 1 means stale;
# exit 2, malformed output, or a missing helper all become an unreadable
# verdict. Heartbeat remains a watchdog and still exits 0.
if [[ -n "${AUTOMETTA_BUILD_CHECK_JSON:-}" ]] \
  && printf '%s' "$AUTOMETTA_BUILD_CHECK_JSON" | jq -e '
    (.status == "current" or .status == "stale" or .status == "unreadable") and
    (.stale | type == "boolean") and
    ((.installed_sha == null) or (.installed_sha | type == "string")) and
    ((.checkout_sha == null) or (.checkout_sha | type == "string")) and
    (.checked_at | type == "string")' >/dev/null 2>&1; then
  build_check="$(printf '%s' "$AUTOMETTA_BUILD_CHECK_JSON" | jq -c '.')"
else
  build_check="$(build_check_json)"
fi
jq --argjson build_check "$build_check" '. + {build_check:$build_check}' \
  "$tmp_report" > "${tmp_report}.next"
mv "${tmp_report}.next" "$tmp_report"

mv "$tmp_report" "$heartbeat_path"
tmp_report=""
exit 0
