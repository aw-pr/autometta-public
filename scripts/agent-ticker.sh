#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# agent-ticker.sh: render a compact ACTIVE / RECENT / SCHEDULED view of
# dispatched agents and stage cards, suitable for the third tmux pane.
#
# Args:
#   <repo_root> [--once]
#
# Without --once, loops forever refreshing every $PHAT_CONTROLLER_TICKER_INTERVAL
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
refresh_interval="${PHAT_CONTROLLER_TICKER_INTERVAL:-5}"

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
  local controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
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

render_once() {
  local active_dir="$repo_root/state/active-agents"
  local recent_dir="$repo_root/state/recent-agents"
  local heartbeat_path="$repo_root/state/heartbeat.json"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf 'Autometta agent ticker — %s\n' "$now_iso"
  printf 'Repo: %s\n' "$repo_root"
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
  python3 - "$state_path" "$budget_path" "$repo_root" "$pending_count" "$in_flight_count" "$enabled" <<'PY' || true
import json, os, sys
state_path, budget_path, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]
pending_count, in_flight_count, enabled = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
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
            if current_id and current_status in ("failed", "verifier_failed", "stalled"):
                blocked.append((current_id, current_status))
            current_id = stripped.split(":", 1)[1].strip()
            current_status = None
        elif stripped.startswith("status:") and current_id:
            current_status = stripped.split(":", 1)[1].strip()
    if current_id and current_status in ("failed", "verifier_failed", "stalled"):
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

  printf 'ACTIVE\n'
  if [[ -f "$heartbeat_path" ]]; then
    python3 - "$heartbeat_path" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        rep = json.load(fh)
except Exception:
    print("  (heartbeat.json unreadable)")
    sys.exit(0)
entries = rep.get("entries", [])
if not entries:
    print("  (none)")
else:
    for e in entries:
        flags = ",".join(e.get("flags", [])) or "fresh"
        print("  %-7s %-9s %-30s pid %-6s %5ss  log:%sB  %s" % (
            e.get("family", "?"),
            e.get("role", "?"),
            (e.get("card_path","")[-30:] or "-").lstrip("/"),
            e.get("pid", "?"),
            e.get("elapsed_seconds", "?"),
            e.get("log_size", "?"),
            flags,
        ))
PY
  else
    printf '  (no heartbeat yet — run scripts/heartbeat.sh %s)\n' "$repo_root"
  fi
  printf '\n'

  printf 'RECENT (last 5)\n'
  if [[ -d "$recent_dir" ]]; then
    python3 - "$recent_dir" <<'PY' || true
import json, os, sys
from datetime import datetime, timezone
d = sys.argv[1]
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
files = []
try:
    for n in os.listdir(d):
        if n.endswith(".json"):
            p = os.path.join(d, n)
            files.append((os.path.getmtime(p), p))
except FileNotFoundError:
    pass
files.sort(reverse=True)
if not files:
    print("  (none)")
else:
    RED, RESET = "\033[31m", "\033[0m"
    FAIL_OUTCOMES = {"fail", "failed", "verifier_failed", "stalled", "error", "stuck"}
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
    printf '  (none)\n'
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

if "$once"; then
  render_once
  exit 0
fi

trap 'exit 0' INT TERM

while true; do
  clear
  render_once
  sleep "$refresh_interval"
done
