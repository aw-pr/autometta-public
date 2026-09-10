# 2026-08-16: the five broken `emergence-lab` stages, one verdict each

Card 36 assumed the five stages sitting in `verifier_failed` or `stalled` were
victims of the two defects cards 29 and 30 describe, and that separating the
victims from the genuine failures was the first question.

It was the right question. The answer is that **none of the five is a victim of
card 29 or card 30.** Both of those defects postdate the incidents: cards 29 and
30 were reported on 2026-08-14 and 2026-08-16, and all five stages failed on
2026-05-26 and 2026-05-27. The statuses matched because `verifier_failed` and
`stalled` are the only two terminal states the loop has, not because the causes
were the same.

Three distinct causes are behind the five, and only one of them warrants a
requeue.

## The verdicts

| Stage | Status | Cause | Verdict |
|---|---|---|---|
| 05-math-formula-rendering | `verifier_failed` (1) | worker missed a satisfiable criterion | genuine failure, leave |
| 13-reset-all-controls-to-defaults | `stalled` (2) | worker died; verifier could not get browser evidence | re-brief the card |
| 14-fractal-colour-cycle-pacing | `verifier_failed` (1) | worker hit the `claude -p` env-strip auth defect; verifier could not get browser evidence | re-brief the card |
| 15-boids-density-motion-tuning | `verifier_failed` (1) | verifier could not get browser evidence | re-brief the card |
| 16-sandpile-larger-slower | `stalled` (3) | worker hit the `claude -p` env-strip auth defect; no verifier ever ran | tooling victim, requeued |

### 05-math-formula-rendering: genuine failure

`state/verifiers/05-math-formula-rendering.json` records six of seven criteria
PASS and criterion 6 FAIL: *"Production build gzip size impact is reported"*.
The verifier's log (`state/logs/05-math-formula-rendering-verifier.log`, 470
bytes) is explicit that this is the only gap, "the commit message does not
report the production gzip bundle-size delta and no separate handoff note
carries it".

The worker knew the number. Its own closing summary reports "~85.82 kB, above
the 80 kB soft cap, so reported", it reported the figure to the orchestrator
and then did not put it where the card required. That is a satisfiable
criterion the worker missed, judged by a verifier that ran to completion and
wrote its artefact. Requeuing it would be using the retry cap to ask again
until the answer is yes.

### 13, 14, 15: the verifier could not obtain the evidence the card demands

All three carry a browser-smoke acceptance criterion:

- card 13 criterion 2, *"Pressing `Reset to defaults` ... returns the UI and
  renderer to the default values"*
- card 14 criterion 5, *"Low multiplier settings no longer appear jumpy in
  browser smoke testing"*
- card 15 criterion 4, *"Browser smoke test on `/#/boids` shows a denser flock
  with faster motion and no blank canvas"*

In each case that criterion is the **only** FAIL, and in each case the verifier
says plainly that it could not get a browser rather than that the code is
wrong. From `state/verifiers/13-reset-all-controls-to-defaults.json`:

> Browser verification could not be completed: the Codex in-app browser
> reported `Browser is not available: iab`; local Google Chrome command-line
> headless launches exited without usable output; `open -na '/Applications/
> Google Chrome.app'` returned kLSNoExecutableErr. A Vite dev server did start
> at http://127.0.0.1:5173/. Because the required real-browser evidence was not
> obtained, overall is FAIL despite the static code path and npm gate looking
> correct.

Cards 14 and 15 report the same thing in their own words. Stage 15's worker
flagged it in advance: "I could not perform the browser smoke test (acceptance
criterion 4) from this environment."

Two things follow. First, the work itself landed, `a0ba582`, `6af7104` and
`38b5e6d` on `dev` carry stages 13, 14 and 15 respectively, and the verifiers
read those commits when they passed every other criterion. Second, requeuing
any of them reproduces the identical FAIL, because a headless verifier seat
cannot press a button in a real browser no matter which keg it runs from. The
criterion, not the code, is what has to change. That is a card re-brief and it
needs a human decision about what evidence a headless seat may substitute, so
it is surfaced here rather than done unilaterally.

Stage 13's worker log is 0 bytes with `worker_pid: null`, so its worker died
before writing anything. Two defects fixed later that same week produce that
signature, the LaunchAgent SIGHUP kill (gotcha 9, fixed `237c8a6` +
`2cc42c2`) and the auth defect below. The log does not distinguish them.

Stage 15 also left a real design question the re-brief should settle: its
worker pinned `pointSize` at `min = max = 16`, making the slider degenerate,
and flagged that `boidsGlyphRadius()` still hard-clamps at 8. The card's
wording is genuinely ambiguous about whether 16 was a minimum or a fixed value.

### 16-sandpile-larger-slower: the one tooling victim

`state/logs/16-sandpile-larger-slower-worker.log` was 35 bytes:

