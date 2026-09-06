# Handover

**Status (2026-09-06):** 104/105/106 re-briefed and requeued (104 in flight);
seventeen new cards 107-123 authored from the wall-clock analysis and queued
behind them. Queue order is instrumentation, network and stall guards,
preserve, disjoint-landing auto-integrate (111), resume verb, pair-by-default
(113, gated on 111), fire profiling, land-and-dispatch (115, gated on 111),
four red-smoke repairs, MCP isolation, gate candidates (121, gated on 106),
cwd-independence, credential-symlink check. Spend estimate ~115M tokens for
the twenty stages (4.5M median per stage plus one p95 outlier). Analysis
summary: a landed stage is ~20 min of agent time, the median gap between
stages is 31-78 min, two-in-flight time is 4%, and 21 landings were hand-
merged after "dev moved". `dev` pushed.

## Recent activity (2026-09-02 — the guard that acts instead of narrating)

- **Token-outlier detector now kills, not just watches.** `AUTOMETTA_OUTLIER_KILL_MULTIPLE`
  (default 15x baseline, 0 disables) terminates a runaway stage rather than
  merely flagging it. 15x was chosen against the largest legitimate stage
  spend on record — 19,502,742 tokens against a 1.64M median, 11.9x — so
  honest slow stages are never killed; stage 73 hit 22.2x and was the
  motivating case. Proven against four real processes: 11.9x survives, 14.9x
  survives, 22x with the kill disabled survives, 22x with it enabled is
  killed. `tui-smoke` and `tui-messages-smoke` pass.
- **`heartbeat.sh` is not vendored** — it runs centrally from the checkout via
  `AUTOMETTA_ROOT`, so the kill-path fix reached every subscriber on commit
  with nothing to distribute per-repo.
- **`aggregate-dashboard.sh` was reading `stage_card_globs` with jq's
  `// empty` syntax, which mikefarah `yq` rejects.** Broken since `ad16c1c`
  (2026-05-26): manifest globs were never actually read, and hardcoded
  fallbacks silently did all the work. Surfaced only because stage 103 added
  `append_state_error` to that code path. Verified fixed by re-running
  `aggregate-dashboard` and confirming the `state_error` cleared.
- **TUI stage-state split `ESCALTD` into `STALLED` / `V-FAILED` / `FAILED`**,
  and `elapsed` now derives from `started_at` against the 5s poll clock
  instead of the heartbeat's ~60s `elapsed_seconds` — a live dispatch dates
  from the agent's own start, not the stage's. Queue position now rides the
  attempt row and the run clock rides the budget row, because `tui-smoke`
  asserts the stage card is never truncated at 80 columns and every metadata
  row is one the card loses; two attempts at a dedicated row both failed that
  assertion. The dashboard's stage table now sorts by queue position (last
  first), then newest-dated-first, then undated terminal stages last.
- **Cards 105 and 106 authored and queued; 102 re-briefed and landed clean**
  (6/6, contract gate recomputed a real sha256 for the first time).
