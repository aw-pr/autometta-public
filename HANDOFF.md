# Handover

**Status (2026-10-09):** batch 145-147 landed; 148 (model-scoped reserve fix) in flight under a drain until 20:19 BST; next agent ends drain once 148 lands.

## Recent activity (2026-10-09 batch-145-147-landed)

- Batch 145-147 queued one at a time; all three passed first attempt and
  landed on `dev`, pushed: 145 `01f4c1c` (Terra/Opus 5.5), 146 `dd7af39`
  (Sol/Opus 5.5), 147 `4318274` (Opus 5.5/Terra).
- Fleet tick LaunchAgent (`com.autometta.tick.fleet`) had been unloaded since
  2026-10-08 18:28; reloaded. Only emergence-viewer has pending work, blocked
  on stage 49 `verifier_failed`.
- The reserve gate is model-blind: `quota_gate_reading` takes the most-used
  Claude window, so Weekly (Fable) at 73% held 145's Opus 5.5 verifier and
  paused the repo until 2026-10-12. Operator chose a watched `--ignore-reserve`
  drain scoped to autometta (ended early after 147).
- 146 verifier moved from Fable 5.1 to Opus 5.5 (`f264c41`): Fable weekly 73%
  is past the 70% line, Claude weekly 46%.
- Carded the fix as 148 "a model window holds only its model", frozen smoke
  `scripts/model-window-smoke.sh` (`61400bef`). 148 is queued (Terra worker,
  Opus 5.5 verifier) under a second 3h drain until 20:19 BST, because its own
  Opus verifier would otherwise hit the Fable hold it fixes. In flight.
- 145 streaming confirmed live: the 146 verifier log filled with progress
  lines during the run. Quiet gaps are not measurable, as the filter writes no
  timestamps.
- 147 finding: keep `verifier.claude.transport` on cli; the agent-sdk
  entrypoint runs without tools and its probe returned FAIL
  (`state/verifiers/147-probe-144.json` is the probe record, not a stage
  failure).
