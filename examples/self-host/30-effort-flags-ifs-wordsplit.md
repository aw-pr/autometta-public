# Stage card 30-effort-flags-ifs-wordsplit: effort flags reach the CLI as one argv element

## Metadata

- **Authored:** 2026-08-14
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** <<worker-identity>>
- **Verifier:** <<verifier-identity>>
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** <<fill at dispatch — cross-family. Note the irony that
  the Metadata effort fields on this very card are the ones that do not
  currently work.>>

## Objective

`effort_flags_for_family` emits a two-token flag string, but both spawn scripts
set `IFS=$'\n\t'` — no space — so the unquoted expansion never word-splits. The
CLI receives `--effort high` as a single argument and rejects it.

Make effort flags arrive as separate argv elements.

## Reported by

Observed on 2026-08-14 in `emergence-lab` (worktree `../emergence-lab-gpu`),
dispatching a Claude Opus 5 verifier for stage
`34-logistic-mandelbrot-fp32-spike`. The entire verifier log was one line:

```
error: unknown option '--effort high'
```

Note the shell quoting in the error: the CLI is reporting one unknown option
whose name contains a space, not an unknown `--effort` flag. `claude --help` on
2.1.232 does list `--effort <level>`; the flag is supported and correctly
spelled. Only its delivery is wrong.

The dispatch died in well under a second and left a 38-byte log. Each attempt
burns one of the three `verifier_attempt_cap` retries (`scripts/tick.sh:953`),
so a stage with a Claude verifier and any `Verifier effort` set will exhaust
its attempts and be marked `stalled` without a single verifier ever running.

## The mechanism, already isolated

`scripts/models.sh:33-49`:

```sh
case "$family" in
  claude) printf -- '--effort %s\n' "$effort" ;;
  codex)  printf -- '-c model_reasoning_effort=%s\n' "$effort" ;;
esac
```

Both spawn scripts set `IFS=$'\n\t'` on line 3, then expand `$effort_flags`
unquoted (`scripts/spawn-worker.sh:185-187`, `scripts/spawn-verifier.sh:348`),
with `# shellcheck disable=SC2086` marking the split as intentional. The split
is intentional but does not happen: word splitting uses `IFS`, and `IFS` has no
space in it. Reproduce directly:

```sh
$ bash -c 'IFS=$'"'"'\n\t'"'"'; f="--effort high"; printf "[%s]\n" $f'
[--effort high]
```

One element, not two.

The codex path has the same defect — `-c model_reasoning_effort=high` is also
delivered as one argument. It has been less visible because codex appears to
tolerate it rather than erroring. **Check whether codex is honouring the effort
level or silently discarding it**; if the latter, every codex dispatch since
the effort feature landed has run at default effort while its card and logs
claimed otherwise. `spawn-worker.sh:131-133` logs `worker effort: high` from
the card, not from what the CLI accepted, so the log is not evidence either
way. This is potentially a larger finding than the crash.

## Inputs (read these in your own context)

- scripts/models.sh — `effort_flags_for_family` and `AUTOMETTA_EFFORT_LEVELS`
- scripts/spawn-worker.sh — line 3 (`IFS`), 125-140, 180-195
- scripts/spawn-verifier.sh — line 3 (`IFS`), 225-245, 340-355
- scripts/tick.sh — 950-975, the verifier attempt cap and retry accounting
- templates/stage-card.md — the `Worker effort` / `Verifier effort` fields

## Deliverables

1. A fix that delivers effort flags as distinct argv elements for both
   families and both spawn scripts. Prefer a bash array over relying on word
   splitting — `IFS` is set deliberately at the top of these scripts and
   should not be weakened for one expansion. An array is explicit and cannot
   silently re-break if `IFS` changes again.
2. A determination on whether codex has been honouring its effort flag, with
   evidence. If it has not, say so plainly in the handoff — it changes how
   every past stage's effort setting should be read.
3. A regression test asserting both families receive two arguments, not one.
   Assert on the constructed argv, not on a successful dispatch, so the test
   does not need live CLI auth.
