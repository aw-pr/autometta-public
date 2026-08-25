#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# agent-ticker.sh: render a compact ACTIVE / RECENT / SCHEDULED view of
# dispatched agents and stage cards, suitable for the third tmux pane.
#
# Args:
#   <repo_root> [--once]
#
# Without --once, loops forever refreshing every $AUTOMETTA_TICKER_INTERVAL
# seconds (default 5). Quits cleanly on SIGINT/SIGTERM.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: %s <repo_root> [--once]\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"
once=false
if [[ "${2:-}" == "--once" ]]; then
  once=true
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Deprecated for one release: PHAT_CONTROLLER_TICKER_INTERVAL.
refresh_interval="${AUTOMETTA_TICKER_INTERVAL:-${PHAT_CONTROLLER_TICKER_INTERVAL:-5}}"
# Deprecated for one release: PHAT_CONTROLLER_COST_LOG_TAIL_ROWS.
cost_log_tail_rows="${AUTOMETTA_COST_LOG_TAIL_ROWS:-${PHAT_CONTROLLER_COST_LOG_TAIL_ROWS:-5000}}"
build_checked_at=0
build_sha="unknown"
installed_sha="unknown"
build_warning=""

refresh_build_status() {
  local now version
  now="$(date +%s)"
  (( now - build_checked_at < 60 )) && return 0
  build_checked_at="$now"
  build_sha="$(git -C "$script_dir/.." rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  version="$(autometta --version 2>/dev/null || true)"
  installed_sha="$(printf '%s' "$version" | grep -Eo '[0-9a-f]{7,40}' | head -n1 || true)"
  [[ -n "$installed_sha" ]] || installed_sha="unknown"
  [[ "$installed_sha" == unknown ]] || installed_sha="${installed_sha:0:7}"
  build_warning=""
  if [[ "$build_sha" != unknown && "$installed_sha" != unknown && "$build_sha" != "$installed_sha" ]]; then
    build_warning="BUILD DRIFT: installed ${installed_sha}, checkout ${build_sha} (fallback comparison)"
  fi
}

# Resolve list-cards.sh: prefer this script's own dir (dev checkout), then
# fall back to the brew-installed CLI's scripts dir, so a stale tmux pane
# launched from an older cellar still finds the current helper.
resolve_list_cards() {
  if [[ -x "$script_dir/list-cards.sh" ]]; then
    printf '%s' "$script_dir/list-cards.sh"
    return 0
  fi
  if command -v autometta >/dev/null 2>&1; then
    local autometta_bin candidate
    autometta_bin="$(command -v autometta)"
    candidate="$(cd "$(dirname "$autometta_bin")/.." && pwd)/scripts/list-cards.sh"
    [[ -x "$candidate" ]] && printf '%s' "$candidate"
  fi
}
list_cards_bin="$(resolve_list_cards)"

# The alert-worthy stage statuses have one definition in the tree; the ALERTS
# panel below reads it rather than spelling the list out again.
# shellcheck source=./alert-statuses.sh
source "$script_dir/alert-statuses.sh"

# Strip one layer of surrounding quotes. subscribe-repo.sh writes quoted
# strings; the subscriber template uses the unquoted form. Accept both, as
# tick.sh's read_subscriber_field does.
unquote_field() {
  local v="$1"
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# Is this repo an enabled subscriber? An empty queue only warrants an alert
# where the controller is actually meant to be dispatching. Prints
# true | false | unknown.
subscriber_enabled() {
  local controller_home
  controller_home="$(autometta_controller_home)"
  local resolved f rp
  resolved="$(cd "$repo_root" 2>/dev/null && pwd || printf '%s' "$repo_root")"
  for f in "$controller_home"/subscribers/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "template.yaml" ]] && continue
    rp="$(unquote_field "$(sed -n 's/^repo_path:[[:space:]]*//p' "$f" | head -n1)")"
    if [[ "$rp" == "$repo_root" || "$rp" == "$resolved" ]]; then
      unquote_field "$(sed -n 's/^enabled:[[:space:]]*//p' "$f" | head -n1)"
      return 0
    fi
  done
  printf 'unknown'
}

