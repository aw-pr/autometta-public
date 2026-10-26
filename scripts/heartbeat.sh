#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# heartbeat.sh: walk state/active-agents/, check liveness, log mtime
# staleness, and budget overrun. Surface findings to state/heartbeat.json.
# Move dead entries to state/recent-agents/ with outcome=exited.
#
# This watchdog kills token outliers; it never retries or escalates.
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
# Warning and kill multiples use uncached tokens, falling back to total tokens
# when the role has no usable uncached baseline. Each kill can be disabled with 0.
outlier_kill_multiple="${AUTOMETTA_OUTLIER_KILL_MULTIPLE:-15}"
# Independent backstop for loops dominated by cache reads.
outlier_total_kill_multiple="${AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE:-40}"

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
  live_uncached=$((live_input + live_output))
  jq --argjson pid "$pid" --argjson total "$live_total" --argjson uncached "$live_uncached" --argjson input "$live_input" \
    '. + [{pid:$pid,total_tokens:$total,uncached_tokens:$uncached,uncached_input_tokens:$input}]' "$tmp_usage" > "${tmp_usage}.next"
  mv "${tmp_usage}.next" "$tmp_usage"
done

# The live Codex weekly reading, for the run cap register-agent.sh stamped
# on each Codex dispatch. Read once per heartbeat, never per agent.
codex_reading="$(python3 "$script_dir/quota-window.py" codex 2>/dev/null || printf '{}')"

python3 - "$active_dir" "$recent_dir" "$tmp_report" "$stall_seconds" \
  "$cost_log_path" "$tmp_usage" "$outlier_window" "$outlier_min_samples" \
  "$outlier_multiple" "$outlier_kill_multiple" "$outlier_total_kill_multiple" "$codex_reading" "$script_dir" <<'PY'
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
    total_kill_multiple_str, codex_reading_str, script_dir,
) = sys.argv[1:]

sys.path.insert(0, os.path.join(script_dir, "lib"))
try:
    from lifecycle_events import agent_event
except ImportError:
    def agent_event(*args, **kwargs):
        pass

try:
    codex_reading = json.loads(codex_reading_str)
except ValueError:
    codex_reading = {}
codex_weekly = next(
    (w for w in (codex_reading.get("windows") or []) if isinstance(w, dict) and w.get("label") == "Weekly"),
    None,
) if isinstance(codex_reading, dict) and codex_reading.get("status") == "known" else None


def terminate(pid):
    """Children first, then the wrapper, so the model process does not outlive
    the script that owns it. Returns the error, or None once signalled."""
    try:
        subprocess.run(["pkill", "-TERM", "-P", str(pid)], check=False)
        os.kill(int(pid), signal.SIGTERM)
    except (OSError, ValueError) as error:
        return error
    return None

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
try:
    total_kill_multiple = max(0.0, float(total_kill_multiple_str))
except ValueError:
    total_kill_multiple = 40.0
now = int(time.time())


