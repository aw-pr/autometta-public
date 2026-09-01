#!/usr/bin/env bash
# dashboard-liveness-smoke.sh: the web dashboard must not call itself live
# when it cannot reach its server. No auth, no network, no token spend.
#
# The defect this pins: loadData() caught every fetch failure and returned the
# snapshot index.html embedded at page load. That resolved the promise, so
# poll() took its success path, reset the failure counter, found generated_at
# unchanged and reported "live - unchanged at <clock>". A dead server was
# indistinguishable from an idle run, which is the one thing that status line
# exists to tell apart. Observed 2026-09-01: a page sat on an 08:39Z snapshot
# until 11:10 still calling itself live, while the aggregator had been writing
# fresh data to a different port all along.
#
# What it asserts:
#
#   1. On the first paint the embedded snapshot is still used, so a page whose
#      very first fetch loses a race still draws instead of showing an error.
#   2. On any later poll a failed fetch rejects, so the poll's own catch runs
#      and the reader is told.
#   3. A live fetch always wins over the embedded snapshot, whichever mode.
#   4. The wiring matches: the first paint asks for the fallback, the poll
#      refuses it. A behavioural guard is worthless if nothing calls it that
#      way.
#   5. The failure message names the staleness, not just the error.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
dashboard_js="$repo_root/dashboard/dashboard.js"

command -v node >/dev/null 2>&1 || { echo "SKIP: node is not on PATH" >&2; exit 0; }
[[ -f "$dashboard_js" ]] || { echo "FAIL: $dashboard_js is missing" >&2; exit 1; }

node --check "$dashboard_js" || { echo "FAIL: dashboard.js does not parse" >&2; exit 1; }

AUTOMETTA_DASHBOARD_JS="$dashboard_js" node <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS, "utf8");

let failed = 0;
function check(desc, ok, detail) {
  if (ok) { console.error("  PASS: " + desc); }
  else { console.error("  FAIL: " + desc + (detail ? " (" + detail + ")" : "")); failed = 1; }
}

// Lift loadData out of the IIFE and run it against stubs. Evaluating the whole
// file would need a DOM; this needs only the four names loadData closes over.
const match = source.match(/\n  function loadData\(allowEmbedded\) \{[\s\S]*?\n  \}\n/);
if (!match) {
  console.error("  FAIL: could not find loadData(allowEmbedded) in dashboard.js");
  process.exit(1);
}

function buildLoadData({ isFile, fetchWorks, embedded }) {
  const scope = {
    isFile,
    window: embedded === undefined ? {} : { AUTOMETTA_DATA: embedded },
    loadViaScript: () => Promise.resolve({ via: "script" }),
    loadViaFetch: () => fetchWorks
      ? Promise.resolve({ via: "fetch" })
      : Promise.reject(new Error("Failed to fetch")),
  };
  const factory = new Function(
    "isFile", "window", "loadViaScript", "loadViaFetch",
    match[0] + "\n  return loadData;");
  return factory(scope.isFile, scope.window, scope.loadViaScript, scope.loadViaFetch);
}

async function main() {
  console.error("== 1. the embedded snapshot is a first-paint courtesy ==");
  const firstPaint = buildLoadData({ isFile: false, fetchWorks: false, embedded: { via: "embedded" } });
  const drawn = await firstPaint(true).catch((e) => ({ threw: e.message }));
  check("a failed first fetch still draws from the embedded snapshot",
        drawn && drawn.via === "embedded", JSON.stringify(drawn));

  console.error("== 2. it is not a standing fallback ==");
  const laterPoll = buildLoadData({ isFile: false, fetchWorks: false, embedded: { via: "embedded" } });
  let rejected = null;
  await laterPoll(false).then((v) => { rejected = { resolved: v }; },
                             (e) => { rejected = { message: e.message }; });
  check("a failed poll rejects rather than replaying the page-load snapshot",
        rejected && rejected.message === "Failed to fetch", JSON.stringify(rejected));

  console.error("== 3. a live fetch always wins ==");
  for (const allow of [true, false]) {
    const ok = buildLoadData({ isFile: false, fetchWorks: true, embedded: { via: "embedded" } });
    const got = await ok(allow);
    check("allowEmbedded=" + allow + " still prefers the served data",
          got.via === "fetch", JSON.stringify(got));
  }

  console.error("== 4. the call sites match the guard ==");
  check("the first paint asks for the fallback",
        /\n  var first = isFile && window\.AUTOMETTA_DATA[\s\S]*?loadData\(true\);/.test(source));
  check("the poll refuses it",
        /function poll\(\) \{\n    loadData\(false\)/.test(source));

  console.error("== 5. the failure is legible ==");
  check("a persistent failure says NOT LIVE rather than stale",
        /setLiveStatus\("NOT LIVE"/.test(source));
  check("and names the generation it is stuck on",
        /showing data generated/.test(source));

  process.exit(failed);
}

main().catch((e) => { console.error("  FAIL: harness error " + e.message); process.exit(1); });
NODE
status=$?
if [[ "$status" -eq 0 ]]; then
  printf 'dashboard-liveness-smoke: PASS\n' >&2
else
  printf 'dashboard-liveness-smoke: FAIL\n' >&2
fi
exit "$status"