render_full() {
  local active_dir="$repo_root/state/active-agents"
  local recent_dir="$repo_root/state/recent-agents"
  local heartbeat_path="$repo_root/state/heartbeat.json"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf 'autometta %s agent ticker — %s\n' "$build_sha" "$now_iso"
  printf 'Repo: %s\n' "$repo_root"
  if [[ -n "$build_warning" ]]; then
    printf 'ALERTS (need attention)\n  %s\n\n' "$build_warning"
  fi
  if [[ -f "$heartbeat_path" ]]; then
    python3 - "$heartbeat_path" <<'PY' || true
import json, sys
from datetime import datetime, timezone
try:
    with open(sys.argv[1]) as fh:
        rep = json.load(fh)
    ts = rep.get("checked_at")
    dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    age = int((datetime.now(timezone.utc) - dt).total_seconds())
except Exception:
    print("Health: heartbeat.json unreadable")
    sys.exit(0)
if age < 60:
    fmt = "%ds" % age
elif age < 3600:
    fmt = "%dm %ds" % (age // 60, age % 60)
else:
    fmt = "%dh %dm" % (age // 3600, (age % 3600) // 60)
if age > 600:
    tag = "STALE — controller may have halted or LaunchAgent stopped firing"
elif age > 180:
    tag = "WARN"
else:
    tag = "ok"
print("Health: last heartbeat %s ago (%s)" % (fmt, tag))
PY
  else
    printf 'Health: no heartbeat.json yet\n'
  fi
  printf '\n'

  # ALERTS panel — surface any stage in a terminal-failure state plus
  # budget halts and stale heartbeats. Shown only when something needs
  # the operator's attention so the panel stays signal, not noise.
  local state_path="$repo_root/state/state.yaml"
  local budget_path="$repo_root/state/budget.json"
  # The card table is read once and shared by ALERTS and SCHEDULED, so the
  # alert and the panel can never disagree about queue depth.
  local cards=""
  if [[ -n "$list_cards_bin" ]]; then
    cards="$("$list_cards_bin" "$repo_root" 2>/dev/null || true)"
  fi
  local pending_count in_flight_count enabled
  pending_count="$(printf '%s' "$cards" | awk -F'\t' '$2 == "pending"' | grep -c . || true)"
  in_flight_count="$(printf '%s' "$cards" | awk -F'\t' '$2 == "in_flight"' | grep -c . || true)"
  enabled="$(subscriber_enabled)"
  python3 - "$state_path" "$budget_path" "$repo_root" "$pending_count" "$in_flight_count" "$enabled" "$(alert_stage_statuses_json)" <<'PY' || true
import json, os, sys
state_path, budget_path, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]
pending_count, in_flight_count, enabled = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
ALERT_STATUSES = frozenset(json.loads(sys.argv[7]))
alerts = []

# Empty queue on an enabled subscriber. The controller will tick this repo
# every interval of every window and dispatch nothing, which is how ~9.4M
# tokens went on an empty queue over the 2026-08-13 weekend
# (token-maxing/WEEKEND-RUNS.md) and how the 2026-08-23 overnight windows came
# up dead. Suppressed while something is in flight -- a queue drained down to
# its last running stage is not idle.
if enabled == "true" and pending_count == 0 and in_flight_count == 0:
    alerts.append("queue empty: 0 pending stages while subscriber is enabled, "
                  "nothing will dispatch this window")

# Budget halts
try:
    with open(budget_path) as fh:
        b = json.load(fh)
    if b.get("halted"):
        alerts.append("budget halted: %s" % (b.get("halt_reason") or "unknown"))
    cf = b.get("consecutive_failures", 0)
    cap = b.get("consecutive_failure_cap", 3)
    if cf > 0:
        alerts.append("consecutive failures: %d/%d" % (cf, cap))
except Exception:
    pass

# Stages in terminal-failure states (read state.yaml as text — avoids yaml dep)
try:
    with open(state_path) as fh:
        lines = fh.read().splitlines()
    current_id = None
    current_status = None
    blocked = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("- id:"):
            if current_id and current_status in ALERT_STATUSES:
                blocked.append((current_id, current_status))
            current_id = stripped.split(":", 1)[1].strip()
            current_status = None
        elif stripped.startswith("status:") and current_id:
            current_status = stripped.split(":", 1)[1].strip()
    if current_id and current_status in ALERT_STATUSES:
        blocked.append((current_id, current_status))
    for sid, st in blocked:
        # If verifier artefact exists, surface the first FAIL criterion
        artefact = os.path.join(repo_root, "state", "verifiers", "%s.json" % sid)
        detail = ""
        if os.path.exists(artefact):
            try:
                with open(artefact) as fh:
                    a = json.load(fh)
                for c in a.get("criteria", []):
                    if c.get("verdict") == "FAIL":
                        detail = " — FAIL crit %s: %s" % (c.get("id"), (c.get("name") or "")[:60])
                        break
            except Exception:
                pass
        alerts.append("%s: %s%s" % (sid, st, detail))
except Exception:
    pass

if alerts:
    RED, RESET = "\033[31m", "\033[0m"
    print("ALERTS (need attention)")
    for a in alerts:
        print("  %s%s%s" % (RED, a, RESET))
    print()
PY

  # SPEND is deliberately computed from a bounded tail. The ledger is
  # append-only, so recent rows are at the end and refresh cost stays fixed as
  # cost-log.jsonl grows.
  local cost_log_path="$repo_root/state/cost-log.jsonl"
  printf 'SPEND (USD estimates use list prices)\n'
  if [[ -f "$budget_path" ]] && command -v jq >/dev/null 2>&1; then
    local spend_fields spent cap today_cost week_cost hit hour_tokens pct
    spend_fields="$({ if [[ -f "$cost_log_path" ]]; then tail -n "$cost_log_tail_rows" "$cost_log_path" 2>/dev/null; fi; } \
      | jq -sr \
      --argjson budget "$(jq -c '.' "$budget_path" 2>/dev/null || printf '{}')" \
      --argjson now "$(date -u +%s)" '
      def tokens: ((.input_tokens // 0) + (.cached_input_tokens // 0) + (.output_tokens // 0));
      def epoch: try (.ts | fromdateiso8601) catch 0;
      [ .[] | select(type == "object") ] as $rows |
      ($now - ($now % 86400)) as $today |
      ($budget.tokens_spent // 0) as $spent |
      ($budget.token_cap_total // 0) as $cap |
      [$rows[] | select(epoch >= $today)] as $today_rows |
      [$rows[] | select(epoch >= ($today - 518400))] as $week_rows |
      [$rows[] | select(epoch >= ($now - 3600))] as $hour_rows |
      ($today_rows | map(.cost_usd_est // 0) | add // 0) as $today_cost |
      ($week_rows | map(.cost_usd_est // 0) | add // 0) as $week_cost |
      ($today_rows | map(.cache_hit_rate // 0) | if length > 0 then add / length else 0 end) as $hit |
      ($hour_rows | map(tokens) | add // 0) as $hour_tokens |
      [$spent,$cap,$today_cost,$week_cost,$hit,$hour_tokens] | @tsv
    ' 2>/dev/null || true)"
    if [[ -n "$spend_fields" ]]; then
      IFS=$'\t' read -r spent cap today_cost week_cost hit hour_tokens <<<"$spend_fields"
      pct="$(awk -v s="$spent" -v c="$cap" 'BEGIN { printf "%.1f", (c > 0 ? s * 100 / c : 0) }')"
      short_tokens() { awk -v n="$1" 'BEGIN { if (n>=1000000000) printf "%.1fB",n/1000000000; else if (n>=1000000) printf "%.1fM",n/1000000; else if (n>=1000) printf "%.1fK",n/1000; else printf "%d",n }'; }
      printf '  window: %s/%s tokens (%s%%)\n' "$(short_tokens "$spent")" "$(short_tokens "$cap")" "$pct"
      printf '  today: $%.2f est  |  7d: $%.2f est\n' "$today_cost" "$week_cost"
      printf '  mean cache hit today: %g%%  |  last hour: %s tokens/h\n' \
        "$(awk -v h="$hit" 'BEGIN { print h * 100 }')" "$(short_tokens "$hour_tokens")"
      printf '  exact window: %s / %s tokens (%g%%)\n' "$spent" "$cap" "$pct"
      printf '  exact today: $%g est  |  7d: $%g est (state/cost-log.jsonl)\n' "$today_cost" "$week_cost"
    else
      printf '  (budget or cost log unreadable)\n'
    fi
  else
    printf '  (budget.json missing or jq unavailable)\n'
  fi
  local quota_path="$repo_root/state/quota-window.json"
  if [[ -f "$quota_path" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '
      .families | to_entries[] |
      if .value.status == "known" then
        (.value.windows | sort_by(-.utilization) | .[0]) as $window |
        "  quota \(.key): \($window.label) \($window.utilization)% used, resets \($window.resets_at // "unknown")"
      else
        "  quota \(.key): unknown (\(.value.reason // "no reason"))"
      end
    ' "$quota_path" 2>/dev/null || printf '  quota: unknown (tick reading unreadable)\n'
  else
    printf '  quota: unknown (no tick reading)\n'
  fi
  printf '\n'

  printf 'ACTIVE\n'
  if [[ -f "$heartbeat_path" ]]; then
    python3 - "$heartbeat_path" "$active_dir" \
      "${AUTOMETTA_CLAUDE_PROJECTS:-$HOME/.claude/projects}" \
      "${AUTOMETTA_CODEX_SESSIONS:-$HOME/.codex/sessions}" <<'PY' || true
import calendar, glob, json, os, re, sys
from datetime import datetime, timezone
try:
    with open(sys.argv[1]) as fh:
        rep = json.load(fh)
except Exception:
    print("  (heartbeat.json unreadable)")
    sys.exit(0)
entries = rep.get("entries", [])
active_dir, claude_root, codex_root = sys.argv[2:]

def epoch(ts):
    try:
        return calendar.timegm(datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").timetuple())
    except Exception:
        return 0

def registry(entry):
    path = os.path.join(active_dir, "%s.json" % entry.get("pid"))
    try:
        with open(path) as fh: return json.load(fh), path
    except Exception:
        return {}, path

def transcript(entry, reg):
    cached = reg.get("transcript_path")
    if cached and os.path.isfile(cached):
        return cached
    cwd = reg.get("working_dir")
    if not cwd:
        return None
    started = epoch(reg.get("started_at") or "")
    family = entry.get("family")
    candidates = []
    if family == "claude":
        slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
        candidates = glob.glob(os.path.join(claude_root, slug, "*.jsonl"))
    elif family == "codex":
        paths = glob.glob(os.path.join(codex_root, "*", "*", "*", "rollout-*.jsonl"))
        paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        for path in paths[:200]:
            try:
                if os.path.getmtime(path) < started - 120:
                    continue
                with open(path, errors="replace") as fh:
                    meta = json.loads(fh.readline()).get("payload") or {}
                if meta.get("cwd") == cwd:
                    candidates.append(path)
            except Exception:
                pass
    candidates = [p for p in candidates if os.path.getmtime(p) >= started - 120]
    if candidates:
        reg["transcript_path"] = max(candidates, key=os.path.getmtime)
        return reg["transcript_path"]
    return None

def transcript_tokens(path, family, reg):
    if not path:
        return None
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2); size = fh.tell()
            if family == "claude":
                if reg.get("transcript_path") != path:
                    reg["transcript_path"], reg["transcript_offset"], reg["transcript_tokens"] = path, 0, 0
                    reg["transcript_tokens_found"] = False
                offset = min(int(reg.get("transcript_offset") or 0), size)
                total = int(reg.get("transcript_tokens") or 0)
                previously_found = bool(reg.get("transcript_tokens_found"))
                fh.seek(offset); chunk = fh.read(16 * 1024 * 1024)
                cut = chunk.rfind(b"\n")
                if cut < 0:
                    return (total if previously_found else None), offset < size
                consumed = chunk[:cut + 1]
                data = consumed.decode("utf-8", "replace")
                reg["transcript_offset"] = offset + len(consumed)
            else:
                fh.seek(max(0, size - 16 * 1024 * 1024))
                data = fh.read().decode("utf-8", "replace")
                if size > 16 * 1024 * 1024: data = data.split("\n", 1)[-1]
                total = 0
    except OSError:
        return None, False
    found = False
    for line in data.splitlines():
        if '"usage"' not in line and '"total_token_usage"' not in line:
            continue
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        if family == "codex":
            info = doc.get("payload") or doc
            usage = info.get("total_token_usage") or (info.get("info") or {}).get("total_token_usage")
            if isinstance(usage, dict) and isinstance(usage.get("total_tokens"), int):
                total = max(total, usage["total_tokens"]); found = True
        else:
            usage = (doc.get("message") or {}).get("usage") or doc.get("usage")
            if isinstance(usage, dict):
                values = [usage.get(k) for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")]
                if any(isinstance(v, int) for v in values):
                    total += sum(v for v in values if isinstance(v, int)); found = True
    if family == "claude":
        reg["transcript_tokens"] = total
        reg["transcript_tokens_found"] = found or previously_found
        return (total if reg["transcript_tokens_found"] else None), reg.get("transcript_offset", 0) < size
    return (total if found else None), False

def save_registry(path, reg):
    try:
        tmp = path + ".ticker-tmp"
        with open(tmp, "w") as fh:
            json.dump(reg, fh, indent=2, sort_keys=True); fh.write("\n")
        os.replace(tmp, path)
    except OSError:
        pass

def log_tokens(path):
    try:
        with open(path, errors="replace") as fh:
            fh.seek(0, 2); fh.seek(max(0, fh.tell() - 262144)); data = fh.read()
        vals = [int(x.replace(",", "")) for x in re.findall(r"(?:tokens used\s*|Total tokens:\s*)([0-9][0-9,]*)", data, re.I)]
        return vals[-1] if vals else None
    except Exception:
        return None

if not entries:
    print("  (none)")
else:
    for e in entries:
        flags = ",".join(e.get("flags", [])) or "fresh"
        reg, reg_path = registry(e)
        path = transcript(e, reg)
        running_tokens, catching_up = transcript_tokens(path, e.get("family"), reg) if path else (None, False)
        if path: save_registry(reg_path, reg)
        if running_tokens is None:
            running_tokens = log_tokens(e.get("log_path", ""))
        elapsed = int(e.get("elapsed_seconds") or 0)
        token_text = ((str(running_tokens) + "+") if catching_up else str(running_tokens)) if running_tokens is not None else ("waiting" if elapsed < 120 else "unavailable")
        print("  %-7s %-9s tokens:%-8s pid %-6s %5ss  %-24s log:%sB  %s" % (
            e.get("family", "?"),
            e.get("role", "?"),
            token_text,
            e.get("pid", "?"),
            e.get("elapsed_seconds", "?"),
            (e.get("card_path","")[-24:] or "-").lstrip("/"),
            e.get("log_size", "?"),
            flags,
        ))
PY
  else
    printf '  (no heartbeat yet — run scripts/heartbeat.sh %s)\n' "$repo_root"
  fi
  printf '\n'

  # Deprecated for one release: PHAT_CONTROLLER_RECENT_MAX_AGE_DAYS.
  local recent_max_age_days="${AUTOMETTA_RECENT_MAX_AGE_DAYS:-${PHAT_CONTROLLER_RECENT_MAX_AGE_DAYS:-7}}"
  # Live worker-log tail: when a stage is actually in_progress, show the
  # tail of its worker log directly in this pane so the operator does not
  # have to go hunting for the log path while a worker is running.
  #
  # The log lives under the canonical repo's state/logs, not the run
  # worktree's: spawn-worker.sh is passed repo_root and writes there, so this
  # path survives worktree-per-run dispatch unchanged.
  #
  # A `claude -p` worker writes nothing until it finishes and then emits the
  # whole log in one burst (lessons.md gotcha 6), so an empty file here is
  # normal rather than a stalled worker. Say so, or the panel invites exactly
  # the wrong conclusion at exactly the wrong moment.
  if [[ -f "$state_path" ]] && command -v yq >/dev/null 2>&1; then
    local live_stage live_status
    live_stage="$(yq -r '.current_stage // ""' "$state_path" 2>/dev/null || true)"
    if [[ -n "$live_stage" && "$live_stage" != "null" ]]; then
      live_status="$(STAGE_ID="$live_stage" yq -r '.stages[] | select(.id == strenv(STAGE_ID)) | .status // ""' "$state_path" 2>/dev/null || true)"
      if [[ "$live_status" == "in_progress" ]]; then
        local live_log="$repo_root/state/logs/${live_stage}-worker.log"
        printf 'LIVE (%s worker log, tail -n 8)\n' "$live_stage"
        if [[ -s "$live_log" ]]; then
          tail -n 8 "$live_log" | sed 's/^/  /'
        elif [[ -f "$live_log" ]]; then
          printf '  (log is still empty; a claude worker writes nothing until it exits)\n'
        else
          printf '  (no worker log yet at %s)\n' "$live_log"
        fi
        printf '\n'
      fi
    fi
  fi

  printf 'RECENT (last 5, max %sd old)\n' "$recent_max_age_days"
  if [[ -d "$recent_dir" ]]; then
    python3 - "$recent_dir" "$recent_max_age_days" "$(alert_stage_statuses_json)" <<'PY' || true
import json, os, sys
from datetime import datetime, timezone
d = sys.argv[1]
max_age_days = float(sys.argv[2])
# A finished run reads red on the same stage statuses the ALERTS panel treats
# as alert-worthy, read from the one definition, plus the outcome words only a
# run has (a stage is never "stuck", a status is never an outcome).
ALERT_STATUSES = frozenset(json.loads(sys.argv[3]))
now = datetime.now(timezone.utc)
def age(ts):
    if not ts:
        return "?"
    try:
        dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return "?"
    s = int((now - dt).total_seconds())
    if s < 60:    return f"{s}s ago"
    if s < 3600:  return f"{s//60}m ago"
    if s < 86400: return f"{s//3600}h{(s%3600)//60}m ago"
    return f"{s//86400}d ago"
cutoff = now.timestamp() - (max_age_days * 86400)
files = []
try:
    for n in os.listdir(d):
        if n.endswith(".json"):
            p = os.path.join(d, n)
            mtime = os.path.getmtime(p)
            if mtime < cutoff:
                continue
            files.append((mtime, p))
except FileNotFoundError:
    pass
files.sort(reverse=True)
if not files:
    print(f"  (none in the last {max_age_days:g}d)")
else:
    RED, RESET = "\033[31m", "\033[0m"
    FAIL_OUTCOMES = ALERT_STATUSES | {"fail", "error", "stuck"}
    for _, p in files[:5]:
        try:
            with open(p) as fh:
                e = json.load(fh)
            card = os.path.basename(e.get("card_path","") or "-")
            card = card[:34]
            outcome = str(e.get("outcome","?"))
            row = "  %-10s %-7s %-9s %-34s %-7s ran %ss" % (
                age(e.get("exited_at")),
                e.get("family","?"),
                e.get("role","?"),
                card,
                outcome,
                e.get("elapsed_seconds","?"),
            )
            if outcome.lower() in FAIL_OUTCOMES:
                row = RED + row + RESET
            print(row)
        except Exception:
            pass
PY
  else
    printf '  (none in the last %sd)\n' "$recent_max_age_days"
  fi
  printf '\n'

  # SCHEDULED reads list-cards.sh, which reads state/state.yaml -- the queue
  # the controller actually dispatches from. The depth is printed as a number
  # whether or not it is zero, because "(no pending cards)" is easy to read as
  # "nothing to show" and an empty queue on an enabled subscriber is the whole
  # signal.
  printf 'SCHEDULED (queue depth %s pending, %s in flight)\n' \
    "$pending_count" "$in_flight_count"
  if [[ -n "$list_cards_bin" ]]; then
    local unqueued_count
    unqueued_count="$(printf '%s' "$cards" | awk -F'\t' '$2 == "unqueued"' | grep -c . || true)"
    printf '%s' "$cards" | awk -F'\t' '$2 == "in_flight" {print "  in_flight  " $1}'
    printf '%s' "$cards" | awk -F'\t' '$2 == "pending" {print "  pending    " $1}' | head -5
    if (( pending_count == 0 && in_flight_count == 0 )); then
      printf '  queue empty: 0 pending, 0 in flight\n'
    fi
    # Cards on disk the controller has never been given. Not queue depth, and
    # deliberately not spelled the same way as a queued-and-waiting stage.
    if (( unqueued_count > 0 )); then
      printf '  %s card(s) on disk never queued (autometta add-stage to queue one):\n' \
        "$unqueued_count"
      printf '%s' "$cards" | awk -F'\t' '$2 == "unqueued" {print "  unqueued   " $1}' | head -3
      if (( unqueued_count > 3 )); then
        printf '  unqueued   ... and %s more\n' "$(( unqueued_count - 3 ))"
      fi
    fi
  else
    # Last-resort fallback: read state.yaml directly so the pane is
    # never blank just because list-cards.sh is unreachable.
    if [[ -f "$repo_root/state/state.yaml" ]] && command -v yq >/dev/null 2>&1; then
      yq -o=json '.' "$repo_root/state/state.yaml" 2>/dev/null \
        | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
stages=d.get("stages") or []
shown=0
for s in stages:
    if s.get("status") in ("pending","in_progress") and shown<6:
        print("  %-11s %s" % (s.get("status","?"), s.get("id","?")))
        shown+=1
if shown==0: print("  (no pending or in-progress stages in state.yaml)")
'
    else
      printf '  (list-cards.sh unreachable and state.yaml not parseable — restart this pane with `autometta attach %s`)\n' "$(basename "$repo_root")"
    fi
  fi
}

render_once() {
  local width height raw
  width="${AUTOMETTA_TICKER_COLUMNS:-${COLUMNS:-$(tput cols 2>/dev/null || printf 80)}}"
  height="${AUTOMETTA_TICKER_ROWS:-${LINES:-$(tput lines 2>/dev/null || printf 24)}}"
  raw="$(render_full)"
  AUTOMETTA_TICKER_FRAME="$raw" python3 - "$width" "$height" "$refresh_interval" <<'PY'
import os, re, sys
width, height, interval = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
raw = os.environ.get("AUTOMETTA_TICKER_FRAME", "").splitlines()
names = ("ALERTS", "ACTIVE", "LIVE", "SPEND", "RECENT", "SCHEDULED")
panels = {n: [] for n in names}
current = None
header = raw[0] if raw else "autometta unknown agent ticker"
health = []
for line in raw[1:]:
    if line.startswith("Health:"):
        current = None
        if not line.endswith("(ok)"): health.append(line)
        continue
    if not line.strip() or line.startswith("Repo:"):
        current = None
        continue
    found = next((n for n in names if line.startswith(n)), None)
    if found:
        current = found
        if not panels[found]:
            panels[found].append(line)
    elif current:
        if line.strip(): panels[current].append(line)

ansi = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
def fit(s):
    plain = ansi.sub("", s)
    return plain if len(plain) <= width else plain[:max(0, width - 1)] + ">"

alerts = panels["ALERTS"] or ["ALERTS  none"]
if health:
    alerts += ["  " + h for h in health]
active = panels["ACTIVE"] or ["ACTIVE", "  (none)"]
if panels["LIVE"]:
    active += ["  LIVE: %d line(s) hidden" % max(1, len(panels["LIVE"]) - 1)]

def bounded(lines, cap, label):
    if len(lines) <= cap:
        return lines
    hidden = len(lines) - max(0, cap - 1)
    if cap == 1:
        return ["%s: %d line(s) hidden" % (label, len(lines))]
    return lines[:cap - 1] + ["  > %d more %s line(s) hidden" % (hidden, label)]

body = []
roomy = height >= 20
body += bounded(alerts, 4, "ALERTS")
body += bounded(active, max(3, height - 14), "ACTIVE")
body += bounded(panels["SPEND"] or ["SPEND unavailable"], 8 if roomy else 4, "SPEND")
body += bounded(panels["RECENT"] or ["RECENT: 0 entries"], 2 if roomy else 1, "RECENT")
body += bounded(panels["SCHEDULED"] or ["SCHEDULED: 0 entries"], 2 if roomy else 1, "SCHEDULED")
footer = "Refresh: %ss  Ctrl+C to quit" % interval
available = max(0, height - 2)
if len(body) > available:
    hidden = len(body) - max(0, available - 1)
    body = body[:max(0, available - 1)] + ["PANELS: %d fitted line(s) hidden" % hidden]
lines = [header] + body
lines += [""] * max(0, height - len(lines) - 1)
lines.append(footer)
sys.stdout.write("\n".join(fit(line) for line in lines[:height]))
PY
}

if "$once"; then
  refresh_build_status
  render_once
  exit 0
fi

trap 'exit 0' INT TERM

printf '\033[?25l\033[2J'
trap 'printf "\033[?25h\n"; exit 0' INT TERM EXIT
while true; do
  refresh_build_status
  frame="$(render_once)"
  printf '\033[H%s\033[J' "$frame"
  sleep "$refresh_interval"
done