def valid_tokens(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


comparable_by_role = {}
uncached_by_role = {}
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
            if not isinstance(role, str):
                continue
            if (
                status in ("recorded", "total_only")
                and valid_tokens(total)
            ):
                comparable_by_role.setdefault(role, []).append(total)
            input_tokens = row.get("input_tokens")
            output_tokens = row.get("output_tokens")
            if (
                status == "recorded"
                and valid_tokens(input_tokens)
                and valid_tokens(output_tokens)
            ):
                uncached_by_role.setdefault(role, []).append(input_tokens + output_tokens)
except OSError:
    pass

baselines = {}
for role in comparable_by_role.keys() | uncached_by_role.keys():
    totals = comparable_by_role.get(role, [])[-baseline_window:]
    uncached = uncached_by_role.get(role, [])[-baseline_window:]
    baseline = statistics.median(totals) if len(totals) >= min_samples else None
    baselines[role] = {
        "comparable_rows": len(totals),
        "median_tokens": baseline,
        "comparable_uncached_rows": len(uncached),
        "median_uncached_tokens": statistics.median(uncached) if len(uncached) >= min_samples else None,
    }

try:
    with open(usage_path, "r", encoding="utf-8") as fh:
        live_usage = {
            row["pid"]: row
            for row in json.load(fh)
            if isinstance(row.get("pid"), int)
            and valid_tokens(row.get("total_tokens"))
            and valid_tokens(row.get("uncached_tokens"))
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
            # 'silent' is only meaningful when this dispatch streams its log.
            if (family == "codex" or doc.get("log_streams") is True) and now - mtime > stall_seconds:
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

    usage = live_usage.get(pid) or {}
    live_total = usage.get("total_tokens")
    live_uncached = usage.get("uncached_tokens")
    role = doc.get("role") or "unknown"
    baseline_info = baselines.get(role) or {
        "comparable_rows": 0,
        "median_tokens": None,
        "comparable_uncached_rows": 0,
        "median_uncached_tokens": None,
    }
    baseline = baseline_info["median_tokens"]
    uncached_baseline = baseline_info["median_uncached_tokens"]
    if live_total is not None:
        doc["live_total_tokens"] = live_total
        doc["live_uncached_tokens"] = live_uncached
        doc["live_uncached_input_tokens"] = usage.get("uncached_input_tokens")
    doc["baseline_median_uncached_tokens"] = uncached_baseline
    if baseline is not None:
        doc["baseline_median_tokens"] = baseline
        doc["baseline_sample_size"] = baseline_info["comparable_rows"]
    total_ratio = (
        live_total / baseline
        if live_total is not None and baseline is not None and baseline > 0 else None
    )
    uncached_ratio = (
        live_uncached / uncached_baseline
        if live_uncached is not None and uncached_baseline is not None and uncached_baseline > 0 else None
    )
    measure = "uncached" if uncached_ratio is not None else "total"
    multiple = uncached_ratio if measure == "uncached" else total_ratio
    primary_kill = multiple is not None and kill_multiple > 0 and multiple >= kill_multiple
    backstop_kill = (
        total_ratio is not None and total_kill_multiple > 0 and total_ratio >= total_kill_multiple
    )
    warns = multiple is not None and multiple >= warning_multiple
    selected_kill_multiple = kill_multiple
    if backstop_kill and not primary_kill:
        measure = "total"
        multiple = total_ratio
        selected_kill_multiple = total_kill_multiple
    if alive and (warns or primary_kill or backstop_kill):
        measured_live = live_uncached if measure == "uncached" else live_total
        measured_baseline = uncached_baseline if measure == "uncached" else baseline
        flags.append("token-outlier")
        doc["token_outlier"] = {
            "baseline_median_tokens": baseline,
            "baseline_sample_size": baseline_info["comparable_rows"],
            "live_total_tokens": live_total,
            "live_uncached_tokens": live_uncached,
            "baseline_median_uncached_tokens": uncached_baseline,
            "baseline_uncached_sample_size": baseline_info["comparable_uncached_rows"],
            "measure": measure,
            "multiple": round(multiple, 1),
            "role": role,
        }
        stage = doc.get("stage_id") or os.path.basename(
            doc.get("card_path") or "unknown"
        ).rsplit(".", 1)[0]
        if primary_kill or backstop_kill:
            # Terminate the dispatch rather than narrate it. The worktree is
            # left standing, so the work survives for the reaper to preserve;
            # what stops is the spending. Children first, then the wrapper, so
            # the model process does not outlive the script that owns it.
            error = terminate(pid)
            killed = error is None
            if not killed:
                print(
                    "WARNING: token outlier: %s %s pid=%s at %.1fx could not be "
                    "terminated (%s); it is still running"
                    % (stage, role, pid, multiple, error)
                )
            if killed:
                flags.append("token-outlier-killed")
                doc["token_outlier"]["killed_at"] = "%dZ" % now
                doc["token_outlier"]["kill_multiple"] = selected_kill_multiple
                doc["outcome"] = "killed-token-outlier"
                print(
                    "KILLED: token outlier: %s %s pid=%s measure=%s live_tokens=%d "
                    "baseline_median=%s multiple=%.1fx exceeded kill threshold "
                    "%.1fx; work left in the run worktree"
                    % (stage, role, pid, measure, measured_live, measured_baseline, multiple,
                       selected_kill_multiple)
                )
        else:
            print(
                "WARNING: token outlier: %s %s pid=%s measure=%s live_tokens=%d "
                "baseline_median=%s multiple=%.1fx; kill threshold=%.1fx "
                "(0 disables), agent remains running"
                % (stage, role, pid, measure, measured_live, measured_baseline, multiple,
                   selected_kill_multiple)
            )

    # The run cap is account-wide: the weekly window has no per-dispatch
    # split, so concurrent Codex runs share one slot allowance between them.
    quota_start = doc.get("quota_start")
    if (
        alive
        and family == "codex"
        and isinstance(quota_start, dict)
        and codex_weekly is not None
        and codex_weekly.get("resets_at") == quota_start.get("week_resets_at")
        and isinstance(quota_start.get("used"), (int, float))
        and isinstance(quota_start.get("run_cap_percent"), (int, float))
        and quota_start["run_cap_percent"] > 0
        and isinstance(codex_weekly.get("utilization"), (int, float))
    ):
        spent = codex_weekly["utilization"] - quota_start["used"]
        doc["quota_run_spent_percent"] = round(spent, 2)
        if spent >= quota_start["run_cap_percent"]:
            stage = doc.get("stage_id") or os.path.basename(
                doc.get("card_path") or "unknown"
            ).rsplit(".", 1)[0]
            error = terminate(pid)
            if error is None:
                flags.append("quota-run-cap-killed")
                doc["outcome"] = "killed-quota-run-cap"
                doc["quota_run_cap_killed_at"] = "%dZ" % now
                print(
                    "KILLED: quota run cap: %s %s pid=%s moved the Codex weekly "
                    "window %.1f%% (cap %.1f%%, from %.1f%%); work left in the "
                    "run worktree"
                    % (stage, role, pid, spent, quota_start["run_cap_percent"],
                       quota_start["used"])
                )
            else:
                print(
                    "WARNING: quota run cap: %s %s pid=%s could not be "
                    "terminated (%s); it is still running" % (stage, role, pid, error)
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
            agent_event(os.path.dirname(os.path.dirname(active_dir)), doc, finished=True)
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
        "total_kill_multiple": total_kill_multiple,
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