4. `docs/lessons.md` — add as a numbered gotcha: `IFS` without a space plus
   unquoted expansion is a silent no-op split, and `shellcheck disable=SC2086`
   documents the intent while hiding the failure.
5. Consider whether a dispatch that dies this fast should consume a
   `verifier_attempt_cap` retry at all. A sub-second exit with a CLI usage
   error is a configuration fault, not a flaky verifier, and burning the
   budget on three identical instant failures helps nobody. Out of scope to
   redesign the retry policy; in scope to note it if you agree.

## Constraints

- Do not remove `IFS=$'\n\t'` from the spawn scripts. It is there deliberately.
- Do not change the card-facing spelling of the effort fields; subscriber repos
  already use them.
- Do not paper over this by dropping effort support.
- Claude and codex must both keep working with no effort field set at all
  (the empty case returns early and must stay working).

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. The repo's own acceptance suite is green.
2. A Claude verifier dispatched from a card declaring `Verifier effort: high`
   starts and runs. Demonstrate with a real dispatch, and show the log
   contains real verifier output rather than a usage error.
3. The same for a codex role with `Worker effort: high`, and state positively
   that the effort was accepted rather than ignored.
4. The regression test fails against the pre-fix commit. Check it out, run it,
   state the failure.
5. A card with no effort fields still dispatches for both families.
6. The finding on historical codex effort handling is stated with evidence.

## Contract test

- **Test file:** `scripts/effort-flags-smoke.sh`
- **Assertions digest:** 17 assertions. Six on `effort_argv_for_family`
  directly: claude and codex each build exactly two argv elements with the
  expected values; a card with no effort and a card with an unknown level each
  build none. Eleven on argv captured from a real dispatch through
  `spawn-worker.sh` and `spawn-verifier.sh`, with a stub `op-fetch` on `PATH`
  recording what it was handed: `--effort` and `high` arrive as consecutive
  arguments and no argument named `--effort high` exists; likewise `-c` and
  `model_reasoning_effort=high` for codex; and a card declaring no effort still
  reaches the CLI for both families with no effort argument at all.

## Out of scope

- The run-worktree envelope bug — that is card
  `29-run-worktree-state-writable`. Both are dispatch-path defects found in the
  same session; keep the fixes and their tests separate.
- Redesigning the verifier retry policy.
- Anything in the subscriber repos.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Worker reports: how the argv is now constructed and why an array was or was not
used; the evidence on whether codex has been honouring effort; the regression
test's failure output against the pre-fix commit; and a view on whether an
instant CLI usage error should consume a verifier retry.

## Family-specific notes

The verifier must run at least one real dispatch of each family, so it needs
working codex and claude auth.

## Worker report

Fixed in the orchestrator session rather than dispatched, on 2026-08-14.
Commits `8a77b08` (fix plus regression test) and `0cf4231` (docs).

**How the argv is now constructed, and why an array.**
`effort_flags_for_family` prints one argv element per line — `--effort` then
`high`, `-c` then `model_reasoning_effort=high`. `effort_argv_for_family` reads
those into the global array `AUTOMETTA_EFFORT_ARGV`, and both spawn scripts
expand it as `${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"}`. A
global array is the return channel because a bash function cannot return one.

The card asked for an array over a fixed word split, and the reasoning holds up
under a detail worth stating: emitting newline-separated flags would *also*
have worked on its own, because `IFS=$'\n\t'` does contain a newline. That fix
would have been correct and invisible — it would leave the dispatch depending
on the value of a variable set 180 lines away in another file, with the
`shellcheck disable=SC2086` still there silencing the one tool that would ask
about it. The array survives any `IFS`. `IFS=$'\n\t'` is untouched, per the
constraint.

The `+alternate` guard is not decoration: `/usr/bin/env bash` resolves to bash
3.2.57 on this machine (the system bash), where `"${arr[@]}"` on an empty array
is an unbound variable under `set -u`. `spawn-verifier.sh` already used the
same idiom for `advisor_arg`, so this matches existing practice in the file.

