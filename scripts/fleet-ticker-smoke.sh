#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# fleet-ticker-smoke.sh: card 66's contract test and acceptance criteria,
# offline. Fixture: eight subscribers -- one halted on token-cap, one
# stalled on a stage, one over its consecutive-failure cap (the trio
# criterion 3 names by name), one paused, two holding a stale vendor
# contract, one carrying a long stage id and a full agent identity to prove
# no truncation at 119, and one plain healthy repo -- rendered fleet-wide
# and then repo-scoped to the halted subscriber, at 80, 119 and 160 columns.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture="$(mktemp -d)"
cleanup() {
  case "$fixture" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$fixture" ;; esac
}
trap cleanup EXIT

fail_count=0
check() {
  local label="$1" got="$2" want="ok"
  if [[ "$got" == "$want" ]]; then
    printf '  PASS: %s\n' "$label"
  else
    printf '  FAIL: %s (got %q)\n' "$label" "$got"
    fail_count=$(( fail_count + 1 ))
  fi
}

# Shared column-parsing helper for the criterion-4 and criterion-9 checks:
# it finds a named table's block in a captured frame, locates each column's
# (line, offset) from the header itself (never a guessed constant), and
# either reads one row's cell at a named column (mode "cell") or asserts
# every row starts each column at the same offset the header does (mode
# "align"). Scoping to the actual column beats grepping the whole frame --
# the id also appears in a REPOS row's free-text state ("running <id>"),
# which made an earlier whole-frame grep a false positive.
#
# The renderer wraps a row across more than one physical line when its
# identifying columns alone outgrow the frame (re-brief attempt 3's
# drop-then-wrap rule) rather than truncating any of them, so "one row is
# one line" no longer holds. A continuation line is always indented four
# columns past the frame's own two-column left margin -- six leading
# spaces where a primary line has two -- and that indent is the same for
# every logical row in a table (column widths are fixed per table, so
# every row wraps at the same point the header does). Header stride is
# read from that structural marker rather than guessed from which names
# turn up, so a column dropped for width (present in no line) never
# corrupts the count the way searching for it forever would.
read -r -d '' PROBE_PY <<'PY' || true
import os, sys

def table_lines(lines, name):
    try:
        start = lines.index(name) + 1
    except ValueError:
        raise RuntimeError("table-not-found:%s" % name)
    end = start
    while end < len(lines) and lines[end].strip():
        end += 1
    return lines[start:end]

def table_metadata(block):
    dropped = set()
    content = []
    for line in block:
        stripped = line.strip()
        if stripped.startswith("columns hidden:"):
            dropped.update(n.strip() for n in stripped.split(":", 1)[1].split(",") if n.strip())
        elif stripped.startswith("and ") and stripped.endswith("see failures-history"):
            continue
        else:
            content.append(line)
    return content, dropped

def leading_spaces(line):
    return len(line) - len(line.lstrip(" "))

def header_stride(block):
    stride = 1
    for line in block[1:]:
        if leading_spaces(line) >= 6:
            stride += 1
        else:
            break
    return stride

def locate(header_lines, names, recorded_drops):
    offsets = {}
    for li, line in enumerate(header_lines):
        pos = 0
        for n in names:
            if n in offsets:
                continue
            idx = line.find(n, pos)
            if idx != -1:
                offsets[n] = (li, idx)
                pos = idx + len(n)
    missing = set(names) - set(offsets)
    if missing != recorded_drops:
        return offsets, "missing:%s:recorded:%s" % (
            ",".join(sorted(missing)) or "-", ",".join(sorted(recorded_drops)) or "-")
    return offsets, None

def row_chunks(block, stride):
    body = block[stride:]
    return [body[i:i + stride] for i in range(0, len(body), stride)]

def cell(chunk, offsets, names, name):
    line_idx, start = offsets[name]
    row = chunk[line_idx] if line_idx < len(chunk) else ""
    end = len(row)
    for n2 in names:
        if n2 == name or n2 not in offsets:
            continue
        li2, idx2 = offsets[n2]
        if li2 == line_idx and idx2 > start and idx2 - 2 < end:
            end = idx2 - 2
    return row[start:end].rstrip()

