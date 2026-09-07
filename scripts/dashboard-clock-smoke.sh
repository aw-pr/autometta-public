#!/usr/bin/env bash
# dashboard-clock-smoke.sh: the web dashboard states its two times in one
# timezone. No auth, no network, no token spend.
#
# The defect this pins: the header rendered data.generated_at raw, an ISO
# stamp ending in Z, immediately beside a freshness clock built from
# new Date().toLocaleTimeString(), which is local. Under BST the same instant
# reads as an hour apart, so a page regenerated eight seconds ago looks an
# hour stale. Observed 2026-09-07, and it fooled the orchestrator before it
# fooled anyone else.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_source="$(cd "$script_dir/.." && pwd)"
dashboard_js="$repo_source/dashboard/dashboard.js"

command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on PATH" >&2; exit 0; }
node --check "$dashboard_js" || { echo "FAIL: dashboard.js does not parse" >&2; exit 1; }

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/133-the-dashboard-states-its-times-in-one-zone.md
AUTOMETTA_DASHBOARD_JS="$dashboard_js" node <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS, "utf8");

let failed = 0;
function check(desc, ok, detail) {
  if (ok) { console.error("  PASS: " + desc); }
  else { console.error("  FAIL: " + desc + (detail ? " (" + detail + ")" : "")); failed = 1; }
}

// Lift the formatter out of the IIFE and run it, the same way
// dashboard-liveness-smoke.sh lifts loadData. Evaluating the whole file
// would need a DOM; this needs nothing the function does not close over.
const match = source.match(/\n  function formatClock\(stamp\) \{[\s\S]*?\n  \}\n/);
if (!match) {
  console.error("  FAIL: could not find formatClock(stamp) in dashboard.js");
  process.exit(1);
}
const formatClock = new Function(match[0] + "\n  return formatClock;")();

// The whole point: the generated stamp and the freshness clock are the same
// kind of time. A reader comparing them must be comparing like with like.
const iso = "2026-09-07T17:43:24Z";
const local = new Date(iso).toLocaleTimeString();
check("formatClock renders an ISO stamp in the same zone as the freshness clock",
  formatClock(iso) === local,
  "formatClock(" + iso + ") = " + JSON.stringify(formatClock(iso)) +
  ", freshness clock would say " + JSON.stringify(local));

// A raw Z stamp beside a local clock is the defect itself, so it must not
// survive anywhere in the header line.
check("formatClock does not return a bare UTC ISO stamp",
  !/\dT\d|Z$/.test(String(formatClock(iso))),
  JSON.stringify(formatClock(iso)));

// And it must be wired in: a formatter nothing calls fixes nothing. The
// generated-at line must go through it rather than concatenating the raw
// field, which is what shipped.
const generatedLine = source.match(/generated-at[\s\S]{0,400}?;/);
check("the generated-at line exists to inspect", !!generatedLine);
if (generatedLine) {
  check("the generated-at line does not concatenate data.generated_at raw",
    !/["']generated ["']\s*\+\s*data\.generated_at/.test(generatedLine[0]),
    generatedLine[0].replace(/\s+/g, " ").slice(0, 160));
  check("the generated-at line formats its stamp",
    /formatClock\s*\(/.test(generatedLine[0]),
    generatedLine[0].replace(/\s+/g, " ").slice(0, 160));
}

// Bad input must not put "Invalid Date" in front of the operator.
check("an unparseable stamp degrades to something readable",
  !/Invalid Date/.test(String(formatClock("not-a-stamp"))),
  JSON.stringify(formatClock("not-a-stamp")));
check("a missing stamp degrades to something readable",
  !/Invalid Date|undefined|null/.test(String(formatClock(undefined))),
  JSON.stringify(formatClock(undefined)));

process.exit(failed);
NODE
# AUTOMETTA-CONTRACT-END

printf 'PASS: the dashboard states its generated stamp and its freshness clock in one timezone\n'
