#!/usr/bin/env bash
# Offline proof for stage card 150: the table ticks while it burns.
#
# The payload is shaped like the emergence-lab --repo seam on 2026-10-11: a
# live CLI agent carries stage_tokens and a burn series but no live_usage,
# and an in-flight stage's settled figures come only from spend.by_stage.
# The web dashboard's stage cells and the TUI's run, agents and detail panes
# are each driven directly. No auth, no network, no token spend.
#
# Re-frozen 2026-11-12 with the operator's approval: the web half had come to
# test stageTokenCells, which nothing drew once the table moved to uncached
# role cells. It now drives the cells renderStagesTable draws, in the
# uncached measure those cells show. The TUI half is unchanged.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

now_epoch="$(date -u +%s)"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/150-the-table-ticks-while-it-burns.md
# 1. Web: an in-flight stage's drawn role and total cells add the live
#    uncached figure to whatever has settled, marked live; settled stages are
#    as before, an SDK reading wins, and an agent with no reading marks nothing.
command -v node >/dev/null 2>&1 || fail "150: node is required for the dashboard assertions"
node --check "$repo_root/dashboard/dashboard.js" || fail "150: dashboard.js does not parse"
AUTOMETTA_DASHBOARD_JS="$repo_root/dashboard/dashboard.js" NOW="$now_epoch" node <<'NODE' || fail "150: the stages table does not tick"
const fs = require("fs");
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS, "utf8");
const defs = source.match(/\n  function \w+\([^)]*\) \{[\s\S]*?\n  \}(?=\n)/g) || [];
for (const signature of ["stageRoleCell(repo, stage, role)", "stageUsageTotal(repo, stage)"]) {
  if (!defs.some((d) => d.startsWith("\n  function " + signature + " {"))) {
    console.error("150: dashboard.js defines no top-level " + signature);
    process.exit(1);
  }
}
const api = new Function("state", "charts", "document", "window",
  defs.join("\n") + "\nreturn { stageRoleCell: stageRoleCell, stageUsageTotal: stageUsageTotal };")({}, {}, {}, {});
