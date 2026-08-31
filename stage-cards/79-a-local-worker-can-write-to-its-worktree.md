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


## Re-brief, attempt 3 (2026-08-30)

Attempt 2 is preserved as `b163d1490e82256400716f08cff3f698f92c6857` on
`wip/79-a-local-worker-can-write-to-its-worktree-attempt-2`. Read that commit
before writing anything. Five of six criteria passed again, and this time the
work behind them is sound: the smoke stubs nothing, cuts a real linked
worktree, symlinks `state/` out of it, leaves the card only in the subscriber
checkout and dispatches real `codex exec --oss` through `spawn-worker.sh`. The
root-cause narrative correctly falsifies attempt 1's cwd theory rather than
restating it. Keep all of that. One thing failed, and it is the same criterion
that has now cost the card twice.

### What failed

Criterion 2. The smoke does not discriminate the fix. The verifier reverted the
only behavioural change (`scripts/spawn-worker.sh:85`, the rendered
`$family_notes` in place of the literal `None`) through the smoke's own seam
`AUTOMETTA_SPAWN_WORKER_UNDER_TEST` and ran six pre-fix trials: PASS, FAIL,
PASS, PASS, PASS, PASS. The fixed arm ran 4/4 PASS. Five of six passes on
unmodified code is not a reproduction; it is noise from a 20B model making a
free choice. The card's central demand is a test that fails before the fix and
passes after it, and this one does not.

The mitigation claimed at `docs/lessons.md:539-544`, that the smoke "accepts
only a marker in the linked worktree and rejects one in the subscriber
checkout", is therefore not supported by the artefact it describes. The marker
lands in the linked worktree with or without the change.

### Why this is structural, not careless

The behaviour under test is a model's free choice of tool directory, which is
stochastic. A single trial cannot be an assertion. That is the real lesson of
attempts 1 and 2 together, and attempt 3 exists to fix the fixture, not to
re-derive the cause.

### What attempt 3 must produce

Take the verifier's route (a). The fixture is not discriminating because the
fixture subscriber checkout lives under `$TMPDIR`, which codex grants as a
sandbox root in its own banner (`sandbox: workspace-write [workdir, /tmp,
$TMPDIR, .../subscriber/state]`). A wrong-checkout write there succeeds
silently, so the wrong choice produces a pass. Place the fixture subscriber
checkout **outside every granted sandbox root**, so a wrong-checkout write is
refused with `Operation not permitted` exactly as in the 2026-08-16 incident
the card stands in for. Then the arms separate on the sandbox's verdict rather
than on the model's mood, and the fixture also becomes a closer model of the
incident.

Route (b), N trials per arm asserting a wrong-checkout rate, is acceptable only
if you can show route (a) cannot be made to work, and you must say why in the
handoff. It costs wall-clock and it leaves a flaky test behind.

Everything else in Deliverables, Constraints and Acceptance criteria stands
unchanged. Specifically:

- Criterion 2 must now be demonstrated with both arms shown: the pre-fix arm
  failing and the fixed arm passing, on the same fixture, in the handoff.
- Do not re-litigate the root cause. It is settled and `docs/lessons.md`
  gotcha 14 records it. Edit that section only if the new fixture changes what
  is true about it.
- Do not widen the sandbox to make the fixture separate. Moving the fixture
  out of the granted roots is the point; granting more roots is the opposite.

### Out of scope, recorded here so it is not lost

`render_prompt` has always discarded the card's own `## Family-specific notes`
section and substituted a literal `None` (`scripts/spawn-worker.sh:85` before
attempt 2's change). Attempt 2 replaced that literal with a fixed sentence, so
the card's declared notes are still dropped. This is pre-existing, it is not
this card's job, and it wants its own card. Do not fix it here.


## Re-brief, attempt 4 (2026-08-30)

Attempt 3 is preserved as `727dc404c6d9012032388b782ccbd56c6dad9867` on
`wip/79-a-local-worker-can-write-to-its-worktree-attempt-3`. Read that commit
before writing anything. Do not start from attempt 2.

Criteria 1 and 3 to 6 passed for the third time. Criterion 2 failed for the
third time. That pattern is the finding, and this re-brief exists to act on it
rather than to ask for a fourth run at the same wall.

### Route (a) worked, and it was still not enough

The fixture change was right. Moving the fixture subscriber checkout outside
the run worktree, `/tmp`, `$TMPDIR` and the granted state path took the pre-fix
false-pass rate from 5-in-6 (attempt 2) to 3-in-14 (attempt 3, against 5/5 on
the fixed arm). The mechanism is now correct: the sandbox refuses the
wrong-checkout write instead of silently accepting it. Keep the attempt-3
fixture. Do not redesign it.

What defeats it is residual, not systematic. Roughly one run in five the model
picks the right checkout for its own reasons and the write lands where it
should regardless of the fix. No single-trial assertion can remove that,
because the quantity being asserted is a probability. Attempt 3 was asked for a
deterministic test of a stochastic behaviour, and that was an authoring error
in the attempt-3 re-brief, not a worker failure.

### What attempt 4 must produce

Take route (b), which earlier re-briefs allowed only as a fallback. It is now
the primary instruction.

- Keep the attempt-3 fixture exactly as it stands.
- Run N trials per arm and assert on the **rate**, not on a single outcome.
  Pick N from the measured rates above and state the arithmetic in the handoff:
  N must be large enough that a 3-in-14 pre-fix arm and a 5-in-5 fixed arm
  separate reliably, and small enough to fit the wall-clock budget. Show the
  number you chose and why.
- Assert a threshold with headroom either side, not equality. A pre-fix arm
  that passes a fifth of the time and a fixed arm that passes every time do not
  need a tight boundary between them.
- The smoke must name its own flake budget in a comment: what rate it tolerates
  on each arm, and what observed rate would mean the fix has regressed.

### The blocker that has now cost three attempts

The worker cannot exercise its own criterion. From inside the worker sandbox
`bash -lc ollama list` returns `dial tcp 127.0.0.1:11434: connect: operation
not permitted`, while the same command from the verifier seat succeeds and
shows `gpt-oss:20b` pulled. Every attempt has reported this, and every attempt
has been marked down for a demonstration it was structurally unable to give.

For this card, stop pretending otherwise:

- Criterion 2's A/B is the **verifier's** job, not the worker's. The worker
  writes the smoke and states plainly that it could not run it, with the exact
  error. That is a complete worker deliverable, not a partial one.
- The worker's handoff envelope should read `status: pass` when the smoke is
  written and criteria 3 to 6 hold, with the unexercised criteria named in
  `notes`. It should not read `partial` for a limitation of the seat it was
  dispatched into.

The sandbox's loopback refusal is a real defect in the local route and it wants
its own card. It is out of scope here. Note it in the handoff, do not fix it.

### Out of scope, restated

`render_prompt` still discards the card's own `## Family-specific notes` and
substitutes a fixed sentence (`scripts/spawn-worker.sh`). Pre-existing, wants
its own card, do not fix it here.

### Not scheduled

This re-brief is recorded, not queued. The stage stays `verifier_failed` until
an operator queues it deliberately. Do not treat the presence of this section
as a dispatch.
