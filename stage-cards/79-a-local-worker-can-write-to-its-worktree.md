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
- ../autometta-testing/state/logs/01-stats-worker.log

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

## Re-brief, attempt 2 (2026-08-27)

Attempt 1 is preserved as `1b93f4c19d8ef3d9693f940f5e2d79794a9231ec` on
`wip/79-a-local-worker-can-write-to-its-worktree-attempt-1`. Read that commit
before writing anything. Five of six criteria passed and that work is worth
restoring; criterion 5 failed, and it failed for a reason that changes how the
rest of this card has to be approached.

### What attempt 1 concluded, and why it is wrong

It reported the root cause as codex's shell tools inheriting the subscriber
root as their operating-system cwd, and changed `scripts/spawn-worker.sh:201`
to change directory to the run worktree before invoking codex.

The verifier falsified that empirically rather than by argument. It cut a real
linked worktree, launched codex with the process cwd deliberately set to the
parent (the exact pre-fix shape), and had the model run `pwd`. The shell landed
in the run worktree, not in the inherited cwd. It repeated the probe through
`op-fetch --` to rule out the `env -i` sanitisation as a variable, with the same
result:

> Codex takes its shell workdir from `-C`; the launching process cwd is not
> consulted, so the change at `scripts/spawn-worker.sh:201` cannot be what makes
> a local worker able to write.

Treat that as established. Do not re-propose cwd inheritance.

### Why the smoke did not catch it

The verifier's second finding matters more than the first. The smoke passed
only because its codex stub asserted `pwd -P` equalled the `-C` argument, which
encodes the hypothesis rather than the observed behaviour of the CLI it stands
in for. A stub written to agree with the theory can never falsify the theory.

This constrains attempt 2: **the reproduction may not stub codex.** It must
invoke the real `codex exec --oss` against a real worktree and observe what
actually happens. It stays free because the local route costs nothing per
token; a trivial prompt is enough. If a real invocation genuinely cannot be
made to run in the smoke's context, say so in the handoff and explain what you
tried, rather than substituting a stub that asserts your own conclusion.

### Prior art the card should have cited and did not

`docs/lessons.md` gotcha 14, "the sandbox refused the one write the loop was
waiting for", documents a 2026-08-16 incident with the same shape: a run
worktree's `state/` is a symlink out of the tree, codex's `workspace-write`
makes only the `-C` root writable, codex resolves the link when it checks a
write, and the write is refused on the physical path. That was omitted from the
original card, which is an authoring error, not a worker error.

It is prior art, not the answer. Our failure was writing `calc/stats.py`, an
ordinary file inside the workdir, and the codex banner showed the state
directory explicitly among the granted roots. So gotcha 14 describes a
neighbouring failure rather than this one. Start from it, establish whether the
same resolution behaviour explains an ordinary in-workdir write, and say
plainly which parts of it do and do not transfer.

### What attempt 2 must produce

Everything the original Deliverables and Acceptance criteria ask for, unchanged,
plus:

- The reproduction invokes real codex, not a stub.
- The handoff states which hypotheses you falsified and how, not only the one
  you settled on. Attempt 1's cwd theory is already falsified; adding to that
  list is progress even if the cause is not found.
- Gotcha 14 is cited explicitly, with a sentence on what transfers and what
  does not.

If you cannot establish the root cause within budget, stop and report the
falsified list. A card that narrows the search honestly is worth more than one
that ships a fix resting on an untested hypothesis, which is exactly what
attempt 1 did and what cost it the stage.