```
Not logged in · Please run /login
```

That is the `claude -p` env-strip defect: `op-fetch` sanitises the environment
and drops the session variables the keychain lookup needs, so the CLI reports
itself logged out. It was fixed on 2026-05-27 in `436c597`, which makes
`auth-route.sh` emit `CLAUDE_CODE_OAUTH_TOKEN` on the claude+subscription
route, the same day the stage died, and after it.

The worker therefore never ran. `state/logs/16-sandpile-larger-slower-verifier.log`
was 0 bytes across all three attempts, so no verifier ever recorded a verdict
either. The stage burned its whole attempt cap without a single role producing
an opinion about the code. Stage 14's worker died the same way, but a verifier
did run there and reached every criterion bar the browser one, so 14 is not in
the same position.

This is the only one of the five where a requeue produces information that does
not already exist.

## What was done

`requeue-stage.sh` was run against stage 16 through the sanctioned path:

```sh
/opt/homebrew/opt/autometta/libexec/scripts/requeue-stage.sh \
  ~/repos/emergence-lab 16-sandpile-larger-slower
```

It removed the run worktree and `autometta/16-sandpile-larger-slower` branch,
purged the verifier artefact and both per-stage logs, and reset the record to
`pending` with `verifier_attempts: 0`. No stale envelope survived to send a
verifier at unfixed code. `state.yaml` was not hand-edited.

The following tick cut a fresh worktree and dispatched a worker that was still
running six minutes later, against an original attempt that was dead in
seconds. Getting past the login refusal was the whole point.

Stage 16's card still carries a browser-smoke criterion of its own (criterion
4), so its verifier may well land in the same place as 13, 14 and 15. That is
the next thing to watch, and it is an argument for re-briefing all four
together rather than one at a time.

## The broader finding

Four of these five stages have working, committed code and are parked in a
terminal state because one acceptance criterion asks for evidence no headless
seat can produce. The dispatch loop has no way to distinguish "the code is
wrong" from "I could not look", and it spends the retry cap the same way on
both. A criterion that only a human at a screen can satisfy is not an
acceptance criterion for an autonomous loop; it is a manual gate wearing one.

## The re-brief, 2026-08-23

Card 40 carried the finding above into action: the four stages whose only FAIL
was a browser criterion have been re-briefed and requeued. Stage 05 is
untouched, for the reason given above.

### What made the re-brief possible

On 2026-08-16 there was no answer to "how should a verifier obtain browser
evidence", so a re-brief would have been guesswork about what a headless seat
may substitute. That gap closed on 2026-08-22: step 5 of
`templates/verifier-prompt.md` now requires any browser check to run fully
headless, launching the verifier's own headless Chromium against a dev server
it starts itself, and forbids attaching to the operator's Chrome (`7c7f22b`).
The instruction whose absence let each verifier conclude it could not look now
exists.

### One correction to the verdicts above

Stage 16 was recorded here as the one stage with no committed work, on the
evidence that its worker never ran and no verifier ever recorded a verdict.
Both of those remain true. The code is nonetheless committed: `8099310` on
`dev`, "16-sandpile-larger-slower: enlarge and slow default", carries the
card's deliverables 1 to 3 (`DEFAULT_INITIAL_PILE` 100000 to 300000, the
`abelian-sandpile` speed profile 4 to 0.8, and the matching kernel test). It
was committed by the orchestrator session on 2026-05-27, the same day the
stage's worker failed to start.

So all four stages have working committed code, not three:

| Stage | Commit | Criterion that failed |
|---|---|---|
| 13-reset-all-controls-to-defaults | `a0ba582` | 2, reset restores every visible control |
| 14-fractal-colour-cycle-pacing | `6af7104` | 5, low multipliers no longer jumpy |
| 15-boids-density-motion-tuning | `38b5e6d` | 4, denser flock, faster motion, no blank canvas |
| 16-sandpile-larger-slower | `8099310` | 4, larger pattern without freezing the UI (never reached) |

### What each card gained

Each browser criterion keeps its wording and gains a headless method by
reference to step 5 of `templates/verifier-prompt.md`. The rule is referenced,
never restated, so there is one copy of it to maintain rather than five.

- **13**, criterion 2: load the route in headless Chromium against a dev
  server the verifier starts itself, move a control in each affected group,
  press `Reset to defaults`, read the inputs and canvas attributes back.
- **14**, criterion 5: at the `0.5x` minimum multiplier, capture a timed burst
  of canvas screenshots on each fractal and show successive frames advance in
  small palette steps. Jumpiness is a large per-frame phase step, so a burst
  showing small steps is the evidence; an impression formed at a headed window
  never was.
- **15**, criterion 4: run the in-repo `boids` case in `e2e/smoke.spec.ts`
  (Playwright, `headless: true`, its own Vite `webServer`), which asserts a
  visible canvas, a named renderer backend, a non-zero display size and an
  advancing iteration counter, and writes a screenshot. Read the live
  `boidCount` and `maxSpeed` off the control inputs for the density and speed
  half.