- Deferred: `jsonschema` pin drift (pinned 4.23.0, installed 4.26.0, found by
  147's worker, out of scope). Five smokes read the live quota and fail on
  admission depending on the day (non-hermetic); `sdk-cache-smoke` needs an
  API key. Not investigated.
- Direction: hold Claude windows at 70% (reserve 30%); Fable is short, prefer
  Opus 5.5 for Claude seats; OpenAI (Astra/Sol) may pass 100% of the session
  window if really needed; operator resets OAI near 80% weekly.
- Open: once 148 lands, end any open drain (`autometta drain end`) and confirm
  a Fable-scoped hold no longer blocks Opus seats. Make the quota-reading
  smokes hermetic? Quota at handoff: Claude weekly 47%, 5-hour 20%, Fable 73%,
  Codex weekly 64%.

## Recent activity (2026-10-09 live-progress-batch-design)

- Operator asked whether to run the repo through the SDKs for finer
  progress monitoring. Finding: the Claude Agent SDK is the `claude` CLI's
  stream-json in a Python wrapper, and both harness transcripts already
  hold per-call, timestamped records that `transcript-tokens.py` reads every
  5s and discards. Cards 23 and 98 had already tried SDK controller and
  worker routes; both stopped at the sandbox. So: card the reader, not the
  transport.
- Carded and committed (`cards(145-147)`): 145 claude dispatches stream
  their log (Terra/Opus 5.5), 146 the agents panel shows turns, last tool
  and age (Sol/Fable 5.1), 147 the agent-sdk pin is current and guarded
  (Opus 5.5/Terra). Each carries a frozen contract test authored here;
  every block fails today at its first assertion and runs clean to the end
  with assertions softened.
- Drift found: `scripts/requirements-sdk.txt` pins `claude-agent-sdk==0.2.87`,
  the brew `python3` (3.14) carries 0.1.81, PyPI is at 0.2.165, and nothing
  in the dispatch path reads the pin. 147 fixes it.
- Measured: a nested `claude -p --output-format stream-json --verbose`
  works from inside a Claude Code session (nine lines, stderr empty); print
  mode refuses stream-json without `--verbose`.
- **Not done**: nothing queued, nothing dispatched. The minder queues 145,
  then 146 only after 145 has landed on `dev`, then 147 the same way;
  shared files mean a gate-released successor would cut from an older
  `dev` and conflict.
- **Watch**: once 145 lands, 146's Fable verifier is the first claude
  dispatch whose log should grow mid-run; note the longest quiet gap
  against the 300s `silent` threshold. If the Fable weekly window is past
  the 80% reserve line when 146 comes up, swap its verifier to Opus 5.5
  before queueing.
- **Deferred**: moving `verifier.claude.transport` off `cli` waits on 147's
  probe record (the manifest is gitignored and the operator's to change);
  mirroring the SDK pin into mcp-hub's dependency registry is out of scope.

## Recent activity (2026-09-26 model-routing-by-identity-slug)

- `claude_model_for_identity` (`scripts/models.sh`) now routes by the
  identity's `<claude-...@local>` slug, which is the API model id; tier
  words only serve identities that carry no slug. `AUTOMETTA_MODEL_OPUS`
  default is now `claude-opus-5-5`. Cards naming "Claude Opus 5" keep
  running `claude-opus-5` until re-carded as "Claude Opus 5.5" — deliberate,
  since attribution must match the weights that actually ran. Committed
  `9cdee02`.
- `scripts/rates.sh` gained `rate_for_model` (per-model USD/1M, mirrors
  `mcp-hub/config/models.json` pricing); `cost-log.sh` now prices the model
  the identity dispatches to (and the advisor's raw model id), falling back
  to `rate_for_tier`. T1 fallback corrected from $15/$75 (Opus 4.1-era) to
  $5/$25; local T5 stays free. Committed `2906059`.
- Verified: new `claude-model-routing-smoke` and `model-rates-smoke` pass;
  `cost-log`, `tick-cost`, `budget-cap`, `adjudicated-spend`,
  `advisor-order`, `ticker-spend` and `verifier-route-matrix` smokes all
  still pass.
- **Deferred**: `rate_for_model` is a hand mirror of the registry pricing,
  not yet wired into mcp-hub's `pricing-check` MIRRORS list. Pre-existing
  smoke failures — `effort-flags`, `local-route`, `phat-controller` (stale
  or undated codex quota reading), `pipeline-pair` — are identical on the
  clean tree before this session and were not investigated.
- **Open questions**: re-card queued Opus 5 stages as Claude Opus 5.5 the
  next time a run is designed?
- Direction: Opus tier moved to Claude Opus 5.5 fleet-wide.

## Recent activity (2026-09-26 publish-sync-review-and-fleet-sync)

- All 15 code-review findings on `scripts/publish-sync.sh` fixed in the
  canonical `mcp-hub` copy, re-synced into this repo, committed (`0675157`)
  and pushed; no stubs left behind.
- `publish-sync.sh` now fast-forwards the publish ref when no commit in the
  range touches a `publishguard.privatefile` path, keeping this repo's
  linear publish model; replay engages only when stripping is actually
  needed. Each replayed commit carries a `Publish-Sync-Source: <sha>`
  trailer as the watermark for the next run, and the attribution
  commit-msg hook is skipped for replay commits so the source message
  otherwise stands unchanged.
- Drift, or a private-path leak after the ref move, now exits 1; a leak
  already on the target is reported and exits 1 even with nothing to
  replay. A glob in `publishguard.privatefile` is refused at startup; a
  trailing slash is accepted.
- Verified: `mcp-hub/tests/test-publish-sync.sh` passes 42/42; a dry run
  here reports mode `fast-forward` for the 9 pending `dev` commits.
  Nothing was run with `--apply`; the `publish` branch is untouched.
- Fleet sync ran: agentic-rag-kimble, bench-marks, emergence-lab and
  explainer-batch pushed clean. research-sweeper committed (`47ad5c9`) but
  its `dev` push was held on an ASK verdict — a GitHub Actions workflow
  watches `dev` there, so that push waits on a human yes.
- **Deferred**: the new mcp-hub test `tests/test-publish-sync.sh` is not
  wired into any CI or quality-check runner (matches the existing test
  there); `docs/PUBLISH-SYNC.md` in mcp-hub still has pre-existing em
  dashes outside the sections touched this session.
- **Open questions**: is this repo's configured privatefile
  (`memory/project-publish-topology-linear-not-orphan.md`), which is
  tracked on neither `dev` nor `publish`, still wanted; should the 9
  pending `dev` commits be published now (a plain fast-forward per the dry
  run) and PR #4 updated?

## Recent activity (2026-09-26 card-137-reserve-and-fleet-rollout)

- **Card 137 landed**: provider-window reserve defaults to a 20% hold (no new
  card past 80% used on any window, per family); `percent: 0` or `action: off`
  disarms it; the default lives in the mandate file so a host with no mandate
  stays off (keeps fixture controller homes in smokes off the live reading).
- `scripts/spawn-worker.sh` is gated by the same rule (`quota_spawn_permits`,
  exit 4 on hold); the tick marks its own spawns
  `AUTOMETTA_RESERVE_GATED=1`; verifiers are not gated at spawn. Host mandate
  `~/.autometta/phat-controller-mandate.yaml` set to 20% hold (was 25%).
- **Fleet rollout**: `refresh-all-repos` restamped emergence-lab and
  reflexivity (committed + pushed on their `dev`); `~/repos/emergence-viewer`
  was vendored but never registered, so it was subscribed (LaunchAgent
  `com.autometta.tick.emergence-viewer` now loaded) and refreshed
  `496c7cc` -> `7f9e6a4`, both commits pushed.
- Docs proposal filed: `docs/proposals/external-dependencies.md` (a
  `dependencies/` directory plan, candidate cards 138-141) — waits on three
  operator decisions (extract the Claude quota publisher from the private
  vibe-menuapp; how `op-fetch`/`agent-whoami` reach a fresh machine given
  `mcp-hub` is private; whether subscriber repos carry the directory,
  recommend no).
- Two later commits by Codex GPT-5.6 Terra (`261bc32`, `9c2d0b0`,
  2026-09-20) layered a Codex admission-policy change on top of card 137 and
  already hold the status line above this section — left as-is, not
  overwritten.
- **Deferred**: stale disabled registry entry
  `~/.autometta/subscribers/emergence-viewer-deep-zoom.yaml` (points at a
  directory that no longer exists, retire it); six pre-existing red smokes on
  clean `dev` (state-branch, state-schema, ticker-fit, tick-cost,
  verify-sdk-schema-path, sdk-cache — not caused by this session);
  `scripts/state-writable-smoke.sh` is named by card 101 as a contract test
  but has no `AUTOMETTA-CONTRACT` block, so the gate will trip the first time
  it is edited.
- **Open questions**: is untracked `scripts/publish-sync.sh` (predates this
  session, untouched) meant to be committed or deleted; the 2026-09-19 Codex
  100% burn came from interactive `codex-tui`/Codex Desktop sessions, not the
  loop, so the reserve protects dispatch only — is that the intended
  boundary?

## Previous status (2026-09-20)

Codex subscription cards now use fresh quota below 100% in both windows for
admission. The active card may finish in overage; subsequent cards wait.
Checks cover manual dispatch and both roles of a new card. Claude reserve and
explicit legacy Codex policy remain supported. Offline admission, reserve,
schedule and budget regressions passed; no provider calls were used in
tests. No automatic reset redemption was added.

## Previous status (2026-09-07 20:30)

Batch 108-134 is **complete**. 109 stages completed, nothing pending, nothing
in flight, nothing awaiting merge. The fleet is refreshed to `fb08d95` and
emergence-lab's working tree is clean. `dev` is pushed.

## State of play

- **autometta is idle with an empty queue.** The machine is free.
- **emergence-lab is paused until 22:00 BST 2026-09-07** by an operator
  record from the previous night ("autometta has the machine overnight
  tonight"). It lifts by itself; clear the record if you want it sooner.
- **A drain expires 2026-09-08 01:06 BST**, after which autometta's cap
  drops back to 600M against ~605M already spent, so it would re-halt on
  `token-cap` if anything were queued. Moot while the queue is empty.
- Spend counters were never reset, so `tokens_spent` is an honest record of
  what this run cost.

## What landed, and the thread running through it

Five stages in this batch failed or nearly failed on **one template
defect**: the stage-card template told whoever held the card to author the
frozen assertion block and record its digest, and whoever holds the card is
the worker. That contradicts `docs/dispatch-contract.md:131`, which exists
so the oracle cannot be tautological. It cost 113, 115, 116, 118 and 123.
**Card 131 fixed it**; `add-stage.sh` now refuses a card that names a test
file without a real digest.

**`check-contract-test-gate.sh` was found wrong about its own inputs four
times, by three different verifiers** (cards 121, 129, 134). It could not
see untracked files, tripped on any file merely mentioning the marker
tokens, gave different answers in `--worktree` and `--staged` about the same
tree, and reported a missing card as a missing digest line. All four are
fixed. This matters more than any single stage: a passing gate is read as
evidence.

**Stage 124 landed with a worker-authored contract test** for the reason
above. Read its verdict knowing that.

**Stage 115's attempt-2 verdict was destroyed** in the state-wipe incident;
its work was re-checked by hand and marked completed. It is the only landed
stage in this batch with no surviving verifier artefact.

## Known defects, surfaced but not carded

- **The tick never reaches its orphaned-verdict scan while a current stage
  is active.** A stage whose worker died after writing a PASS envelope sits
  `in_progress` indefinitely. This hit 108, 110, 114, 116, 118, 120 and 123;
  every one was dispatched to its verifier by hand. **This is the highest-
  value uncarded defect.**
- **A `state_apply_json` write race.** Two verifiers dispatched together
  clobbered one another's `verifier_pid`. Unnoticed, the tick would have
  double-dispatched and burned an attempt.
- **`state-branch-smoke.sh` section 8** fails on clean `dev` and has since
  at least `51a3a3a`; it may read ambient repo state rather than its own
  fixtures. Recorded on card 116.
- **`templates/verifier-prompt.md:15`** tells verifiers to run the gate
  "against the working tree" without naming `--worktree`; a bare invocation
  is staged mode and exits 2 on a dispatch tree. One word, own card.
- **Codex quota readings are stale whenever Codex is idle** - they come from
  its local rollout log, so a figure can sit frozen for hours. Claude's are
  live.
- **Verifier attempt counters understate this batch**, because hand
  dispatches bypass the tick's accounting.

## Two operator notes

- **Never `git add -A` in a run worktree.** Its `state` is a deliberate
  symlink; committing it made git replace the real state directory on the
  next checkout and took `state.yaml`, `budget.json`, every verifier
  artefact and the cost log with it. Recovery came from the
  `autometta/state` snapshot branch, which does not carry artefacts or logs.
- **Editing `dashboard/` in the repo does not reach the page.** Run
  `autometta dashboard` to redeploy, and prefer `--serve --watch` over
  `file://`.

## Unverified by design

The per-stage chart change (`fb08d95`) was made by hand at the operator's
request: ordered by queue newest-first, queued cards at zero, status
colours, and a runs slider. It carries **no verifier and no contract test**.
Checked against a synthetic fixture across three slider positions, and the
three dashboard smokes pass.
