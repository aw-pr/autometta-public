#!/usr/bin/env bash
# The fleet page never reads transcripts, so a running agent there carries
# only the heartbeat's live_total_tokens. The stage cells, the run totals and
# the agents table must still tick on that figure rather than read zero or
# n/a. No auth, no network, no token spend.
#
# AUTOMETTA-CONTRACT-NONE reason=regression smoke for the fleet-view live token fallback
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || fail "node is required for the dashboard assertions"
AUTOMETTA_DASHBOARD_JS="$repo_root/dashboard/dashboard.js" node <<'NODE' || fail "the fleet view does not tick on the heartbeat figure"
const fs = require("fs");
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS, "utf8");
const defs = source.match(/\n  function \w+\([^)]*\) \{[\s\S]*?\n  \}(?=\n)/g) || [];
const api = new Function("state", "charts", "document", "window",
  defs.join("\n") + "\nreturn { stageTokenCells: stageTokenCells, burnCell: burnCell };")({}, {}, {}, {});
const html = (c) => (c && typeof c === "object" && c.html != null) ? String(c.html) : String(c == null ? "" : c);
const text = (c) => html(c).replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
const isLive = (c) => /class="[^"]*\blive\b[^"]*"/.test(html(c));
const problems = [];

const working = { id: "19-working", status: "in_progress", tokens: 0, worker_tokens: null, verifier_tokens: null };
const fleetAgent = { stage_id: "19-working", role: "worker", stage_tokens: null, stage_tokens_status: null,
  live_usage: null, live_total_tokens: 10612018 };
const repo = { name: "promo-flow", spend: { by_stage: [], failures: [] }, stages: [working], agents: [fleetAgent] };
const [w, v, t] = api.stageTokenCells(repo, working);
if (!/10,612,018/.test(text(w)) || !isLive(w)) problems.push("worker cell should read 10,612,018 live, got '" + text(w) + "'");
if (isLive(v)) problems.push("the idle verifier must not be marked live");
if (!/10,612,018/.test(text(t)) || !isLive(t)) problems.push("total should include the heartbeat figure, got '" + text(t) + "'");

const burn = text(api.burnCell(fleetAgent));
if (!/10\.6M/.test(burn) || /n\/a/.test(burn)) problems.push("agents table should show the heartbeat figure, got '" + burn + "'");

const counted = Object.assign({}, fleetAgent, { stage_tokens: 2500000, stage_tokens_status: "counted" });
const [cw] = api.stageTokenCells(Object.assign({}, repo, { agents: [counted] }), working);
if (!/2,500,000/.test(text(cw))) problems.push("a transcript figure must still win over the heartbeat, got '" + text(cw) + "'");

if (!/\{ html: burnCell\(a\) \}/.test(source)) problems.push("renderAgents escapes burnCell's markup instead of rendering it");
if (problems.length) { console.error(problems.join("; ")); process.exit(1); }
NODE
printf 'PASS fleet-live-tokens\n'
