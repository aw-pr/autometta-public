#!/usr/bin/env bash
# Offline proof for stage card 151: the run totals tick above the table.
#
# The repo object is shaped like the emergence-lab --repo seam on 2026-10-11:
# a current_run whose tokens_total holds what has settled (a finished stage
# and a finished worker) while the verifier is still running and visible only
# as a live agent. The dashboard's run-totals strip is driven directly. No
# auth, no network, no token spend.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/151-the-run-totals-tick-above-the-table.md
# 1. The page has a place for the strip, in the Per stage section above the
#    table.
python3 - "$repo_root/dashboard/index.html" <<'PY' || fail "151: index.html has no run-totals strip above the stages table"
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
heading = page.find("<h2>Per stage</h2>")
strip = page.find('id="run-totals"')
table = page.find('id="stages-table-wrap"')
sys.exit(0 if 0 <= heading < strip < table else 1)
PY
# 2. The strip reads settled run totals plus every live figure in the run,
#    marks itself live while anything is running, and is absent without a run.
command -v node >/dev/null 2>&1 || fail "151: node is required for the dashboard assertions"
node --check "$repo_root/dashboard/dashboard.js" || fail "151: dashboard.js does not parse"
AUTOMETTA_DASHBOARD_JS="$repo_root/dashboard/dashboard.js" node <<'NODE' || fail "151: the run totals strip is wrong"
const fs = require("fs");
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS, "utf8");
const defs = source.match(/\n  function \w+\([^)]*\) \{[\s\S]*?\n  \}(?=\n)/g) || [];
if (!defs.some((d) => /\n  function runTotals\(repo\) \{/.test(d))) {
  console.error("151: dashboard.js defines no top-level runTotals(repo)");
  process.exit(1);
}
const api = new Function("state", "charts", "document", "window",
  defs.join("\n") + "\nreturn { runTotals: runTotals };")({}, {}, {}, {});
const html = (c) => (c && typeof c === "object" && c.html != null) ? String(c.html) : String(c == null ? "" : c);
const text = (c) => html(c).replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
const isLive = (c) => /class="[^"]*\blive\b[^"]*"/.test(html(c));
const problems = [];

const run = {
  id: "run-20261011-121812", started_at: "2026-10-11T12:18:12Z",
  tokens_total: 30329034, cost_usd_est: 16.637064,
  stages: [
    { id: "123b-orbit-render-cues", status: "completed", tokens: 20715099 },
    { id: "116-logistic-mandelbrot-window-build", status: "in_progress", phase: "verifying", tokens: 9613935 }
  ]
};
const verifierLive = { name: "emergence-lab", current_run: run,
  agents: [{ stage_id: "116-logistic-mandelbrot-window-build", role: "verifier",
             stage_tokens: 2000000, stage_tokens_status: "counted", live_usage: null }] };
const live = api.runTotals(verifierLive);
if (!/32,329,034/.test(text(live))) problems.push("settled 30,329,034 plus live 2,000,000 should read 32,329,034: '" + text(live) + "'");
if (!isLive(live)) problems.push("a run with a live agent should carry class=\"live\"");
if (!/\$16\.64/.test(text(live))) problems.push("the settled cost should read $16.64");
if (!/1 of 2/.test(text(live))) problems.push("the strip should count 1 of 2 stages done");
if (!/run-20261011-121812/.test(text(live))) problems.push("the strip should name the run");

const elsewhere = Object.assign({}, verifierLive, {
  agents: [{ stage_id: "99-another-run", role: "worker", stage_tokens: 5000000, stage_tokens_status: "counted", live_usage: null }] });
if (!/30,329,034/.test(text(api.runTotals(elsewhere))))
  problems.push("a live agent on a stage outside the run must not be added");

const sdk = Object.assign({}, verifierLive, {
  agents: [{ stage_id: "116-logistic-mandelbrot-window-build", role: "verifier", stage_tokens: 99,
             stage_tokens_status: "counted", live_usage: { input_tokens: 1000, output_tokens: 234, updated_at: "2026-10-11T13:00:00Z" } }] });
if (!/30,330,268/.test(text(api.runTotals(sdk)))) problems.push("an SDK figure should win over the transcript total");

const idle = Object.assign({}, verifierLive, { agents: [] });
const idleCell = api.runTotals(idle);
if (!/30,329,034/.test(text(idleCell)) || isLive(idleCell)) problems.push("an idle run shows its settled total with no live mark");

const waiting = Object.assign({}, verifierLive, {
  agents: [{ stage_id: "116-logistic-mandelbrot-window-build", role: "verifier", stage_tokens: null, stage_tokens_status: "waiting", live_usage: null }] });
if (!/30,329,034/.test(text(api.runTotals(waiting)))) problems.push("an agent with no figure yet adds nothing");

if (text(api.runTotals({ name: "x", current_run: null, agents: [] })) !== "")
  problems.push("a repo with no current run renders nothing");

const callers = defs.filter((d) => !/\n  function runTotals\(/.test(d) && /\brunTotals\(/.test(d));
if (!callers.length) problems.push("nothing on the render path calls runTotals");
if (!/getElementById\("run-totals"\)/.test(source)) problems.push("nothing writes into #run-totals");
if (problems.length) { console.error("151: " + problems.join("; ")); process.exit(1); }
NODE
# AUTOMETTA-CONTRACT-END

printf 'run-totals-smoke: PASS\n'