- **16**, criterion 4: the same smoke case for `abelian-sandpile`. An
  advancing counter is the not-frozen half; the screenshot and the live
  `initialPile` are the pattern-size half.

`e2e/smoke.spec.ts` was the useful find. A headless harness that starts its own
server and screenshots the canvas has been in the repo the whole time; nothing
in the four cards pointed at it, so three verifiers went looking for a browser
on their own and did not find one.

### The `Requires GUI` question card 36 left open

Card 36 asked whether a codex verifier needs `Requires GUI: true` on these
cards, since a sandboxed codex role aborts at `NSApplication init` even
headless. It would. None of the four declares it, because none of them has a
codex role that touches a browser any more: the browser pass sits in the Claude
verifier seat, which is unsandboxed by nature, and the codex worker seat is
confirmation only. `Requires GUI` widens the codex sandbox and nothing else
(`resolve_codex_sandbox_for_card` in `scripts/models.sh`), so declaring it for
a Claude role grants that role nothing while reading as though it does. Cards
35, 36 and 37 in `emergence-lab` each declare it "for the Claude verifier",
which is inert. Card 55 states the current rule correctly and is the precedent
followed here.

The roles the next run uses are `GPT-5.6 Sol <gpt-5-6-sol@local>` as worker and
`Claude Opus 5 <claude-opus-5@local>` as verifier and orchestrator. The old
trio (worker `Claude Opus 4.7`, orchestrator and verifier `GPT-5.5`) is
recorded in each card's re-brief section; the commits already on `dev` keep
their authorship and were not rewritten.

### Why stage 16 stalled the second time

The 2026-08-16 requeue worked. The worker got past the login refusal that
killed attempt 1 and ran for real. It then ended its turn with a 75-byte log
reading "The benchmark is running. I'll report once it lands", having spent
2,196,052 tokens, and never wrote its handoff envelope; `state.yaml` recorded
`worker_envelope_missing_after_exit`. No tooling failed. A role that defers its
result to a measurement it is no longer running to collect stalls the stage
however much work it did, because the envelope is the loop's only completion
signal.

So this round is not the same requeue again. The worker seat changes family,
the job is confirmation only, and every card now says explicitly: do not start
anything you then wait on, run to completion, then hand off. A `partial`
envelope naming what is missing is worth more than a turn that ends waiting.

### The tree has moved, and the re-brief says so

Three months of later work sit between these stages and the tree a fresh
verifier will judge. Two of the four are affected and both cards now say so:

- **15**: `187c087` (2026-06-01) added spatial binning, raised the count
  ceiling and shrank the default glyph, restoring `pointSize` to `min: 4,
  max: 16`. That also settles the design question left open above: the stage
  worker's `min = max = 16` was a misreading, `16` was a ceiling for the glyph
  and never a fixed value, and the degenerate slider is not to be restored.
  `4f2bcf3` (2026-08-16) later set clustered flocks and a 1x default speed.
- **16**: `f44c65d` and `417776b` (both 2026-06-06) refilled the screen and put
  the default simulation speed back to 1.

Neither card re-tunes anything. Where a criterion no longer holds because later
deliberate work moved a value, the verifier records it in
`additional_findings`; that is a fact about the tree, not a licence to change
code.

### The requeues

Four runs of the sanctioned path, one per stage:

```sh
scripts/requeue-stage.sh ~/repos/emergence-lab <stage-id>
```

All four are `pending` with `verifier_attempts: 0`, no handoff envelope, no
verifier artefact, no run worktree and no `autometta/*` branch. `state.yaml`
was not hand-edited. `emergence-lab` remains paused until 22:05 for the card 57
sweep (`paused_until` is untouched by `requeue-stage.sh`) and nothing was
dispatched into it. The archived `.log.gz` files for stages 13 to 15 are left
in place: they are the evidence this document cites, and the tick reads only
the uncompressed `<stage>-worker.log` / `<stage>-verifier.log` paths, which are
gone.

### One thing the re-brief could not fix

`scripts/add-stage.sh` captures a card's worker and verifier identities into
`state/state.yaml` once, when the stage is added, and nothing refreshes them.
`spawn-worker.sh` and `spawn-verifier.sh` re-read the card at dispatch time, so
a re-brief that changes the roles does dispatch the new ones. `tick.sh` reads
`state.yaml` for the commit author and for the cost-log tier, so it will
attribute the resulting commit to `Claude Opus 4.7 <claude-opus-4-7@local>` and
bill a codex worker at the old rate. All four stages currently carry that stale
pair. Correcting it needs either a hand edit of `state.yaml`, which the
re-queue skill rules out, or a change to `requeue-stage.sh` to re-read the card,
which is outside card 40. It is left for the operator.