def main():
    table = sys.argv[1]
    names = sys.argv[2].split(",")
    mode = sys.argv[3]
    lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
    try:
        block = table_lines(lines, table)
    except RuntimeError as exc:
        print(str(exc))
        return
    block, recorded_drops = table_metadata(block)
    stride = header_stride(block)
    offsets, locate_error = locate(block[:stride], names, recorded_drops)
    if locate_error:
        print(locate_error)
        return
    if not offsets:
        print("no-columns-found")
        return
    if len(block[stride:]) % stride:
        print("partial-row-group")
        return
    chunks = row_chunks(block, stride)

    if mode == "align":
        for chunk in chunks:
            if len(chunk) != stride:
                print("short-row-group:%r" % chunk)
                return
            for n, (li, idx) in offsets.items():
                if li >= len(chunk):
                    print("missing-line:%s:%r" % (n, chunk))
                    return
                row = chunk[li]
                if len(row) <= idx:
                    print("row-ended-before:%s:%d:%r" % (n, idx, row))
                    return
                if row[idx].isspace():
                    print("blank-at-offset:%s:%r" % (n, row))
                    return
                earlier = [p for _n, (line_no, p) in offsets.items() if line_no == li and p < idx]
                if earlier and row[max(0, idx - 2):idx] != "  ":
                    print("missing-separator:%s:%r" % (n, row))
                    return
        print("ok")
        return

    if mode == "cell":
        match, name, want = sys.argv[4], sys.argv[5], sys.argv[6]
        if name not in offsets:
            print("requested-column-dropped:%s" % name)
            return
        for chunk in chunks:
            if any(match in row for row in chunk):
                got = cell(chunk, offsets, names, name)
                print("ok" if got == want else "got:%r" % got)
                return
        print("row-not-found")
        return

    print("bad-mode")

main()
PY

# Prove the probe itself fails loudly on the three permissive cases called
# out in the attempt-4 re-brief. These are its own negative controls, not
# assertions about renderer output.
probe_missing_frame=$'REPOS\n  repo  state\n  alpha  idle'
probe_missing="$(AUTOMETTA_TEST_FRAME="$probe_missing_frame" python3 -c "$PROBE_PY" REPOS "repo,state,today" align)"
check "the alignment probe rejects an absent, unrecorded requested column" \
  "$([[ "$probe_missing" == missing:today:recorded:- ]] && printf ok || printf '%s' "$probe_missing")"
probe_short_frame=$'REPOS\n  repo  state\n  alpha'
probe_short="$(AUTOMETTA_TEST_FRAME="$probe_short_frame" python3 -c "$PROBE_PY" REPOS "repo,state" align)"
check "the alignment probe rejects a row ending before a column offset" \
  "$([[ "$probe_short" == row-ended-before:* ]] && printf ok || printf '%s' "$probe_short")"
probe_separator_frame=$'REPOS\n  repo  state\n  alphaXidle'
probe_separator="$(AUTOMETTA_TEST_FRAME="$probe_separator_frame" python3 -c "$PROBE_PY" REPOS "repo,state" align)"
check "the alignment probe rejects a non-space at the offset without its separator" \
  "$([[ "$probe_separator" == missing-separator:* ]] && printf ok || printf '%s' "$probe_separator")"

now_epoch="$(date -u +%s)"
iso_at() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now_iso="$(iso_at "$now_epoch")"

controller="$fixture/controller"
mkdir -p "$controller/subscribers" "$controller/dashboard"

make_repo() {
  local name="$1"
  mkdir -p "$fixture/$name/state/active-agents"
  printf 'repo_path: "%s"\nenabled: true\n' "$fixture/$name" > "$controller/subscribers/$name.yaml"
}

