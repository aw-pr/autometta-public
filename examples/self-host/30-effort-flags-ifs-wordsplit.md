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

- **Test file:** <<fill at dispatch>>
- **Assertions digest:** <<fill at dispatch>>

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