const html = (c) => (c && typeof c === "object" && c.html != null) ? String(c.html) : String(c == null ? "" : c);
const isLive = (c) => /class="[^"]*\blive\b[^"]*"/.test(html(c));
const problems = [];
const cellsOf = (repo, stage) =>
  [api.stageRoleCell(repo, stage, "worker"), api.stageRoleCell(repo, stage, "verifier"), api.stageUsageTotal(repo, stage)];

const working = { id: "03-working", status: "in_progress", tokens: 0, worker_tokens: null, verifier_tokens: null };
const workerRepo = { name: "lab", spend: { by_stage: [], failures: [], role_usage: [] }, stages: [working],
  agents: [{ stage_id: "03-working", role: "worker", stage_tokens: 8151781, stage_tokens_status: "counted", live_usage: null,
             live_total_tokens: 8151781, live_uncached_tokens: 151781, live_uncached_input_tokens: 120000 }] };
let [w, v, t] = cellsOf(workerRepo, working);
if (w.sort !== 151781 || !isLive(w) || !/151,781 uncached tokens/.test(html(w)))
  problems.push("a live worker's cell should count 151,781 uncached marked live, got " + w.sort);
if (isLive(v)) problems.push("the idle verifier cell must not be marked live");
if (t.sort !== 151781 || !isLive(t)) problems.push("the total should include the live worker figure, marked live, got " + t.sort);

const verifying = { id: "02-verifying", status: "in_progress", tokens: 0, worker_tokens: null, verifier_tokens: null };
const done = { id: "01-done", status: "completed", tokens: 20715099, worker_tokens: 17619762, verifier_tokens: 3095337 };
const verifierRepo = { name: "lab", spend: { by_stage: [], failures: [], role_usage: [
    { stage_id: "02-verifying", role: "worker", input_tokens: 2000000, cached_input_tokens: 15000000, output_tokens: 477447 },
    { stage_id: "01-done", role: "worker", input_tokens: 600000, cached_input_tokens: 17000000, output_tokens: 19762 },
    { stage_id: "01-done", role: "verifier", input_tokens: 90000, cached_input_tokens: 3000000, output_tokens: 5337 }] },
  stages: [done, verifying],
  agents: [{ stage_id: "02-verifying", role: "verifier", stage_tokens: 2500000, stage_tokens_status: "counted", live_usage: null,
             live_total_tokens: 2500000, live_uncached_tokens: 500000, live_uncached_input_tokens: 450000 }] };
[w, v, t] = cellsOf(verifierRepo, verifying);
if (v.sort !== 500000 || !isLive(v)) problems.push("a live verifier's cell should count 500,000 marked live, got " + v.sort);
if (w.sort !== 2477447 || isLive(w)) problems.push("the finished worker's cell should keep its settled 2,477,447 unmarked, got " + w.sort);
if (t.sort !== 2977447 || !isLive(t)) problems.push("the total should be settled 2,477,447 plus live 500,000, got " + t.sort);

[w, v, t] = cellsOf(verifierRepo, done);
if (w.sort !== 619762 || v.sort !== 95337 || t.sort !== 715099)
  problems.push("a completed stage must keep its recorded figures, got " + [w.sort, v.sort, t.sort].join(" / "));
if ([w, v, t].some(isLive)) problems.push("a completed stage must carry no live mark");

const sdkRepo = { name: "lab", spend: { by_stage: [], failures: [], role_usage: [] }, stages: [working],
  agents: [{ stage_id: "03-working", role: "worker", stage_tokens: 99, stage_tokens_status: "counted",
             live_total_tokens: 5000, live_uncached_tokens: 400, live_uncached_input_tokens: 300,
             live_usage: { input_tokens: 1000, output_tokens: 234, updated_at: "2026-10-11T12:00:00Z" } }] };
[w, v, t] = cellsOf(sdkRepo, working);
if (w.sort !== 1234 || !isLive(w)) problems.push("an SDK reading should win over the heartbeat and transcript, got " + w.sort);

const waitingRepo = { name: "lab", spend: { by_stage: [], failures: [], role_usage: [] }, stages: [working],
  agents: [{ stage_id: "03-working", role: "worker", stage_tokens: null, stage_tokens_status: "waiting", live_usage: null }] };
[w, v, t] = cellsOf(waitingRepo, working);
if ([w, v, t].some(isLive)) problems.push("an agent with no reading yet must not be marked live");
if (w.sort !== 0) problems.push("an agent with no reading yet must add nothing, got " + w.sort);

if (!/function renderStagesTable\(repos\) \{[\s\S]*?stageRoleCell\([\s\S]*?stageUsageTotal\(/.test(source))
  problems.push("renderStagesTable does not draw stageRoleCell and stageUsageTotal");
if (problems.length) { console.error("150: " + problems.join("; ")); process.exit(1); }
NODE
# 2. TUI: the run row totals settled plus live, the agents row shows the
#    transcript figure rather than n/a, and the detail pane's live line and
#    burn line read the transcript and its series.
python3 - "$script_dir/lib/tui/render.py" "$now_epoch" <<'PY' || fail "150: the TUI does not tick"
import importlib.util, re, sys

spec = importlib.util.spec_from_file_location("autometta_tui_render", sys.argv[1])
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)
now = int(sys.argv[2])
opus = "Claude Opus 5.5 <claude-opus-5-5@local>"
sol = "GPT-5.6 Sol <gpt-5-6-sol@local>"
payload = {
    "_now": now,
    "name": "lab",
    "current_stage": "02-verifying",
    "agents": [
        {"pid": 1, "stage_id": "02-verifying", "role": "verifier", "family": "claude",
         "identity": opus, "elapsed_seconds": 600, "budget_seconds": 1500,
         "started_at": None, "live_total_tokens": 2500000, "stage_tokens": 2500000,
         "stage_tokens_status": "counted", "live_usage": None, "activity": None,
         "burn": {"bucket_seconds": 60, "points": [
             {"t": now - 600, "tokens": 400000, "cached": 300000, "turns": 4},
             {"t": now - 300, "tokens": 1000000, "cached": 800000, "turns": 9},
             {"t": now, "tokens": 2500000, "cached": 2000000, "turns": 20}]}},
    ],
    "spend": {"by_stage": [{"stage_id": "02-verifying", "tokens": 2477447},
                           {"stage_id": "01-done", "tokens": 20715099}]},
    "stages": [{"id": "01-done", "status": "completed", "tokens": 20715099},
               {"id": "02-verifying", "status": "in_progress", "tokens": 0}],
    "current_run": {
        "id": "run-smoke", "started_at": "2026-10-11T12:00:00Z",
        "stages": [
            {"id": "01-done", "status": "completed", "worker": opus, "verifier": sol,
             "started_at": "2026-10-11T12:00:00Z"},
            {"id": "02-verifying", "status": "in_progress", "worker": sol, "verifier": opus,
             "started_at": "2026-10-11T12:30:00Z"},
        ],
    },
}
state = render.TuiState(5.0)
state.update(payload, observed_at=0.0)
state.observe_time(0.0)
frame = render.render(state, 180, 50).text()
lines = frame.splitlines()
problems = []
total = render.tick_tokens(2477447 + 2500000)
live = render.tick_tokens(2500000)
rate = render.short_tokens(300000) + "/min"
run_rows = [l for l in lines if "02-verifying" in l and re.search(r"\S→\S", l)]
if not run_rows or total not in run_rows[0]:
    problems.append("the run row should total settled plus live as %s: %r" % (total, run_rows[:1]))
done_rows = [l for l in lines if "01-done" in l and re.search(r"\S→\S", l)]
if not done_rows or render.tick_tokens(20715099) not in done_rows[0]:
    problems.append("the finished stage's run row lost its settled total")
agent_rows = [l for l in lines if "● 02-verifying" in l]
if not agent_rows or live not in agent_rows[0] or "n/a" in agent_rows[0]:
    problems.append("the agents row should show %s from the transcript, not n/a: %r" % (live, agent_rows[:1]))
live_rows = [l for l in lines if re.search(r"│ live {6}\S", l)]
if not live_rows or live not in live_rows[0] or "transcript" not in live_rows[0]:
    problems.append("the detail live line should read %s transcript: %r" % (live, live_rows[:1]))
if "burn this run" not in frame or rate not in frame:
    problems.append("the detail burn line should read 'burn this run' at %s from the series" % rate)
if "burn last 8 polls" in frame:
    problems.append("an agent with a burn series still shows the poll-history burn line")

sdk = dict(payload, agents=[dict(payload["agents"][0], burn=None,
           live_usage={"input_tokens": 1000, "output_tokens": 234, "updated_at": "2026-10-11T12:00:00Z"})])
state = render.TuiState(5.0)
state.update(sdk, observed_at=0.0)
state.observe_time(0.0)
sdk_frame = render.render(state, 180, 50).text()
if "LIVE" not in sdk_frame:
    problems.append("an SDK figure lost its LIVE label")
if "burn last 8 polls" not in sdk_frame:
    problems.append("without a burn series the detail pane should keep its poll-history line")
if problems:
    sys.stderr.write("150: " + "; ".join(problems) + "\n")
    sys.exit(1)
PY
# AUTOMETTA-CONTRACT-END

printf 'live-stage-tokens-smoke: PASS\n'