# 1. plain healthy repo.
make_repo agentic-rag-kimble
cat > "$fixture/agentic-rag-kimble/state/state.yaml" <<EOF
current_stage: null
stages: []
EOF
cat > "$fixture/agentic-rag-kimble/state/budget.json" <<'EOF'
{"tokens_spent":1000000,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
: > "$fixture/agentic-rag-kimble/state/cost-log.jsonl"

# 2. halted on token-cap -- first of the criterion-3 trio.
make_repo emergence-lab-alpha
cat > "$fixture/emergence-lab-alpha/state/state.yaml" <<EOF
current_stage: null
stages: []
EOF
cat > "$fixture/emergence-lab-alpha/state/budget.json" <<'EOF'
{"tokens_spent":8000000,"token_cap_total":8000000,"halted":true,"halt_reason":"token-cap","consecutive_failures":0,"consecutive_failure_cap":3}
EOF
: > "$fixture/emergence-lab-alpha/state/cost-log.jsonl"

# 3. a stage sitting in `stalled` -- second of the trio. Re-brief finding 1:
# an in-progress stage with an over-budget agent (fixture 6 below) is not
# the same state and must not be allowed to stand in for it.
stalled_id="41-a-stalled-example-stage"
make_repo boids-density
cat > "$fixture/boids-density/state/state.yaml" <<EOF
current_stage: $stalled_id
stages:
  - id: $stalled_id
    status: stalled
EOF
cat > "$fixture/boids-density/state/budget.json" <<'EOF'
{"tokens_spent":50000,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
: > "$fixture/boids-density/state/cost-log.jsonl"

# 4. over its consecutive-failure cap -- third of the trio. Distinct from
# "over-budget" (a single live agent past its wall-clock allowance): this is
# a repo whose failures have reached the cap that governs whether it may be
# dispatched again.
make_repo usage-limiter
cat > "$fixture/usage-limiter/state/state.yaml" <<EOF
current_stage: null
stages: []
EOF
cat > "$fixture/usage-limiter/state/budget.json" <<'EOF'
{"tokens_spent":150000,"token_cap_total":8000000,"halted":false,"consecutive_failures":3,"consecutive_failure_cap":3}
EOF
: > "$fixture/usage-limiter/state/cost-log.jsonl"

# 5. paused on a provider limit.
make_repo wind-watcher
cat > "$fixture/wind-watcher/state/state.yaml" <<EOF
current_stage: null
stages: []
EOF
cat > "$fixture/wind-watcher/state/budget.json" <<EOF
{"tokens_spent":200000,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3,"paused_until":$(( now_epoch + 3600 )),"paused_reason":"provider limit"}
EOF
: > "$fixture/wind-watcher/state/cost-log.jsonl"

# 6 and 7. two subscribers holding a stale vendor contract.
for name in research-sweeper fin-ops; do
  make_repo "$name"
  cat > "$fixture/$name/state/state.yaml" <<EOF
current_stage: null
stages: []
EOF
  cat > "$fixture/$name/state/budget.json" <<'EOF'
{"tokens_spent":300000,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
  : > "$fixture/$name/state/cost-log.jsonl"
  cat > "$fixture/$name/.autometta-vendor" <<'EOF'
# Autometta vendor stamp. Refresh with: autometta refresh-repo .
source_repo: autometta
vendored_from: 0000000
vendored_at: 2026-01-01
EOF
done

# 8. a stage id long enough to prove the id column is not capped at the old
# ~40-column guess, a full agent identity, and a live over-budget agent --
# proves no truncation at 119 (criterion 4) and that a healthy repo earns no
# ESCALATIONS row nobody would act on (deliverable 3). This is a real stage
# id length from this repo's own card names, kept full-length on purpose:
# re-brief attempt 3 named shrinking a fixture id to fit the assertion the
# exact habit run-lessons entry 15 forbids. At 119 columns it does not fit
# alongside repo, result, role and identity at their own natural widths --
# the row wraps (drop-then-wrap), it does not truncate.
long_stage_id="66-the-fleet-view-fits-its-pane-too-and-so-does-this-one"
make_repo fractals-from-the-90s
cat > "$fixture/fractals-from-the-90s/state/state.yaml" <<EOF
current_stage: $long_stage_id
last_tick_at: "$now_iso"
stages:
  - id: $long_stage_id
    status: in_progress
    started_at: "$now_iso"
EOF
cat > "$fixture/fractals-from-the-90s/state/budget.json" <<'EOF'
{"tokens_spent":10000,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
: > "$fixture/fractals-from-the-90s/state/cost-log.jsonl"
cat > "$fixture/fractals-from-the-90s/state/active-agents/$$.json" <<EOF
{"pid":$$,"family":"codex","role":"verifier","identity":"Codex GPT-5.6 Sol <gpt-5-6-sol@local>","stage_id":"$long_stage_id","card_path":"live.md","started_at":"$now_iso","budget_seconds":10,"working_dir":"$fixture/fractals-from-the-90s"}
EOF
cat > "$fixture/fractals-from-the-90s/state/heartbeat.json" <<EOF
{"checked_at":"$now_iso","entries":[{"pid":$$,"elapsed_seconds":9999,"flags":["over-budget"]}]}
EOF

export PHAT_CONTROLLER_HOME="$controller"
"$script_dir/aggregate-dashboard.sh" >/dev/null

# Locale and TERM pinned, as card 49 established and card 63's smoke pins
# them for scripts/repo-ticker.sh.
capture_fleet() {
  local width="$1"
  LC_ALL=en_GB.UTF-8 TERM=xterm-256color PHAT_CONTROLLER_HOME="$controller" AUTOMETTA_FLEET_ONCE=true \
    AUTOMETTA_FLEET_COLUMNS="$width" AUTOMETTA_FLEET_ROWS=200 "$script_dir/attach.sh" --fleet-ticker
}
capture_scoped() {
  local width="$1" repo="$2"
  LC_ALL=en_GB.UTF-8 TERM=xterm-256color PHAT_CONTROLLER_HOME="$controller" AUTOMETTA_FLEET_ONCE=true \
    AUTOMETTA_FLEET_COLUMNS="$width" AUTOMETTA_FLEET_ROWS=200 "$script_dir/attach.sh" --fleet-ticker "$repo"
}

fleet80="$(capture_fleet 80)"
fleet119="$(capture_fleet 119)"
fleet160="$(capture_fleet 160)"
escalations119="$(printf '%s\n' "$fleet119" | sed -n '/^ESCALATIONS/,$p')"

printf '== 1. fleet page fits at 80 and 119, no scrollback ==\n' >&2
check "80-col fleet frame has no line over 80 printable columns" \
  "$(AUTOMETTA_TEST_FRAME="$fleet80" python3 -c '
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
print("ok" if all(len(l) <= 80 for l in lines) else "overflow")')"
check "119-col fleet frame has no line over 119 printable columns" \
  "$(AUTOMETTA_TEST_FRAME="$fleet119" python3 -c '
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
print("ok" if all(len(l) <= 119 for l in lines) else "overflow")')"
check "80-col fleet frame fits the given height (no scrollback)" \
  "$([[ "$(printf '%s\n' "$fleet80" | wc -l | tr -d ' ')" -le 40 ]] && printf ok || printf 'too tall')"
check "119-col fleet frame fits the given height (no scrollback)" \
  "$([[ "$(printf '%s\n' "$fleet119" | wc -l | tr -d ' ')" -le 40 ]] && printf ok || printf 'too tall')"
check "the fleet renderer has no right-edge height slice" \
  "$([[ -z "$(grep -F 'lines[:height]' "$repo_root/scripts/lib/fleet-ticker-render.py" || true)" ]] && printf ok || printf 'height slice remains')"

printf '\n== 2. FAILURES left the live view; the failures-history command covers the fleet ==\n' >&2
check "the fleet frame carries no FAILURES section" \
  "$([[ "$fleet119" != *"FAILURES"* ]] && printf ok || printf 'FAILURES rendered live')"
fleet_history="$("$script_dir/failures-history.sh" --fleet)"
check "the fleet history command runs" \
  "$([[ -n "$fleet_history" ]] && printf ok || printf empty)"

printf '\n== 3. halted, stalled and over-cap (the named trio) are visible with their reasons ==\n' >&2
check "the halted repo and its reason are visible at 119" \
  "$([[ "$fleet119" == *"emergence-lab-alpha"*"HALTED: token-cap"* ]] && printf ok || printf 'missing')"
check "the halted repo and its reason are visible at 80 (no scrolling needed)" \
  "$([[ "$fleet80" == *"emergence-lab-alpha"* && "$fleet80" == *"token-cap"* ]] && printf ok || printf 'missing')"
check "the stalled repo and its stalled stage id are visible" \
  "$([[ "$fleet119" == *"boids-density"*"STALLED: $stalled_id"* ]] && printf ok || printf 'missing')"
check "the over-cap repo and its failure count are visible" \
  "$([[ "$escalations119" == *"usage-limiter"* && "$escalations119" == *"attempt-cap"* && "$escalations119" == *"3/3"* ]] && printf ok || printf 'missing')"
check "the paused repo and its reason are visible" \
  "$([[ "$fleet119" == *"wind-watcher"* && "$fleet119" == *"paused"* ]] && printf ok || printf 'missing')"
check "research-sweeper's stale vendor contract is visible" \
  "$([[ "$escalations119" == *"research-sweeper"* && "$escalations119" == *"vendor-stale"* ]] && printf ok || printf missing)"
check "fin-ops's stale vendor contract is visible" \
  "$([[ "$escalations119" == *"fin-ops"* && "$escalations119" == *"vendor-stale"* ]] && printf ok || printf missing)"
check "the over-budget agent's stage is visible as an escalation" \
  "$([[ "$fleet119" == *"over-budget"* ]] && printf ok || printf 'missing')"
check "a healthy idle repo earns no ESCALATIONS row" \
  "$([[ "$escalations119" != *"agentic-rag-kimble"* ]] && printf ok || printf 'idle repo row present')"

printf '\n== 4. no identifying or enumeration column is truncated at 119 ==\n' >&2
check "the ESCALATIONS stage column holds the long id whole, not the whole-frame grep a REPOS free-text match would pass on" \
  "$(AUTOMETTA_TEST_FRAME="$fleet119" python3 -c "$PROBE_PY" ESCALATIONS "repo,result,stage,role,identity" cell fractals-from-the-90s stage "$long_stage_id")"
check "the ESCALATIONS role column holds 'verifier' whole" \
  "$(AUTOMETTA_TEST_FRAME="$fleet119" python3 -c "$PROBE_PY" ESCALATIONS "repo,result,stage,role,identity" cell fractals-from-the-90s role verifier)"
check "the ESCALATIONS result column holds 'over-budget' whole" \
  "$(AUTOMETTA_TEST_FRAME="$fleet119" python3 -c "$PROBE_PY" ESCALATIONS "repo,result,stage,role,identity" cell fractals-from-the-90s result over-budget)"
check "the ESCALATIONS identity column holds the full agent identity whole" \
  "$(AUTOMETTA_TEST_FRAME="$fleet119" python3 -c "$PROBE_PY" ESCALATIONS "repo,result,stage,role,identity" cell fractals-from-the-90s identity "Codex GPT-5.6 Sol")"
check "the ESCALATIONS repo column holds the repo name whole" \
  "$(AUTOMETTA_TEST_FRAME="$fleet119" python3 -c "$PROBE_PY" ESCALATIONS "repo,result,stage,role,identity" cell fractals-from-the-90s repo fractals-from-the-90s)"
check "no repo name in REPOS is truncated with an ellipsis at 119" \
  "$([[ "$(printf '%s\n' "$fleet119" | sed -n '/^REPOS/,/^$/p')" != *'…'* ]] && printf ok || printf 'ellipsis present')"

printf '\n== 5. allocation differs at 80, 119 and 160 ==\n' >&2
check "80 and 119 column captures differ" "$([[ "$fleet80" != "$fleet119" ]] && printf ok || printf identical)"
check "119 and 160 column captures differ" "$([[ "$fleet119" != "$fleet160" ]] && printf ok || printf identical)"

printf '\n== 6. the renderer recomputes no aggregate ==\n' >&2
check "fleet-ticker-render.py opens no file of its own" \
  "$([[ "$(grep -c 'open(' "$repo_root/scripts/lib/fleet-ticker-render.py" || true)" == 0 ]] && printf ok || printf 'opens a file')"
check "attach.sh never reads a subscriber's state.yaml, budget.json or cost-log.jsonl directly" \
  "$([[ -z "$(grep -v '^\s*#' "$repo_root/scripts/attach.sh" | grep -E 'state\.yaml|budget\.json|cost-log\.jsonl' || true)" ]] && printf ok || printf 'reads a file directly')"
# A file-open check alone would miss a recomputed count or sum -- feed the
# renderer a payload where a repo's queue array (length 5) and its
# aggregate-emitted queue_depth (2) deliberately disagree, direct enough
# that aggregate-dashboard.sh's own queue_depth arithmetic is never in the
# loop, and require the rendered figure to be the aggregate's, not a
# recount of the array.
recompute_payload='{"generated_at":"'"$now_iso"'","fleet_totals":{"enabled_repos":1,"today_tokens":0,"today_cost_usd_est":0,"window_tokens_spent":0,"window_token_cap_total":0},"spend":{"tokens_total":0,"cost_usd_est":0},"repos":[{"name":"queue-depth-check","enabled":true,"halted":false,"tokens_spent":0,"effective_token_cap":8000000,"queue":[{"stage_id":"a"},{"stage_id":"b"},{"stage_id":"c"},{"stage_id":"d"},{"stage_id":"e"}],"queue_depth":2,"spend":{"tokens_total":0},"stages":[],"agents":[]}]}'
recompute_frame="$(AUTOMETTA_FLEET_PAYLOAD="$recompute_payload" AUTOMETTA_BUILD_SHA=test python3 "$repo_root/scripts/lib/fleet-ticker-render.py" fleet fleet 160 40 600)"
check "REPOS shows the aggregate's queue_depth (2), not a recount of queue (5)" \
  "$(AUTOMETTA_TEST_FRAME="$recompute_frame" python3 -c "$PROBE_PY" REPOS "repo,state,today,q,window" cell queue-depth-check q 2)"

printf '\n== 7. the tall capture cannot hide an overflow behind clipping ==\n' >&2
check "the smoke asks for 200 rows but the bounded 80-column page is naturally at most 40" \
  "$([[ "$(printf '%s\n' "$fleet80" | wc -l | tr -d ' ')" -le 40 ]] && printf ok || printf 'natural overflow')"

printf '\n== 8/9. window 0 is repo-scoped: no REPOS table, columns whole and aligned ==\n' >&2
scoped80="$(capture_scoped 80 "$fixture/emergence-lab-alpha")"
scoped119="$(capture_scoped 119 "$fixture/emergence-lab-alpha")"
scoped160="$(capture_scoped 160 "$fixture/emergence-lab-alpha")"
check "the repo-scoped page carries no REPOS table" \
  "$([[ "$scoped119" != *"REPOS"* ]] && printf ok || printf 'REPOS present')"
check "the repo-scoped page shows the halt and its reason" \
  "$([[ "$scoped119" == *"halted"* && "$scoped119" == *"token-cap"* ]] && printf ok || printf missing)"
check "the repo-scoped page fits at 80 columns" \
  "$(AUTOMETTA_TEST_FRAME="$scoped80" python3 -c '
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
print("ok" if all(len(l) <= 80 for l in lines) else "overflow")')"
check "the repo-scoped page fits at 119 columns" \
  "$(AUTOMETTA_TEST_FRAME="$scoped119" python3 -c '
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
print("ok" if all(len(l) <= 119 for l in lines) else "overflow")')"
selfhost_dir="$fixture/autometta"
mkdir -p "$selfhost_dir"
dry_run_plan="$(PHAT_CONTROLLER_HOME="$controller" "$script_dir/attach.sh" --dry-run "$selfhost_dir")"
check "the fleet-wide page is still reachable (a distinct tmux window in the dry-run plan)" \
  "$([[ "$dry_run_plan" == *'third window: fleet'* ]] && printf ok || printf 'not reachable')"
check "window 0 of that plan is the repo-scoped page, not the fleet-wide one" \
  "$([[ "$dry_run_plan" == *'default window: repo'* ]] && printf ok || printf 'wrong landing window')"

printf '\n== column edges align: every column starts at the same offset from header to every body row ==\n' >&2
for width_var in fleet80:80 fleet119:119 fleet160:160; do
  frame_name="${width_var%%:*}"
  width="${width_var##*:}"
  frame="${!frame_name}"
  check "REPOS columns align at $width columns" \
    "$(AUTOMETTA_TEST_FRAME="$frame" python3 -c "$PROBE_PY" REPOS "repo,state,today,q,window" align)"
  check "ESCALATIONS columns align at $width columns (fleet page)" \
    "$(AUTOMETTA_TEST_FRAME="$frame" python3 -c "$PROBE_PY" ESCALATIONS "repo,result,stage,role,identity" align)"
done
for width_var in scoped80:80 scoped119:119 scoped160:160; do
  frame_name="${width_var%%:*}"
  width="${width_var##*:}"
  frame="${!frame_name}"
  check "ESCALATIONS columns align at $width columns (repo-scoped page)" \
    "$(AUTOMETTA_TEST_FRAME="$frame" python3 -c "$PROBE_PY" ESCALATIONS "result,stage,role,identity" align)"
done

if (( fail_count > 0 )); then
  printf '\nFAIL fleet ticker smoke: %d assertion(s) failed\n' "$fail_count"
  exit 1
fi
printf '\nPASS fleet ticker: fits its pane, no FAILURES table, escalations visible, no truncation, allocation, one-JSON-source, repo-scoped window 0, column alignment\n'
