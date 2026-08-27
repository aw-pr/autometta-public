# Stage card 79: a local worker can write to its worktree

## Metadata

- **Authored:** 2026-08-27
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/79-a-local-worker-can-write-to-its-worktree
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/spawn-worker.sh, scripts/local-worktree-write-smoke.sh
- **Pairing rationale:** a cross-family investigation, not a display stage. The
  worker needs a fresh Codex window to reproduce a Codex sandbox behaviour; the
  verifier must be the family that did not form the hypothesis.

## Objective

The free local route cannot currently complete a stage. On 2026-08-27 the
first real dispatch into `autometta-testing` ran `gpt-oss:20b` as worker in the
run worktree `autometta-testing-run-01-stats`, with codex reporting

```
sandbox: workspace-write [workdir, /tmp, $TMPDIR, /Users/.../autometta-testing/state]
```

and every attempted write nevertheless failing with `Operation not permitted`.
The worker spent roughly 470K tokens discovering it could not write, produced
no deliverables and no handoff envelope, and the stage stalled. Find the cause
and make a local worker able to write its deliverables.

The sandbox mode resolved correctly (`resolve_codex_sandbox` returns
`workspace-write`, and codex echoed it), so the fault is below that. Candidate
directions, none of them confirmed, all of them cheap to falsify:

- The run worktree is a linked git worktree whose `.git` is a **file**, and
  whose real object store lives in the parent repo outside the writable roots.
- `workdir` is granted, but the model wrote via a shell whose cwd was elsewhere.
- Codex's `--oss` path applies a different sandbox profile than the API path.
- `state/` is a symlink into the parent repo (see the run-worktree state
  symlink decision), so a write through it leaves the granted root.

Do not guess. Reproduce it first, in isolation, then fix the narrowest thing
that makes the reproduction pass.

## Inputs (read these in your own context)

- scripts/spawn-worker.sh
- scripts/models.sh
- docs/lessons.md
- docs/observability.md
- /Users/AnthonyWest/repos/autometta-testing/state/logs/01-stats-worker.log

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/local-worktree-write-smoke.sh`, a smoke that cuts a real temporary
   git worktree, dispatches nothing, and asserts the exact write that failed
   now succeeds inside the sandbox roots a local dispatch is granted. It must
   fail on today's code and pass after the fix, and it must spend no tokens and
   need no network or auth.
2. Whatever change to `scripts/spawn-worker.sh` the reproduction shows to be
   necessary, and nothing wider.
3. A `docs/lessons.md` gotcha 14 recording the root cause, the evidence that
   established it, and the rule it generalises to.

## Constraints

- Do not widen the sandbox to `danger-full-access` to make the symptom go away.
  The sandbox is the role boundary (see CLAUDE.md); lifting it is a different
  card and a worse system.
- Do not modify `scripts/tick.sh` or anything under `scripts/lib`.
- The verifier route must stay outside the worker sandbox.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash scripts/local-worktree-write-smoke.sh` exits 0.
2. Reverting the `spawn-worker.sh` change makes that smoke fail, demonstrated in
   the handoff by showing the failing output.
3. `bash scripts/local-route-smoke.sh` still exits 0.
4. `bash -n` passes on every modified shell script.
5. `docs/lessons.md` gotcha 14 names the confirmed root cause and cites the
   evidence, not a hypothesis.
6. No file outside Path claims and `docs/lessons.md` is modified.

## Contract test

- **Test file:** scripts/local-worktree-write-smoke.sh
- **Assertions digest:** None

## Out of scope

- The `codex_models_manager` "missing field `models`" listing noise. It is
  non-fatal and is gotcha 13's problem, not this card's.
- Any change to which local models are usable.
- The TUI.

## Budget

- **Worker wall-clock:** 3600s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the confirmed root cause in one sentence,
the failing-then-passing smoke output, and anything you falsified along the way.

## Family-specific notes

The reproduction concerns Codex CLI sandbox behaviour, so the worker must be the
codex family. `codex exec` reads stdin after the prompt argument: redirect
`</dev/null` from any wrapping harness (gotcha 1).