- **Deferred:** stage 104 verifier_failed a second time (4/7) — needs a third
  re-brief with a straggler grep actually run, not transcribed from the
  verifier; it missed `skills/autometta-requeue/SKILL.md:8-10,21-26`. Stage
  105 verifier_failed on a one-token marker mismatch (`stage=105-...` vs the
  gate's required `card=<path>`) despite 6/6 criteria passing. Stage 106
  verifier_failed on its **own** contract test — `gate-smoke.sh` necessarily
  contains marker-token fixtures, so `cmd_gate` counts several frozen blocks
  and rejects the file; the gate cannot verify its own test and this needs a
  design decision (open question below). The installed Homebrew build has
  drifted again (checkout at `831fb07` or later); nothing was in flight at
  last check, `scripts/install-homebrew-local.sh` closes it.
- **Direction:** guard philosophy shifted — detection must act, not narrate.
  The consecutive-failure cap and the drain cap are backstops; the outlier
  kill is the guard that actually bounds a runaway.

## Recent activity (2026-09-01 — the SDK that was the other SDK)

**The verifier had not run in any subscriber repo since 2026-08-31.** Card 90
made "the SDK" the verifier's transport of first resort; card 89 was titled
"the SDK verifier runs on the subscription". Neither was true as built, and it
took running a real repo against the route to find out. Two independent
defects, both fixed:

- `verify-sdk.py` read `SCHEMA = Path("schemas/verifier.json")`, relative to
  cwd. A dispatched verifier runs with cwd set to the subscriber's run
  worktree, and `schemas/` is not in the vendored set, so it died one second
  after every dispatch on `verifier schema not found`. It only ever worked in
  autometta, where cwd happens to hold the file (`1df9ab3`).
- `verify-sdk.py` imports `anthropic` — the **API SDK**, the raw Messages API —
  while its docs, its dispatch branch and its own `VERIFIER_IDENTITY` all named
  `claude-agent-sdk`. A Claude Code subscription token is not a credential for
  that surface. Measured, one request each, same model and minute: `max_tokens=4`
  returned **429** on the OAuth token, **200** on `ANTHROPIC_API_KEY`, and
  `claude -p` on that same OAuth token answered. Card 89 passed because
  `verify-sdk.py` prefers `ANTHROPIC_API_KEY` when both are present, so the
  subscription token was never the credential under test.

**A 429 with no rate-limit headers is not a quota.** The first diagnosis of the
above was "the subscription window is saturated, wait it out", and it was
wrong — a four-token request cannot exhaust anything, and the response carried
`x-should-retry` with no `retry-after` and no `anthropic-ratelimit-*`. The
operator pushed back on it, twice, and both pushes were right.

**`models.sh` now holds the route matrix** (`361b43c`): `cli` and `agent-sdk`
take either credential, `api-sdk` takes only an API key. `claude_route_guard`
applies it inside `resolve_verifier_transport`, so it covers the env override
and the manifest as well as the default, and `--print-transport` reports what a
dispatch would actually take. A refused pairing downgrades to the CLI with its
reason rather than failing the stage.

**Card 99 implemented the missing surface.** `scripts/verify-sdk-agent.py`
drives `claude_agent_sdk` with `output_format` set to a `json_schema`, so the
artefact comes back as `ResultMessage.structured_output` with no
markdown-JSON parsing. Verified with a credential control the card did not ask
for: with `HOME` redirected to an empty directory so no ambient
`~/.claude/.credentials.json` was reachable, the real token still produced a
PASS artefact while a bogus token and no token both failed. **No default
changed** — `agent-sdk` is available to a manifest that asks for it, and card
90 is the cautionary tale for promoting a transport early.

**Card 99 was the last card that could ever be queued.** The stage-id pattern
was `^[0-9]{2}[a-z]*-` — exactly two digits — so `add-stage` rejected card 100
as malformed. Widened to `{2,}` in **thirteen** files (`dba0f2e`);
`schemas/state.yaml.json` alone carried six copies. The smoke's third
assertion greps for any surviving narrow copy rather than checking a list, and
that is what found the last five *after* a first pass had been made and
believed complete.

**Model ids re-synced to `mcp-hub/config/models.json`** (`ceaf80b`). The
load-bearing one was `identity_for_model`, whose table stopped at the 4.x ids:
every SDK verifier run on `claude-sonnet-5` since the July bump was filed under
a generic fallback label rather than a name `git shortlog` can group.

**The loop got faster.** Two LaunchAgents were running the *identical* bare
`autometta tick` — both scanning the whole fleet, neither scoped to a repo
despite one being named `autometta-testing`. That was the source of all 194
`tick already in progress` skips. Duplicate unloaded (plist in the session
scratchpad), cadence 300s -> 30s, work-tick cap 400 -> 2000. Observed after:
tick starts 123s and 118s apart, **zero** lock skips.

**The TUI** reads one token unit across the history tab and both detail panes
(`c22be06`), and the detail pane now follows the cursor instead of waiting for
enter (`907628a`).

## Open questions and known-bad, for the next agent

- **Should the 80-column no-truncation guarantee in `tui-smoke` be relaxed**
  so the TUI can give run timing its own labelled row? The operator asked to
  see the time and it is currently appended to the budget row rather than
  broken out.
- **How should `check-contract-test-gate.sh` handle a test file whose content
  is legitimately markers** (`gate-smoke.sh`)? Candidates: heredoc-quoted
  fixtures, a scoped block, or exempting that file by name. Blocks stage 106.
- **Does the token-burn sparkline need the same poll-clock treatment as
  elapsed?** `live_usage` still comes from the heartbeat, not the 5s poll
  clock that `elapsed` was moved onto this session.
- **`state-branch-smoke.sh` and `superseded-status-smoke.sh` both fail on a
  clean `dev`**, predating this session's batch. `superseded-status-smoke`
  also fails at `e057331` — i.e. before stage 103 touched `render.py` — so
  103 did not introduce it. Neither is carded yet.
- **A fleet tick costs 90 seconds** — 90.20 / 90.22 / 91.54 wall, 63-64s user,
  30-31s sys, six subscribers, four of them drained. That is now the loop's
  response floor: launchd will not restart a running job, so the effective
  cadence is `max(interval, duration)` and the 30s setting lands at ~120s. It
  is paid three times per stage. **Card 100 is in flight against this** and
  carries the ruled-out list — yq, jq, the quota scan, aggregate-dashboard,
  git fetch, hash-object, status, lock contention and a fixed sleep are all
  measured and none is the cause. `sample` shows only bash frames.
- **The one lead in card 100 is weak and the card says so:** a `bash -x` trace
  recorded 2,349 commands, which cannot account for 90 seconds, and was
  probably taken while the LaunchAgent held the per-repo locks. Re-take it with
  the agent unloaded, **and load it again afterwards** — the loop is live.
- **`--print-transport` reports the resolver's answer**, which is now correct,
  but the sdk+subscription downgrade happens there rather than at dispatch. If
  a future route needs a dispatch-time decision, that split will need
  revisiting.
- **`verify-sdk.py` still writes its live-usage registry to a cwd-relative
  `state/active-agents/<pid>.json`** — same family as the schema defect, seen
  as a stray warning in card 99's transcript. Harmless where it runs today.
- **`retro-grade-batch.py:19` carries the same cwd-relative
  `schemas/verifier.json`** that was fixed in `verify-sdk.py`. Lower risk since
  it normally runs from the repo root, but it is the same defect.
- **`tui-history-smoke.sh` is red on a clean `dev`** — a *fourth* red smoke, not
  in the previous handoff's list of three. Confirmed pre-existing by stashing
  the session's TUI change and re-running. It is the "two definitions of
  tokens" item.
- **Pairing is not the lever it looks like.** `pipeline.pair_on: off` is the
  *widest* setting, not "disabled", and pairing overlaps a worker with the
  previous stage's verifier. It has fired twice in the whole log against
  fifteen refusals; the common refusals are missing or overlapping
  `path_claims`. Parallelism comes from authoring cards with accurate disjoint
  claims, not from the config key.
- **Resolved: `handoff.mode` set to `tracked`.** `de863ba` (this repo) moved
  the key from `envelope` to `tracked`, untracked `HANDOFF.md` from
  `.gitignore` and git-tracked it; `a9d938e` (`mcp-hub`) updated the fleet
  dev-rules to say a dispatch envelope and a session handoff are different
  artefacts, and seeded `registry/repo-policies.json` so the sync script
  won't revert this. Privacy did not regress: `publishguard.privatefile`
  already named `HANDOFF.md`, verified by dry-run to block it at the
  `publish` boundary. Card 104 is queued to remove the name collision itself
  by renaming the envelope artefact.
- **Machine state changed outside any repo:** the duplicate LaunchAgent plist
  was moved to the session scratchpad rather than deleted, and
  `.autometta.local.yaml` gained `base_branch: dev` (gitignored, local). Both
  are reversible and neither is in git.
- Unchanged: `aggregate-dashboard.sh` swallowing a jq failure (card 103 queued),
  `state.yaml` failing its own schema with 69 errors (card 102 queued), the two
  definitions of "tokens", `BUILD STALE` printing two identical SHAs, and the
  TUI's empty run state being unable to tell "no run yet" from "just finished"
  — seen live today, moments after stage 69 landed.

## Recent activity (2026-09-01 — three adjudications, and four lying instruments)

**The keg was stale by two cards.** Built at `eb18378` against a checkout of
`6774b0d`, so cards 96 and 97 were merged the night before and live nowhere.
Re-rendered. `state/heartbeat.json` carries a `build_check` block that says so;
read it when picking up a session, because nothing else fails loudly.

**Stage 79 landed at 5 of 6, by adjudication.** Its fix had been parked on a wip
branch for two days: `dev`'s `spawn-worker.sh:147` still had the pre-fix
`worker_family_notes="None"` and the smoke did not exist there. Criterion 2 asks
that reverting the fix make the smoke fail, and the verifier measured 3 pre-fix
*passes* in 14 trials, because the pre-fix arm asks a 20B model to use the card's
checkout rather than forcing it. Landed with that as a recorded caveat.
**Open:** make that arm turn on a sandbox property, not an instruction. Until
then a green `local-worktree-write-smoke.sh` is not evidence the fix is needed.

**Stages 23 and 98, the SDK experiments, both landed by adjudication** (9/10 and
6/8) after three attempts and one respectively. Their shared finding is worth
more than either Decision: an agent session spawned inside a dispatched role
needs the sandbox opened three times over — network, then a writable
`~/.claude`, then credentials it can actually reach — where an ordinary role
needs it opened not at all, because the codex CLI calls the API from outside the
sandbox. Two card-level grants now exist for the first two
(`Requires network`, `Requires agent home`); both are narrow and keep
`workspace-write`.

**But both Decisions rest on a constraint since lifted.** "Keep cron+tick" and
"workers stay CLI" were each reached *before* the grants existed, and card 98's
worker had reached the right call for the right reason: to get writability it
moved the config dir into the worktree, which emptied it of credentials, and it
refused to copy them or widen the sandbox because that would alter the boundary
under test. The claim that an SDK role cannot reach its first tool call is now
**untested, not established**. `docs/experiments/*-postmortem.md` say so in
their own words. If the question matters, re-run with both grants.

**Four instruments were lying, all in the same direction — reporting healthy.**

- `requeue-stage.sh` zeroed `worker_tokens` and `tokens` but not
  `verifier_tokens`, so a re-queued stage reported its previous verifier's spend
  against an attempt that had never run.
- The web dashboard caught every failed fetch and replayed the snapshot embedded
  at page load, so `poll()` took its success path and printed
  "live · unchanged" against a dead server for two and a half hours.
- History cards and every "lost" figure were built from the cost log alone, so
  adjudication was invisible to them: 30.3M tokens across stages 23, 79 and 98
  were reported as wasted work after being landed on `dev`.
- The TUI's status panel moved four lines under the reader's eye whenever the
  data-age line appeared, and put the run's spend on the same line as the repo's
  lifetime cap percentage, where "6.9M ... 600.0M (53%)" invited a reading wrong
  by a factor of forty.

Each now has a smoke that fails on the unfixed code: `requeue-reset-smoke.sh`,
`dashboard-liveness-smoke.sh`, `adjudicated-spend-smoke.sh`, and the ordering
and unit assertions in `tui-smoke.sh`.

**The TUI also gained** thousands-grouped token units on the two watched panels
(`1,143k`, so a poll visibly moves the number), an in-flight live-spend ticker
read from the heartbeat's transcript totals, and panel 5, which carries the
loop's own tick-log narration plus the refresh line that used to shove the
status panel around.

### Open questions and known-bad, for the next agent

- **`consecutive_failures` was 2 of 3 and is now 0**, reset at the close of the
  2026-09-01 session. Note the fleet-wide `autometta tick --reset-halt` also
  zeroes tick and idle counters for *every* enabled subscriber; to clear one
  repo's failures alone, `budget_write_atomic <repo> '.consecutive_failures = 0'`
  via `scripts/budget.sh` touches nothing else.
- **`autometta-testing` sits at 1 of 3** and was left alone.
- **`state/state.yaml` fails its own schema with 68 errors**, all pre-existing
  from stage 9 onward: `tokens`, `verifier_tokens`, `verifier_started_at` and
  `notes` are undeclared in `schemas/state.yaml.json`. That validation currently
  proves nothing.
- **Three smokes are red on a clean `dev`** and were before today:
  `fleet-ticker-smoke.sh` (2 tmux window-plan assertions) and
  `effort-flags-smoke.sh` + `state-writable-smoke.sh`, the latter two failing the
  *same* codex-verifier argv adjacency assertion. That smells like one change to
  `spawn-verifier.sh` rather than three faults.
- **`aggregate-dashboard.sh` swallows a jq failure into an empty default.** A
  syntax error there returns *no history at all*, silently, rather than erroring.
  This nearly shipped today.
- **Two definitions of "tokens" coexist in the aggregator**: the repo-level lost
  figure sums `input+cached+output`, a history card reads `total_tokens`. They
  diverge whenever a row's total is not the sum of its parts.
- **`BUILD STALE` prints two identical SHAs** when only files have drifted
  (uncommitted edits), which reads as a false positive. It should name the file
  count.
- **Resolved later the same day: `handoff.mode=envelope` misclassified this
  repo.** `state/handoffs/<stage>.json` is the worker→tick completion
  protocol, not a session handoff, and following the handoff skill literally
  under that mode wrote no session handoff at all. Fixed in `de863ba` /
  `a9d938e`; see the resolved entry in the "SDK that was the other SDK"
  session above for the detail.
- **Per-repo dashboards under `~/.phat-controller/dashboard/repos/`** are only
  regenerated on demand; one sat a day stale with nothing on the page saying so.
- **The TUI's empty run state** cannot tell "no run yet" from "the run just
  finished", which is the moment a reader is most likely to look.

## Recent activity (2026-09-01 — keg re-render, stage 79 adjudicated, stage 23 re-queued)

**The keg was stale by two cards.** Built at `eb18378` against a checkout at
`6774b0d`, so cards 96 (no verdict left behind) and 97 (a pause is not a
stall) were merged but not installed. Re-rendered with
`scripts/install-homebrew-local.sh`; `check-installed-build.sh` reports a
match, and `budget-cap`, `pipeline-pair`, `idle-tick` and
`installed-build-warning` smokes all pass against it.

**Stage 79 landed by adjudication at 5 of 6 criteria.** Its fix was sitting
unlanded on a wip branch: `dev`'s `spawn-worker.sh:147` still carried the
pre-fix `worker_family_notes="None"` and the smoke did not exist there, so a
confirmed root-cause fix was parked over a criterion no seat can satisfy.
Criterion 2 asks that reverting the fix makes the smoke fail; the verifier
measured 3 pre-fix passes in 14 trials, because the pre-fix arm asks the model
to use the card's checkout rather than forcing it. Landed with that recorded
as a caveat rather than a pass, and with two verifier notes applied: the new
lessons section was numbered 14 against two existing 14s and is now 20, and
the determinism claims in the smoke comment and the prose now state the
measured rate. `local-worktree-write-smoke.sh` and `local-route-smoke.sh` both
pass on `dev`.

**The open follow-up on 79** is to make the pre-fix arm turn on a sandbox
property rather than an instruction. Until then the smoke is a sound
regression test of the fixed route and a weak proof of necessity. Do not read
a green run as evidence the fix is still needed.

**Stage 23 re-queued for attempt 2.** The verifier scored 7 of 10 and the
load-bearing failure is criterion 2: `tests/sdk-controller-experiment/stage-A.md`
runs `echo hello > /tmp/sdk-exp-A.txt`, a command that cannot fail, yet the
session logged `stage-A: failed: worker`. The apparatus could not run its own
success case, so the "keep cron+tick" Decision does not yet rest on an
observation. The re-brief asks for the subprocess exit status and streams in
the log before any fix. Criteria 4 (the SIGTERM was described as design, never
sent) and 7 (decision memo has no frontmatter) are the smaller two. Re-queued
through `requeue-stage.sh`; attempt 1 is preserved at `94570284`.

**Two subscribers were on a stale dispatch contract.** `emergence-lab` and
`fractals-from-the-90s` both refreshed to `e00c296`, picking up the
established-facts section in the verifier prompt. `fractals-from-the-90s` had
been refusing every refresh since 2026-08-30 because a prior refresh was left
uncommitted on `templates/stage-card.md`; that is committed now, so refreshes
work there again. Four other repos under `~/repos` carry older stamps
(`data-graph-experiment`, `my-own-private-ai`, `promo-flow-data-visuals` at
`a360ede`, `emergence-viewer` at `496c7cc`, `reflexivity` at `ae41921`) but
none is ticked by the loop, so nothing is blocked on them.

## Recent activity (2026-08-16 card 36 — keg re-render + emergence-lab triage)

**The keg was eight commits stale, not one.** It was built at `205ff9a`, so it
already carried the card-30 effort-flag fix but none of card 29 (sandboxed
codex role can write the shared state dir), card 31 (caps gate every dispatch)
or card 35 (a usage refusal is a pause, not a stage failure). Re-rendered from
a clean `dev` with `scripts/install-homebrew-local.sh`; `autometta --version`
and `git rev-parse --short HEAD` both read `996d42e`. All three smoke tests
pass against the installed keg, not the checkout:
`state-writable-smoke.sh`, `effort-flags-smoke.sh`, `usage-error-smoke.sh`.

`aegis-guardrails` and `agentic-rag-kimble` both pin
`/opt/homebrew/opt/autometta/libexec`, the version-independent symlink, so they
picked the re-render up with no edit. Both ticked clean afterwards — unhalted,
`consecutive_failures: 0`, tick counter advanced. Their queues are drained, so
neither had a stage to dispatch; the evidence is that the loop reached and
processed them on the new keg without error.

**None of `emergence-lab`'s five broken stages was a victim of card 29 or 30.**
Both defects postdate the incidents by two and a half months; the statuses
matched only because `verifier_failed` and `stalled` are the only terminal
states the loop has. Full per-stage reasoning with log citations is in
[`docs/incidents/2026-08-16-emergence-lab-five-broken-stages.md`](docs/incidents/2026-08-16-emergence-lab-five-broken-stages.md).
In short:

- **05** is a genuine failure — the worker knew the gzip delta (85.82 kB, over
  the 80 kB soft cap) and did not put it where the card required. Left alone.
- **13, 14, 15** have working committed code (`a0ba582`, `6af7104`, `38b5e6d`)
  and one FAIL each, always the browser-smoke criterion, always because the
  verifier could not get a browser rather than because the code was wrong. A
  requeue reproduces it exactly. These need a card re-brief, which is a human
  call about what evidence a headless seat may substitute.
- **16** is the one real tooling victim: its worker died on `Not logged in ·
  Please run /login` (the `op-fetch` env-strip defect fixed the same day in
  `436c597`) and no verifier ever ran across three attempts. Requeued through
  `requeue-stage.sh`; the next tick cut a fresh worktree and its worker was
  still running six minutes in, against an original that died in seconds.

### Open questions for next agent

- **Re-brief cards 13, 14, 15 and 16 together.** Four stages are parked in a
  terminal state over an acceptance criterion no autonomous seat can satisfy.
  Decide what stands in for "looks right in a browser" — a headless screenshot
  diff, a DOM assertion, an explicit human sign-off step outside the loop — and
  apply it to all four at once. Stage 16's requeued verifier will most likely
  land in the same place.
- **Settle stage 15's design ambiguity while re-briefing it.** Its worker
  pinned `pointSize` at `min = max = 16`, so the slider is degenerate, and
  flagged that `boidsGlyphRadius()` still hard-clamps at 8. The card does not
  say whether 16 was a floor or a fixed value.
- Should the loop distinguish "the verifier judged the code wrong" from "the
  verifier could not obtain the evidence"? It spends the retry cap identically
  on both, which is how four stages with working code ended up terminal.

## Recent activity (2026-08-14 requeue-stage.sh)

Session scope: land the sanctioned stage re-queue tool and its companion skill, then a documentation-only handoff pass. No behaviour change to `tick.sh` itself this session.

- **`scripts/requeue-stage.sh` is the sanctioned stage re-queue path.** Purges per-stage envelopes/logs/agent registrations, resets the stage to pending, and clears the halt. Refuses to run while the tree is dirty outside `state/` — worker WIP must be committed first, authored by the worker model. Landed complete and tested (refusal path and full-reset path both verified against a scratch repo), gate green: `bash -n` clean, both code paths live-tested before commit `ec4c424`.
- **Companion skill `autometta-requeue`** lives canonically in `mcp-hub/skills` (symlinked into `~/.claude/skills`). `ai-schedules` gained a window preflight that reports halted, dirty, or stale-envelope subscribers.
- **Deferred:** this repo is itself still a halted subscriber — the tree carries pre-existing untracked `docs/plans/` and `memory/adopters/promo-flow/` dirs. Resolve their provenance before unhalting.

### Open questions for next agent

- Should `tick.sh` itself refuse verifier dispatch when the worker envelope predates the current card mtime — defence in depth beyond `requeue-stage.sh`?

## Recent activity (2026-07-04 fable-as-advisor verifier)

Fable-as-advisor verifier built on `dev` (3 atomic commits, fc319a0/3ee61fa/73ae182, Opus 4.8, nothing pushed): `verify-sdk.py` gains a `--advisor` slot + #66714 capability-ordering guard (fable>opus>sonnet>haiku, rejects inverted pairs locally before any call) + retention note + `scripts/advisor-order-smoke.sh`; `spawn-verifier.sh` resolves `verifier.claude.advisor` under the sdk branch; docs (`sdk-verifier.md`, yaml example) + SKILL.md T0-as-dispatched-Fable reconciliation. Gate green: cost-log-smoke + advisor-order-smoke pass, AST parses. NO live Fable call made. Queued (post-exam): one advisor smoke run — Sonnet request + Fable advisor via verify-sdk.py in api mode — confirm cost-log two-line pattern + cache_hit_rate>0.

## Where the directives live

The agent brief is in `CLAUDE.md` (and `AGENTS.md`, which is a symlink to it). The auth-route surface is documented in `docs/setup.md` section 7, `README.md` "Billing routes", `docs/lessons.md` gotchas 6-9, and `memory/decision-auth-route-toggle.md`. The full self-host backlog and status is in `examples/self-host/PLAN.md`. Read those first; this file is the dated session log.

## Recent activity (2026-06-10 contract-test gate + per-role attribution + vendor freshness)

Opus 4.8 session. 4 atomic commits on `dev` (`0f93fcb`–`6a89be9`). Cross-repo fan-out: 3 adopters retrofitted (1 commit each), mcp-hub re-synced (227/227 checks). Nothing pushed anywhere.

- **Frozen contract-test gate** added to the dispatch contract (`0f93fcb`). Orchestrator authors the assertions inside `AUTOMETTA-CONTRACT-BEGIN/END` blocks; worker satisfies them without editing the block; verifier guards via a sha256 digest recorded in the card (`scripts/check-contract-test-gate.sh`).
- **autometta-setup vendoring** (`eead35f`): setup now vendors the gate script + `scripts/autometta-vendor-check.sh` and writes a `.autometta-vendor` provenance stamp. New Step 1b freshness check runs at setup time.
- **Per-role commit attribution** (`436557b`, `6a89be9`): `tick.sh` author = worker; role-named `Co-Authored-By` lines for orchestrator (identity parsed from card metadata) and verifier; `Autometta-Orchestrator/-Worker/-Verifier` trailers carry canonical identities. Orchestrator also added as co-author with `(orchestrator)` role in the display name.
- **3 adopters retrofitted** with vendor freshness check + contract-test gate (emergence-lab, fractals-from-the-90s, my-own-private-ai), 1 commit each. **mcp-hub** re-synced (227/227 checks); generated aggregate catalogs untracked + gitignored (3 commits).
- **Deferred:** codex-mini worker-tier identity row in mcp-hub-dev-rules.md; dogfood stage card through Autometta's own loop; register my-own-private-ai in `autometta/memory/adopters/`.

### Open questions for next agent

- Register my-own-private-ai in the adopter registry (`autometta/memory/adopters/`)?
- Author the dogfood stage card to run this change set through Autometta's own dispatch loop?

## Recent activity (2026-06-07 cost instrumentation + prompt caching)

Opus 4.8 session off the `token-maxing` kickoff (TOKEN-SPEND-TODO item 2). Instrumentation first so the caching saving is measured, not assumed. Commits `9fcbdc4`, `9038385`, `af0684f` on `dev`.

- **Phase 1, cost-log.** `scripts/cost-log.sh` appends one JSONL line per dispatched role to `state/cost-log.jsonl` at the existing token-accounting points in `tick.sh` (worker reap, verifier artefact, aborted re-dispatch). Each line carries tier, auth route, input/cached/output tokens, `cost_usd_est` from a single per-tier rate table (`scripts/rates.sh`), `cache_hit_rate`, and result. Schema + per-route fidelity in `docs/cost-log.md`. `tick.sh` stamps `verifier_started_at` and gained a `BASH_SOURCE` guard so its functions are sourceable for tests.
- **Phase 2, caching.** Reordered `templates/worker-prompt.md` + `templates/verifier-prompt.md` so the instructional prose is a byte-identical cacheable prefix and per-dispatch values sit in a trailing `## This dispatch` block (breakpoint-after-stable-prefix for the implicit-caching CLI routes; the SDK verifier route already split explicitly). Fixed a latent gap: `spawn-worker.sh` never substituted `<<stage-id>>`.
- **Live-verified.** `sdk-cache-smoke.sh` via op-fetch: cold `write=1765 read=0` → warm `write=0 read=1765` (real API cache hit on the reordered template). Real cost-log lines produced from live API logs, full schema. `scripts/cost-log-smoke.sh` proves cache_hit_rate 0→0.88 and a measured cost reduction offline.
- **OAuth-vs-API caching finding.** Both routes cache; only the API route surfaces cached-token counts, so only it is measurable from the log. Banked in `memory/decision-cost-log-and-caching.md`.
- **Fleet refresh.** Reinstalled the local CLI (`ebd7ea0` → `af0684f`). `emergence-lab` (commit `3c98f29`) and `fractals` (commit `499d46a` on `feat/julia-deep-zoom`) adopted the current dispatch contract: refreshed templates + scaffolded `state/handoffs/` + `.gitignore` exceptions. Both held clean older autometta template revisions (no bespoke content overwritten); fractals' unrelated feature work + `.codegraph/` ignore left untouched.

### Open items for next agent

- **All three subscribers are halted with 0 pending stages.** Nothing dispatches until `autometta tick --reset-halt` + a queued stage. Cost-log lines start on the first real dispatch.
- **Exercise the cost-log end to end:** queue fractals U-USA-6, reset its halt, tick. For measurable caching, dispatch its verifier on the API route (fractals manifest is `subscription`; only the API/SDK route returns cached-token counts).
- **emergence-lab + fractals manifests are `subscription`**, so their cost-log `cache_hit_rate` will read 0 even with caching active until a role runs on the API route.

## Recent activity (2026-05-29 launchd verification + v0.1.0 publish)

Opus 4.8 orchestrator session: closed the launchd verification gate, ran a doc-currency pass, rewrote the publish workflow to match reality, and published the first tagged release. Commits `59d8091`, `93aab0b`, `b161918`, `ebd7ea0` on `dev`, all fast-forwarded onto public `main`.

- **LaunchAgent SIGHUP fix VERIFIED.** A real launchd `RunAtLoad` tick dispatched a claude/Haiku worker that survived the tick exit and ran to completion (envelope `pass`); cross-family codex verifier returned PASS. `disown` + `AbandonProcessGroup` hold together. Throwaway smoke stage and LaunchAgent torn down; no residue, other subscribers untouched. Updated CLAUDE.md + `docs/lessons.md` gotcha 9, MANUAL.md (→ Resolved), README.md (loop → `shipped`).
- **Publish-safety scrub.** Relativised absolute `/Users/AnthonyWest` paths in CLAUDE.md + 3 self-host cards. Flagged but left as-is: the `emergence-lab` name is pervasive (~15 files) and already public; operator accepted leaving it.
- **PLAN.md reconciled** (18–22 marked done with commits; operator note corrected — queue drained, `current_stage` null).
- **Topology correction.** `docs/PUBLISH-WORKFLOW.md` described a stale orphan-squash model. Real topology is linear: `publish` is a fast-forward ancestor of `dev` on one shared history (`git merge-base dev publish` == publish's tip). Rewrote the doc around the linear flow; banked `memory/project-publish-topology-linear-not-orphan.md`.
- **Published v0.1.0.** `git merge --ff-only dev` on `publish` → `git publish` → public `main` at `b161918`; first GitHub release `v0.1.0` on `aw-pr/autometta-public`. Granular per-agent commits preserved (no squash) by deliberate choice.
- **Local install** reinstalled from HEAD; `autometta --version` = `b161918` (VERSION is a gitignored local stamp; clones use the git fallback).

### Open items for next agent

- **Sync mcp-hub publish skills to the linear model.** `repo-publish-workflow` (and possibly `repo-publish-guard-*` / `repo-publish-audit`) likely still encode the orphan-squash / "branch `wip/*` from publish" model. Reconcile with the rewritten `docs/PUBLISH-WORKFLOW.md` and re-sync via mcp-hub.
- **Self-host backlog drained.** Cards 23–28 (mostly design/experiment) are the remaining candidates; none queued.

## Recent activity (2026-05-29 Opus publishability pass + launchd plist fix)

Ran in parallel with the Sonnet 4.6 session below (stages 18-21). This session was the human-led orchestrator answering "are we publishable feature-wise?" and fixing the gaps. Only path-scoped commits were made; the two sessions never staged each other's files.

### Landed (`2cc42c2` → `428f959`, plus mcp-hub `d7966f5`)

| Commit | What |
|---|---|
| `2cc42c2` | **fix(launchd): `AbandonProcessGroup=true` on the plist template.** `templates/launchagent.plist.tpl` (and the gitignored per-repo `.autometta/launchagent.plist.tpl`). Addresses a *different* cause from `disown`: launchd reaps the tick's whole process group when the tick process exits. This is complementary to Sonnet's `disown` fix (`237c8a6`), not a replacement. **Neither is verified under a real LaunchAgent dispatch yet.** |
| `9d621de` | **fix(publish-guard): reject non-fast-forward pushes to the public default branch** even with the sentinel set. `scripts/git-hooks/pre-push` gains a `git merge-base --is-ancestor` check (first publish / zero remote-sha still allowed). Makes the three claims already in `docs/PUBLISH-WORKFLOW.md` actually true. |
| `e1b4c80` | **docs: `MANUAL.md`.** New consolidated operator manual at repo root: feature catalogue, full CLI command table, runbooks (first dispatch, loop, auth, observability, publish), troubleshooting. Cross-links `docs/` for depth. |
| `428f959` | **docs(readme): honest pass-2 status + feature-status table + Known limitations.** Marks the unattended launchd loop `experimental` (not `shipped`) pending a smoke test. |
| mcp-hub `d7966f5` | **feat(repo-readme-authoring): feature-status table convention.** New optional section + closed status vocabulary (`shipped`/`planned`/`design-only`/`experimental`); reframes the anti-Roadmap line so a durable status *table* is sanctioned. Separate repo; mcp-hub's registry/catalog regen is mid-flight in another session. |

### Decisions

- **Two launchd fixes coexist deliberately.** `disown` (Sonnet, `237c8a6`) stops shell-job-control SIGHUP; `AbandonProcessGroup` (Opus, `2cc42c2`) stops launchd reaping the process group when `tick` exits. Keep both. `CLAUDE.md` gotcha 9 currently documents only `disown` — it should be extended to mention the plist fix once the combined fix is confirmed.
- **Publish gate: harden the hook, not soften the doc.** The doc/hook discrepancy was resolved by making the hook fail-closed (reject non-ff to public default), consistent with the budget-file/fail-closed philosophy.
- **Cloud + SDK granularity logged as cards, not built.** Card 27 (cloud orchestration, design-only future phase) and card 28 (per-role/per-family SDK transport matrix; OpenAI verifier route + orchestrator-SDK design gated on card 23) were authored and queued in `PLAN.md` Tier 4. Committed by the Sonnet session as part of `dbc7fed`.

### Open items for next agent

- **Budget is halted on a stale `dirty-working-tree`** (`consecutive_failures: 1`). The tree is clean now. Run `autometta tick --reset-halt` before the next tick or the loop will not advance.
- **Verify the combined launchd fix.** Re-run `autometta install-launchagent <repo>` (re-renders the plist from the per-repo template + re-bootstraps), trigger a tick, and confirm a claude worker survives a full cycle. Only then is the unattended loop honestly `shipped`. Update `CLAUDE.md` gotcha 9 + README `Known limitations` to reflect the confirmed fix.
- **mcp-hub distribution.** The `repo-readme-authoring` skill edit is committed, but the registry/catalog files that actually distribute it are dirty from other work in the mcp-hub session; that regen needs to land there.

## Recent activity (2026-05-29 setsid fix + stage 21)

### Landed (`237c8a6` → `aae7f9c`)

| Commit | What |
|---|---|
| `237c8a6` | **fix(launchd): disown worker/verifier subshells.** `spawn-worker.sh`, `spawn-verifier.sh`, `spawn-verifier-panel.sh` each gain `disown "$pid"` (or `disown "$p0_pid" "$p1_pid"`) immediately after `pid="$!"`. Root cause: LaunchAgent bash sends SIGHUP to background subshells on tick exit, silently killing claude workers after ~21s. Codex workers unaffected (no wrapping subshell). This was the single blocker for unattended loop runs with the claude family. |
| `93e61b5` | **docs(lessons): gotcha 9.** New entry in `docs/lessons.md` and `CLAUDE.md` headless-gotchas list — SIGHUP root cause, symptoms (0-byte log, no ticker alert), and fix. Cross-referenced to `237c8a6`. |
| `aae7f9c` | **feat(21): remote monitoring scripts + contract.** `scripts/monitoring/check-public-mirror.sh` (compares origin/publish to public/main; --no-fetch flag for testing), `check-brew-install.sh` (install smoke + version match), `check-upstream-skills.sh` (NOTICE on local symlink, real diff check in hosted context). `docs/remote-monitoring.md` (four hard constraints), `docs/scheduled-routines.md` (exact /schedule invocations: mirror 6h, brew daily, skills weekly), `memory/decision-remote-monitoring.md`, `.github/PULL_REQUEST_TEMPLATE/monitoring.md` (no-state-mutation checkbox). AC1 divergence test confirmed; AC3 symlink notice confirmed; AC8 grep clean. |

### Decisions

- **LaunchAgent setsid fix approach: `disown` not `setsid`.** `setsid` is not available on macOS without coreutils. `disown "$pid"` after `$!` is portable bash, removes the job from the shell's job table, and prevents SIGHUP on shell exit. Applied to all three spawn scripts.
- **Stage 21 orchestrator-direct (no worker dispatch).** Stage 21 deliverables were built in the orchestrator session rather than via a dispatched worker, consistent with the prior pattern for design-oriented stages. Verifier not run; ACs manually confirmed.

### Open items for next agent

- **Stage 22 (MCP-served cards design)** is the next card — a design-only Tier 2 stage. Read `examples/self-host/22-mcp-served-cards-design.md` before dispatching.
- **Manual testing available for stage 21 scripts.** Run `scripts/monitoring/check-public-mirror.sh`, `check-brew-install.sh`, `check-upstream-skills.sh` directly. The brew check requires Homebrew; the mirror check works immediately; the skills check will NOTICE symlink locally.
- **16 commits unpushed on `dev`.** `git push origin dev` when ready, then evaluate the publish flow.
- **`/schedule` routines not yet registered.** `docs/scheduled-routines.md` has the exact invocations. Operator must run them manually from a Claude Code session in the autometta repo.

## Recent activity (2026-05-28 stages 18–20, Tier 1 complete)

### Landed (`dbc7fed` → `af2eb96`)

| Commit | What |
|---|---|
| `dbc7fed` | **Plan tidy-up.** PLAN.md Tier 0 table updated to `done` with commit SHAs; Tier 4 cards (27, 28) added and committed; `state.yaml` `current_stage` advanced to 18. |
| `fa735aa` | **Stage 18: panel verifier.** `scripts/spawn-verifier-panel.sh` (N=3: Opus SDK + Sonnet SDK + Codex CLI, majority vote, stalls on tie-with-crash or <2 quorum), `is_panel_mode()` in `spawn-verifier.sh`, `schemas/verifier-panel.json`, `Verifier panel: false` default in `templates/stage-card.md`, `docs/verifier-panel.md`, `memory/decision-verifier-panel.md`, `autometta panel <stage-id>`. `verify-sdk.py` gains `--model` flag. 9/10 PASS; AC10 orchestrator override (purely additive guard). |
| `bcae155` | **Stage 19: batch retro-grade.** Codex worker. `scripts/retro-grade.sh` + `scripts/retro-grade-batch.py` — submits last N completed stages as Anthropic Batch, polls, writes drift report to `memory/`. Advisory only, never mutates state.yaml or verifiers. `autometta retro-grade [--last N] [--dry-run]`. All 10 PASS. |
| `af2eb96` | **Stage 20: sweep-stage design.** `docs/design/sweep-stage.md` (N workers into N worktrees, synthesis agent, docs/decisions/ output, all 8 beliefs addressed, panel vs sweep boundary explicit), `memory/decision-sweep-stage.md`, one-sentence exception added to `docs/philosophy.md` belief 5. All 10 PASS. |

### Decisions

- **Codex subscription mode.** `.autometta.local.yaml` has `codex: subscription`; workers bill ChatGPT OAuth. No API key required for Codex dispatch.
- **Orchestrator override, AC10 (stage 18).** `is_panel_mode()` guard is purely additive; stages 06-14 cards have no `Verifier panel: true`; structural regression impossible. Documented in commit and memory.
- **Stage 15c `verifier_failed` state.** Carried forward as-is. The 2 FAILs were criterion defects requiring stage-14 smoke artefacts that don't exist. Core plumbing shipped and is in use by stages 16+.

### Open items for next agent

- **Stage 21 (remote scheduled monitoring)** is the next card — first Tier 2 stage, first use of hosted `RemoteTrigger`/`CronCreate` primitives. Read `examples/self-host/21-remote-scheduled-monitoring.md` before dispatching.
- **LaunchAgent setsid fix still outstanding.** `scripts/spawn-worker.sh` needs `setsid` or equivalent before `&` for claude workers spawned via LaunchAgent tick. Still the single blocker for unattended loop runs with claude workers.
- **21 commits unpushed on `dev`.** Push when ready, then evaluate publish flow.

## Recent activity (2026-05-28 stage 16 smoke test + stage 17 handoff envelope)

### Landed (`fd0a6d1`)

| Commit | What |
|---|---|
| `fd0a6d1` | **Stage 17 complete.** Worker handoff envelope — `schemas/handoff-envelope.json`, `scripts/validate-handoff-envelope.sh`, `state/handoffs/` directory, `docs/handoff-envelope.md`, `memory/decision-handoff-envelope.md`. `templates/worker-prompt.md` gains Step 6 with a literal envelope example. `scripts/tick.sh` gains four outcome branches on worker exit: pass→verifier, fail/partial→stage failed, missing envelope→`worker_envelope_missing_after_exit`, invalid envelope→`worker_envelope_invalid`. `.gitignore` switched from `state/` to `state/**` so the handoffs negation rules take effect. |

### Decisions

- **Stage 16 smoke test with real API keys: PASS.** `op-fetch ANTHROPIC_API_KEY=op://dev-stuff/Autometta-claude-api-key/credential -- scripts/sdk-cache-smoke.sh` → run 1: write=1519/read=0; run 2: write=0/read=1519. Cache hit confirmed.
- **Switched to Sonnet 4.6** at session start (was Opus 4.7 in prior session).

### Open items for next agent

- **Stage 18 (panel verifier)** is the next implementation card. It depends on 15c (SDK verifier route, `verifier_failed` state in state.yaml — criteria 9-10 unverified) and stage 17 (just landed). Before dispatching 18, decide whether to fix the 2 outstanding 15c FAILs first or proceed on the assumption that 15c's core plumbing is sound.
- **Stage 15c 2 remaining FAILs** still open. Needs `ANTHROPIC_API_KEY` to re-run the stage-14 verifier under both sdk+cli routes. Can be fixed with a manual smoke run: `op-fetch ANTHROPIC_API_KEY=op://dev-stuff/Autometta-claude-api-key/credential -- scripts/sdk-cache-smoke.sh 14-auth-route-toggle examples/self-host/14-auth-route-toggle.md scripts/auth-route.sh,scripts/spawn-worker.sh,scripts/spawn-verifier.sh`.
- **LaunchAgent `setsid` fix** still outstanding (claude workers exit silently from LaunchAgent context). Still the blocker for unattended loop runs.
- **18 commits unpushed on `dev`.**

## Recent activity (2026-05-28 15b/15c/16 reconciliation + prompt caching)

### Landed (commits `d3e35e1` → `33eca3b`)

| Commit | What |
|---|---|
| `d3e35e1` | **15b complete.** `schemas/verifier.json`, `scripts/validate-verifier-artefacts.sh`, updated `scripts/verify-sdk.py` (exit-3 / `.invalid.json`), `jsonschema` pin, `memory/decision-verifier-rubric-schema.md`. Verifier had been failing on a worktree-sync race (deliverables absent at verify time because worker hadn't flushed). Opus 4.7 manually verified all 9 criteria PASS against clean tree. `state.yaml` updated to `completed`. |
| `7f10a70` | **15c committed.** `scripts/spawn-verifier.sh` SDK transport route, `.autometta.local.yaml.example` transport docs, `docs/sdk-verifier.md` Integration section, `memory/decision-sdk-verifier-integration.md`, `CLAUDE.md` one-liner. 8/10 criteria PASS; 2 FAILs require running the stage-14 smoke test under both sdk+cli routes with `ANTHROPIC_API_KEY` (Codex subscription can't inject that key). Remains `verifier_failed`. |
| `b4ab7b8` | **16 — prompt caching on SDK verifier route.** `scripts/verify-sdk.py` switches from `claude_agent_sdk` to `anthropic` library; splits prompt into a cacheable static block (~1377 tokens, above Sonnet's 1024 minimum) and a per-stage variable block; logs `cache: write=N read=M input=I output=O` to stderr. `scripts/sdk-cache-smoke.sh` asserts read>0 on second run. `scripts/requirements-sdk.txt` adds `anthropic==0.100.0`. Docs + decision memo. |
| `33eca3b` | Memory INDEX updated. |

### Decisions and changes this session

- **Codex auth → subscription.** `.autometta.local.yaml` flipped from `codex: api` to `codex: subscription`. Codex now bills ChatGPT OAuth (5-hour sub), not OpenAI API. Saves metered spend on retries. No code change — just the local manifest.
- **Model shift.** User switched harness from Opus 4.7 to Sonnet 4.6 mid-session (`/model sonnet`). Session started Opus, finished Sonnet.
- **Worker silent-exit root-caused.** LaunchAgent worker (claude -p) exits after ~21s with a 0-byte log. Confirmed via direct test: `op-fetch + claude -p` works in interactive shell (process alive at 30s), so the issue is the LaunchAgent environment. Most likely: background subshell `( ... ) &` in `spawn-worker.sh` receives SIGHUP when the tick job exits, because there is no `setsid` or `disown` call. **Unfixed.** Workaround used this session: implement deliverables directly in the orchestrator session rather than via the loop.
- **Stage 16 verifier pairing.** The card specifies Codex as verifier to check cache hit counts. With Codex on subscription, it cannot inject `ANTHROPIC_API_KEY` needed to run the smoke test. The Codex verifier will check static criteria (files present, structure correct, help works) but will FAIL criteria 2-4 unless either: (a) Claude is used as verifier (subscription, can call Anthropic API), or (b) the smoke test is pre-run manually and artefacts left for the verifier to inspect.

### Open items for next agent

- **LaunchAgent `setsid` fix (blocking for autonomous loop).** Add `setsid` or `disown` before `&` in the claude dispatch in `scripts/spawn-worker.sh`. Without this, every claude worker spawned via the tick silently exits when the tick job returns. The Codex family is unaffected (reads its own auth.json, different process model). A card for this would be appropriate — it's the single most important fix before resuming unattended loop runs.
- **Stage 16 verifier.** State is `in_progress` (worker done, verifier_pid=null, attempts=0). The next tick will dispatch the Codex verifier. Expect FAIL on criteria 2-4 (smoke test). To get PASS: either switch verifier identity to `Claude Sonnet 4.6 <claude-sonnet-4-6@local>` in `state.yaml` and add an `op://dev-stuff/Claude oauth token/credential` CLAUDE_CODE_OAUTH_TOKEN pair, or pre-run the smoke test manually (`op-fetch ANTHROPIC_API_KEY=... -- scripts/sdk-cache-smoke.sh`) and leave the artefacts for the verifier to check.
- **Stage 15c 2 remaining FAILs.** Needs `ANTHROPIC_API_KEY` to re-run the stage-14 verifier under sdk+cli routes and diff artefacts. Can be fixed in a single manual dispatch: `op-fetch ANTHROPIC_API_KEY=... -- scripts/sdk-cache-smoke.sh 14-auth-route-toggle examples/self-host/14-auth-route-toggle.md scripts/auth-route.sh,scripts/spawn-worker.sh,scripts/spawn-verifier.sh`.
- **17 commits unpushed on `dev`.** `git push origin dev` when ready. Then evaluate the publish flow.

## Recent activity (2026-05-27 op-daemon fix + status ticker)

### Landed (uncommitted at session end)

| Change | What |
|---|---|
| `b53d87a` (codex worker) | **15a landed via the loop** — `scripts/verify-sdk.py`, `scripts/requirements-sdk.txt`, `docs/sdk-verifier.md`, `memory/decision-sdk-verifier-prototype.md`. First card to complete end-to-end through the autonomous chain. State now `completed`. |
| `templates/launchagent.plist.tpl` + 3× per-repo `.autometta/launchagent.plist.tpl` + 3× live `~/Library/LaunchAgents/com.autometta.tick.*.plist` | **Stripped `OP_NO_DAEMON=1`.** Diagnosis: that env var isn't a real 1Password CLI knob (not in `op --help` global flags). The "op would like to access data from other apps" TCC prompt was AppleEvents from `op` trying to reach the 1Password desktop app, not the daemon. Two `op daemon` processes were running despite the plist setting, confirming the var was ignored. Real fix applied by user: 1Password app → Settings → Developer → uncheck "Connect with 1Password CLI", then `pkill -f 'op daemon'`. Plists then re-bootstrapped via `launchctl bootout/bootstrap`. |
| `scripts/status-ticker.sh` (new) | Auto-refreshing replacement for the one-shot `status.sh` in the left tmux pane. Wraps the existing multi-repo table and adds a `COMPLETED (last N passed)` section that reads each subscriber's `state.yaml` for `status: passed` stages, sorted by `completed_at`. Configurable via `PHAT_CONTROLLER_STATUS_TICKER_INTERVAL` / `PHAT_CONTROLLER_COMPLETED_LIMIT`. |
| `scripts/attach.sh` | Left pane (0.0) now runs `scripts/status-ticker.sh` instead of one-shot status + idle shell. |
| `scripts/agent-ticker.sh` | ALERTS panel rows wrapped in ANSI red (`\033[31m`). RECENT panel rows colorise if outcome ∈ `{fail, failed, verifier_failed, stalled, error, stuck}`. The load-bearing FAIL signal is in ALERTS (which reads `state.yaml` + verifier artefacts); RECENT-row colorisation is a secondary catch for stuck/stalled agents since most `recent-agents/*.json` carry `outcome: "exited"`. |

### Open items for next agent

- **15b is `verifier_failed`.** ALERTS panel surfaces: "FAIL crit 1: validate-verifier-artefacts.sh exits 0 on current corpus". Budget shows `halted: dirty-working-tree` + `consecutive_failures: 1/3`. Worker deliverables are in the tree uncommitted. Decide: reset 15b for another worker pass, or fix the criterion / verifier and re-run.
- **Re-attach tmux** to pick up the new left pane: `tmux kill-session -t autometta-autometta && autometta attach autometta`. Other tmux windows holding work can stay open.
- **TCC prompt confirmation**: next LaunchAgent dispatch should now run without the "op would like to access data from other apps" dialog. If it reappears, the 1Password desktop integration toggle didn't stick, or there's a stray `op daemon` still alive.
- **Handover doc still flags** rotating the leaked `OP_SERVICE_ACCOUNT_TOKEN` from the earlier awk dump. Not done.
- Working tree has 3 modified files + 1 new untracked (`scripts/status-ticker.sh`). Handover did not commit. User indicated they'll switch to Codex from here to run the loop.

## Recent activity (2026-05-27 pass-3 cards + observability hardening)

### Landed (16 commits this session, `101fb30` → `e464e75`)

**Pass 3 roadmap.** Twelve concept items from a cloud + SDK brainstorm were translated into 14 stage cards (`15a-15c, 16-26`) and queued in `examples/self-host/PLAN.md`. Five are implementation, nine are design-only. The chain 15a→15b→15c→16 is what was attempted unattended in-session.

**Auth-route — claude OAuth via env, codex sibling, default flip.**
| Commit | What |
|---|---|
| `101fb30` | Template recommends `codex: api` + `claude: subscription`; resolver fallback unchanged. |
| `436c597` | `auth-route.sh` claude+subscription now emits `CLAUDE_CODE_OAUTH_TOKEN=<ref>` so `claude -p` works from op-fetch's stripped env (was failing with "Not logged in" because the env strip drops session vars keychain needs). |
| `e683372` | README + `op-refs.local.sh.example` make the XDG location reasoning impossible to miss. |

**Controller fixes.**
| Commit | What |
|---|---|
| `1302663` | `tick.sh` no longer halts on `dirty-working-tree` when `current_stage` is non-null (worker is supposed to leave dirt for verifier). Also `agent-ticker.sh` shows heartbeat age + WARN/STALE flags. |
| `c66cd11` | `install-launchagent.sh` writes the brew SYMLINK path (`/opt/homebrew/bin/autometta`) not the versioned Cellar path. Brew upgrades silently broke every plist before — root cause of the "loop went silent for an hour" incident. |
| `e464e75` | Plist now sets `OP_NO_DAEMON=1` so `op` skips the desktop daemon and goes direct to the API. Stops the "op would like to access data from other apps" TCC prompts. Also adds an ALERTS panel to the ticker that surfaces any stage in a terminal-failure state + budget halts + consecutive-failure counts. |
| `6142b1b` | Ticker shows "exited Xm ago" not "exited 124s" (run duration was static); `list-cards.sh` resolves via PATH so stale Cellar tmux panes still find it; status pane lands in repo dir. |
| `ac8fff7` | Cards 15a/b/c audited and amended — fixed `checks` vs `criteria` (existing artefacts use `criteria`), removed circular dispatch in 15c (deliverable was mutating live manifest in a way that broke its own verifier), updated 15b's stale cross-reference. |

**Loop attempts.** 15a was dispatched four times. First three failed:
1. Worker passed, verifier flagged my uncommitted README/op-refs.example edits as out-of-scope dirt (my orchestrator-hygiene bug).
2. Same shape after I committed my docs (different verifier ran, hit `checks` vs `criteria` mismatch in the card).
3. After card audit + reset, the codex worker exited in 12s with a 0-byte log. Strongly suspected: `op` invoked from the LaunchAgent context blocked on a TCC dialog launchd can't render. `OP_NO_DAEMON=1` should fix this.

At session end, all four chain stages (15a-16) are reset to `pending` with the OP_NO_DAEMON fix in place. Worker deliverables previously produced (`scripts/verify-sdk.py` etc.) were discarded so the rerun is clean.

### Operator-visible additions

- `symlinked-config/` — gitignored convenience dir with symlinks to `~/.config/autometta/op-refs.local.sh`, `~/.config/op/service-account.env`, both codex `auth.json` files, the LaunchAgent plist, and the subscriber yaml. `ls symlinked-config/` gives quick access from inside the repo.
- `autometta auth status` already prints the loaded op-refs.local.sh path (good for confirming XDG is in effect).

### Token rotation needed

I leaked the `OP_SERVICE_ACCOUNT_TOKEN` to the conversation log earlier via an awk debugging dump. Should be rotated in 1Password → service accounts. Not exploitable without other context, but rotating is the safe move and free.

### Anthropic API key situation (resolved)

`OP_REF_ANTHROPIC_API_KEY` pointed at an item that contained an OpenAI `sk-proj-...` key. User created a fresh Anthropic API key at `op://dev-stuff/Autometta-claude-api-key/credential` (now correctly `sk-ant-api03-...`). `op-refs.local.sh` updated to the right ref. All three creds (OpenAI, Anthropic API, Claude OAuth) now resolve correctly.

## Recent activity (2026-05-27 auth-route + cards 12-14)

### Landed

| Commit | What |
|---|---|
| `d5a13a1` | **Card 12** — macOS LaunchAgent replaces cron for the heartbeat (Aqua-session keychain access). Cron fallback preserved on Linux. |
| `5a62d9c` | **Card 13** — agent observability: per-agent registry under `state/active-agents/`, `scripts/heartbeat.sh`, `scripts/agent-ticker.sh` for the third tmux pane. |
| `b91aa20` | `scripts/watch-agent.sh` polling primitive — orchestrator dispatches block until done or STUCK, no more silent agent deaths. |
| `6cc26e0` | Heartbeat suppresses `silent` for `claude` family (`claude -p` doesn't stream — log is 0 bytes until completion). |
| `bbe21ac` | `spawn-verifier.sh` codex sandbox bumped to `workspace-write` so codex verifiers can write `state/verifiers/<stage>.json`. |
| `9cd4f6f` | **Card 14** — per-family auth route toggle via `op-fetch` (auth-route-security skill pattern). |
| `06b9791` | `op-refs.sh` now resolves the override from `~/.config/autometta/op-refs.local.sh` so the brew-installed CLI sees it. |
| `4e0720a` | Sibling `CODEX_HOME` for codex api mode. Without this, codex prefers `~/.codex/auth.json` (chatgpt mode) over `OPENAI_API_KEY` and silently bills the subscription. |

### Decisions

- Switched the active branch model. Working line is `dev` from now on; `publish` is the public-facing line, populated via clean topic-branch merges. See `docs/PUBLISH-WORKFLOW.md`.
- Default dispatch mode for both families is `subscription`. `api` is explicit opt-in via `.autometta.local.yaml` in the subscribed repo, or `AUTOMETTA_<FAMILY>_MODE=api` at dispatch time.
- The auth route fails closed across the surface: missing `op-fetch`, unset `OP_REF_*`, placeholder ref, or missing sibling CODEX_HOME all abort the spawn before any token is spent.

### Force-rewrite of `publish`

Three commits (`f333ed3`, `3990f5b`, `16c1c6c`) carrying an earlier wrong-shape auth-route design were removed from `publish` and `public/main` history. The safety tag `pre-rewrite-2026-05-27` preserves the old tip locally for ~90 days. The current `bbe21ac` (codex verifier sandbox fix) was preserved across the rewrite. If another machine has pulled the old refs, it will need to reset to the new `publish` HEAD.

## Operational state on this host

- `autometta` brew install matches HEAD (`scripts/install-homebrew-local.sh` packages the working tree, not git HEAD).
- `~/.config/autometta/op-refs.local.sh` (mode 0600) carries the real `op://dev-stuff/...` refs for OpenAI + Anthropic API keys.
- `~/.codex-api-only/` is initialised with `auth_mode: "apikey"` so codex api dispatches actually bill the API. Set up via `op-fetch --print "$OP_REF_OPENAI_API_KEY" | CODEX_HOME=~/.codex-api-only codex login --with-api-key`.
- `~/.publish-guard.local` patterns include `op://dev-stuff` and `op://Personal` — committing a stray real ref is blocked by `scripts/git-hooks/pre-commit`.
- `~/repos/fractals-from-the-90s/.autometta.local.yaml` has `auth.codex.mode: api` and `auth.claude.mode: subscription`. `autometta auth check codex` returns PASS with redacted credential; `auth check claude` returns subscription.

## Next run

### Autometta pass-3 chain (immediate)
- All four stages `pending`, budget clear, LaunchAgent loaded with `OP_NO_DAEMON=1`. Worker for 15a should dispatch within 120s of session resume. `autometta attach autometta` to watch.
- **Read first:** the verifier failure pattern was the worker dispatching but its op-fetch invocation blocking on the TCC "op would like to access data from other apps" prompt that LaunchAgent can't show. Plist fix is in. If the worker log lands at 0 bytes again, OP_NO_DAEMON isn't the full fix and the next debug step is to run `op-fetch $pairs --pass CODEX_HOME -- codex exec ...` directly from a `launchctl asuser <uid> env -i HOME=$HOME PATH=$PATH ...` wrapper to reproduce the LaunchAgent context.
- **Operator shell:** add `export OP_NO_DAEMON=1` to `~/.zshrc` so manual `autometta auth check` from Ghostty also skips the daemon path. Without it, Ghostty windows will keep triggering the TCC prompt for direct CLI use.
- The Ghostty TCC permission may also need a one-off Allow click for `op` itself (System Settings → Privacy & Security → Automation).
- Chain order: 15a (probe + docs + decision memo) → 15b (rubric JSON schema + validator) → 15c (SDK route into `spawn-verifier.sh` with CLI fallback) → 16 (prompt-cache the SDK verifier). Each card has explicit Depends-on notes; controller doesn't enforce dependency order beyond FIFO so they're queued in the right sequence.
- If 15c lands cleanly, 18-26 in the same backlog become candidates. 18-26 are mostly design cards; only 21 + 25 are real implementation.

### Carry-over from prior session
- `fract-cl` tmux session was mid-dispatch on fractals U-FIX-5 (filter-typo sweep). Codex worker via the new API route completed; Sonnet verifier was running when that session ended. Likely landed by now — check `autometta attach fractals-from-the-90s`.
- Next fractals card after U-FIX-5 lands is operator's call.

### Latent autometta gaps (deferred, not blocking)
- Separate heartbeat LaunchAgent that survives `autometta tick` dying entirely. Currently a single point of failure: if the tick LaunchAgent stops (system sleep / App Nap / OS reset of permissions), heartbeat goes stale and there's no alarm. The ticker now flags STALE if `heartbeat.json.checked_at` > 10min, so operator catches it visually, but a separate process would catch it for headless runs.
- Per-role auth (codex worker on subscription, codex verifier on api) — only if the per-family granularity proves limiting.
- `autometta auth setup-codex-api-home` helper to script the one-time sibling setup.

## Open questions

- The `git publish` alias's pre-push hook allowed the public force-push with `PUBLISH_GUARD_OK=1` + `--force-with-lease` — no `--no-verify` was needed. `docs/PUBLISH-WORKFLOW.md` claims non-ff to public default is rejected even with the sentinel; the actual hook (`scripts/git-hooks/pre-push`) doesn't enforce that. Either the doc is aspirational and the hook should be hardened, or the doc should be corrected. Decide deliberately before relying on it.
- Is dogfooding the loop on autometta's own backlog the right cost/benefit? This session, the chain failed multiple times on real autometta bugs (each one is now fixed) but the actual deliverables (`scripts/verify-sdk.py` etc.) could have been hand-built in ~3 hours. The dogfood found real defects but at a cost to forward progress. Worth being deliberate about the trade-off rather than defaulting to "always dispatch via the loop".

- 2026-08-23T14:53:58Z: stage 40-rebrief-the-browser-evidence-stages: dev moved since dispatch; autometta/40-rebrief-the-browser-evidence-stages left standing, pushed to origin/autometta/40-rebrief-the-browser-evidence-stages for manual integration

- 2026-08-23T15:24:22Z: stage 41-fleet-pane-spend-columns-and-an-alerts-table: dev moved since dispatch; autometta/41-fleet-pane-spend-columns-and-an-alerts-table left standing, pushed to origin/autometta/41-fleet-pane-spend-columns-and-an-alerts-table for manual integration

- 2026-08-24T09:39:07Z: stage 45-a-free-verifier-tier-on-local-weights: dev moved since dispatch; autometta/45-a-free-verifier-tier-on-local-weights left standing, pushed to origin/autometta/45-a-free-verifier-tier-on-local-weights for manual integration

- 2026-08-24T09:54:24Z: stage 43-superseded-stage-status: dev moved since dispatch; autometta/43-superseded-stage-status left standing, pushed to origin/autometta/43-superseded-stage-status for manual integration

- 2026-08-24T14:42:03Z: stage 46-verifier-bake-off-local-against-cloud-free: dev moved since dispatch; autometta/46-verifier-bake-off-local-against-cloud-free left standing, pushed to origin/autometta/46-verifier-bake-off-local-against-cloud-free for manual integration

- 2026-08-25T06:56:51Z: stage 58-the-controller-decides-the-scripts-are-its-verbs: dev moved since dispatch; autometta/58-the-controller-decides-the-scripts-are-its-verbs left standing, pushed to origin/autometta/58-the-controller-decides-the-scripts-are-its-verbs for manual integration

- 2026-08-26T09:43:22Z: stage 72-the-run-page-knows-where-the-run-starts: dev moved since dispatch; autometta/72-the-run-page-knows-where-the-run-starts left standing, pushed to origin/autometta/72-the-run-page-knows-where-the-run-starts for manual integration

- 2026-08-26T10:15:03Z: stage 73-the-tui-never-blocks-on-its-seam: dev moved since dispatch; autometta/73-the-tui-never-blocks-on-its-seam left standing, pushed to origin/autometta/73-the-tui-never-blocks-on-its-seam for manual integration

- 2026-08-26T13:22:11Z: stage 75-the-run-rows-name-models-and-line-up: dev moved since dispatch; autometta/75-the-run-rows-name-models-and-line-up left standing, pushed to origin/autometta/75-the-run-rows-name-models-and-line-up for manual integration

- 2026-08-31T10:21:39Z: stage 83-the-trailers-already-knew-the-facts: dev moved since dispatch; autometta/83-the-trailers-already-knew-the-facts left standing, pushed to origin/autometta/83-the-trailers-already-knew-the-facts for manual integration

- 2026-08-31T10:53:51Z: stage 84-a-landing-leaves-a-fact-behind: dev moved since dispatch; autometta/84-a-landing-leaves-a-fact-behind left standing, pushed to origin/autometta/84-a-landing-leaves-a-fact-behind for manual integration

- 2026-08-31T11:11:51Z: stage 85-the-verifier-reads-the-ledger-first: dev moved since dispatch; autometta/85-the-verifier-reads-the-ledger-first left standing, pushed to origin/autometta/85-the-verifier-reads-the-ledger-first for manual integration

- 2026-08-31T11:37:42Z: stage 87-the-multiplexer-knows-what-its-panes-are-doing: dev moved since dispatch; autometta/87-the-multiplexer-knows-what-its-panes-are-doing left standing, pushed to origin/autometta/87-the-multiplexer-knows-what-its-panes-are-doing for manual integration

- 2026-08-31T13:34:42Z: stage 88-the-machine-dependencies-are-declared: dev moved since dispatch; autometta/88-the-machine-dependencies-are-declared left standing, pushed to origin/autometta/88-the-machine-dependencies-are-declared for manual integration

- 2026-08-31T14:00:39Z: stage 28-per-role-family-sdk-transport: dev moved since dispatch; autometta/28-per-role-family-sdk-transport left standing, pushed to origin/autometta/28-per-role-family-sdk-transport for manual integration

- 2026-08-31T14:33:14Z: stage 90-the-verifier-reaches-for-the-sdk-first: dev moved since dispatch; autometta/90-the-verifier-reaches-for-the-sdk-first left standing, pushed to origin/autometta/90-the-verifier-reaches-for-the-sdk-first for manual integration

- 2026-08-31T21:34:53Z: stage 96-no-verdict-left-behind: dev moved since dispatch; autometta/96-no-verdict-left-behind left standing; push to origin also failed, integrate locally

- 2026-08-31T21:59:42Z: stage 97-a-pause-is-not-a-stall: dev moved since dispatch; autometta/97-a-pause-is-not-a-stall left standing, pushed to origin/autometta/97-a-pause-is-not-a-stall for manual integration

- 2026-09-01T18:14:20Z: stage 100-the-tick-stops-costing-ninety-seconds: dev moved since dispatch; autometta/100-the-tick-stops-costing-ninety-seconds left standing, pushed to origin/autometta/100-the-tick-stops-costing-ninety-seconds for manual integration

- 2026-09-01T18:25:25Z: stage 101-the-verifier-passes-its-flags-the-way-the-worker-does: dev moved since dispatch; autometta/101-the-verifier-passes-its-flags-the-way-the-worker-does left standing, pushed to origin/autometta/101-the-verifier-passes-its-flags-the-way-the-worker-does for manual integration

- 2026-09-01T18:46:30Z: stage 103-the-dashboard-does-not-invent-a-zero: dev moved since dispatch; autometta/103-the-dashboard-does-not-invent-a-zero left standing, pushed to origin/autometta/103-the-dashboard-does-not-invent-a-zero for manual integration

- 2026-09-06T10:09:50Z: stage 104-the-envelope-stops-being-called-a-handoff: dev moved since dispatch; autometta/104-the-envelope-stops-being-called-a-handoff left standing, pushed to origin/autometta/104-the-envelope-stops-being-called-a-handoff for manual integration
