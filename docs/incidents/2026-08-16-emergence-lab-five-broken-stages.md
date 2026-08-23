# 2026-08-16 — the five broken `emergence-lab` stages, one verdict each

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
| 05-math-formula-rendering | `verifier_failed` (1) | worker missed a satisfiable criterion | genuine failure — leave |
| 13-reset-all-controls-to-defaults | `stalled` (2) | worker died; verifier could not get browser evidence | re-brief the card |
| 14-fractal-colour-cycle-pacing | `verifier_failed` (1) | worker hit the `claude -p` env-strip auth defect; verifier could not get browser evidence | re-brief the card |
| 15-boids-density-motion-tuning | `verifier_failed` (1) | verifier could not get browser evidence | re-brief the card |
| 16-sandpile-larger-slower | `stalled` (3) | worker hit the `claude -p` env-strip auth defect; no verifier ever ran | tooling victim — requeued |

### 05-math-formula-rendering — genuine failure

`state/verifiers/05-math-formula-rendering.json` records six of seven criteria
PASS and criterion 6 FAIL: *"Production build gzip size impact is reported"*.
The verifier's log (`state/logs/05-math-formula-rendering-verifier.log`, 470
bytes) is explicit that this is the only gap — "the commit message does not
report the production gzip bundle-size delta and no separate handoff note
carries it".

The worker knew the number. Its own closing summary reports "~85.82 kB, above
the 80 kB soft cap, so reported" — it reported the figure to the orchestrator
and then did not put it where the card required. That is a satisfiable
criterion the worker missed, judged by a verifier that ran to completion and
wrote its artefact. Requeuing it would be using the retry cap to ask again
until the answer is yes.

### 13, 14, 15 — the verifier could not obtain the evidence the card demands

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

Two things follow. First, the work itself landed — `a0ba582`, `6af7104` and
`38b5e6d` on `dev` carry stages 13, 14 and 15 respectively, and the verifiers
read those commits when they passed every other criterion. Second, requeuing
any of them reproduces the identical FAIL, because a headless verifier seat
cannot press a button in a real browser no matter which keg it runs from. The
criterion, not the code, is what has to change. That is a card re-brief and it
needs a human decision about what evidence a headless seat may substitute, so
it is surfaced here rather than done unilaterally.

Stage 13's worker log is 0 bytes with `worker_pid: null`, so its worker died
before writing anything. Two defects fixed later that same week produce that
signature — the LaunchAgent SIGHUP kill (gotcha 9, fixed `237c8a6` +
`2cc42c2`) and the auth defect below. The log does not distinguish them.

Stage 15 also left a real design question the re-brief should settle: its
worker pinned `pointSize` at `min = max = 16`, making the slider degenerate,
and flagged that `boidsGlyphRadius()` still hard-clamps at 8. The card's
wording is genuinely ambiguous about whether 16 was a minimum or a fixed value.

### 16-sandpile-larger-slower — the one tooling victim

`state/logs/16-sandpile-larger-slower-worker.log` was 35 bytes:

```
Not logged in · Please run /login
```

That is the `claude -p` env-strip defect: `op-fetch` sanitises the environment
and drops the session variables the keychain lookup needs, so the CLI reports
itself logged out. It was fixed on 2026-05-27 in `436c597`, which makes
`auth-route.sh` emit `CLAUDE_CODE_OAUTH_TOKEN` on the claude+subscription
route — the same day the stage died, and after it.

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
running six minutes later — against an original attempt that was dead in
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