**Whether codex has been honouring its effort flag: yes, throughout.**
This was the card's larger worry and it is a false alarm. `-c` is a short
option, clap accepts an attached value on a short option, so codex received
`-c` with the value `" model_reasoning_effort=high"` — leading space included —
and its override parser trims the key. Evidence, on codex-cli 0.147.0, with no
tokens spent:

```
$ codex debug -c model_provider=doesnotexist prompt-input
Error: Model provider `doesnotexist` not found
$ codex debug "-c model_provider=doesnotexist" prompt-input
Error: Model provider `doesnotexist` not found
$ codex debug -c " model_provider=doesnotexist" prompt-input
Error: Model provider `doesnotexist` not found
```

All three forms apply the override identically, which is the same argv shape
the pre-fix codex dispatch produced. `model_reasoning_effort` is not validated
locally, so the probe uses `model_provider`, which resolves at startup and
fails loudly — the same override mechanism, made observable. No past codex
stage needs its effort setting re-read.

A long option has no equivalent forgiveness, which is why only the claude
family crashed. That asymmetry is the whole reason one half of this bug was
loud and the other silent.

**Regression test against the pre-fix commit.** The pre-fix tree was
reconstructed with `git archive HEAD | tar -x -C <tmp>` and the new smoke
copied in:

```
== effort argv construction (card 30) ==
  FAIL: models.sh has no effort_argv_for_family — pre-fix tree, effort
        flags are emitted space-joined and collapse to one argument
effort-flags-smoke: FAIL
prefix exit=1
fixed exit=0
```

The collapse itself, reproduced against the pre-fix `models.sh` under the spawn
scripts' own `IFS`:

```
$ IFS=$'\n\t'; f="$(effort_flags_for_family claude high)"
$ set -- claude --model x $f -p prompt; printf '[%s]\n' "$@"
[claude]
[--model]
[x]
[--effort high]     <- one argument
[-p]
[prompt]
```

**Whether an instant CLI usage error should consume a verifier retry: no.**
Agreeing with the card. A sub-second exit with a 38-byte log and a usage error
on stderr is a configuration fault; the second and third attempts cannot
succeed where the first failed, and they consume the stage's only defence
against a genuinely flaky verifier. Left unchanged as out of scope — it wants
its own card, and the shape it needs is a fast-usage-error class that halts the
stage with a distinct reason rather than exhausting `verifier_attempt_cap`.

**Verification notes for the downstream agent.**

- `bash scripts/effort-flags-smoke.sh` needs no auth, no network and no spend.
  Nothing in it reaches a real CLI: `op-fetch` is stubbed on `PATH` and records
  the argv it was handed. Expect 17 PASS lines.
- Acceptance criteria 2 and 3 ask for real dispatches. The argv capture is the
  stronger evidence for *delivery* and is what the test asserts on; a live run
  additionally proves the CLI accepts the flag. For claude that was confirmed
  directly: `claude --effort bogus -p hi` returns `Warning: Unknown --effort
  value 'bogus' — ignoring it and using the default effort. Valid values: low,
  medium, high, xhigh, max.` That is the option parsing and validating, and the
  list matches `AUTOMETTA_EFFORT_LEVELS` exactly. Contrast the pre-fix
  `error: unknown option '--effort high'`.
- Existing suites re-run green: `cost-log-smoke.sh`, `advisor-order-smoke.sh`,
  `health-check.sh`. `shellcheck -x` on the three changed scripts and the new
  one reports nothing beyond the pre-existing findings.
- **The fix is not live for subscriber repos yet.** The CLI is a rendered brew
  tap; `scripts/install-homebrew-local.sh` has deliberately not been re-run, so
  an installed `autometta` still carries the collapsing expansion. Verify
  against this checkout, or re-render first.
- Known gap, not introduced here: `spawn-verifier-panel.sh` reads no effort
  field at all, so a panel card's `Verifier effort` has never had any effect.
  The sdk transport in `spawn-verifier.sh` is likewise inert on effort, which
  is already documented at the call site. Neither is in this card's scope.
