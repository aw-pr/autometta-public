# Stage card 62: the run worktree's state symlink is load-bearing

## Metadata

- **Authored:** 2026-08-25
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/62-the-run-worktree-state-symlink-is-load-bearing
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** a path-resolution bug in bash, verified by the
  family that can replay a dispatch and read where the file actually landed.

## Objective

`ensure_run_worktree` in `scripts/tick.sh` replaces a fresh run worktree's
tracked `state/` directory with a symlink to the subscriber's real state:

```sh
rm -rf "${work_dir:?}/state"
ln -s "../$(basename "$repo_root")/state" "$work_dir/state"
```

Everything downstream depends on that symlink existing, because the paths
handed to agents are **relative**. `scripts/spawn-verifier.sh` builds
`artefact_path="state/verifiers/${stage_id}.json"` and
`templates/worker-prompt.md` names ``state/handoffs/<<stage-id>>.json``.
Both are resolved by the agent against its own working directory, which is
the run worktree. Meanwhile every reader resolves them against `repo_root`:
`tick.sh` reads `"$repo_root/state/verifiers/${current_stage}.json"`, and
`spawn-verifier.sh` itself prepares `"$repo_root/state/verifiers"`.

So the symlink is the only thing making the writer and the reader agree.
When it is present, everything works. When it is absent, the agent writes
into the run worktree, the tick sees nothing, and the outcome is
indistinguishable from an agent that failed to write at all.

On 2026-08-25 that is exactly what happened. Stage 51's verifier returned a
genuine PASS on all six criteria; the artefact landed at
`<run-worktree>/state/verifiers/51-....json`, the tick found nothing at
`$repo_root/state/verifiers/`, scored the verifier `aborted`, and
re-dispatched. Two attempts of three were burned on a verdict that already
existed. The symlink had been removed by an operator script that mistook it
for a worker's mistake, which it is not.

The failure mode is worse than the incident. A missing symlink is silent,
it presents as `worker_envelope_missing_after_exit` or as an aborted
verifier, and it sends the operator hunting the agent instead of the path.

After this card, a missing symlink is impossible to ignore.

## Inputs (read these in your own context)

- `scripts/tick.sh`, `ensure_run_worktree` and the artefact read near the
  verifier reap.
- `scripts/spawn-verifier.sh`, the `verifiers_dir` and `artefact_path`
  lines, and `render_prompt`.
- `templates/worker-prompt.md`, the handoff envelope path.
- `templates/verifier-prompt.md`, which already documents the symlink as
  expected behaviour and tells verifiers not to cite it as a scope
  violation.
- `docs/lessons.md` gotcha 2, the card-sync race, which is the same class of
  problem: two views of one tree disagreeing about where a file is.

## Deliverables

1. **A dispatch-time assertion.** Cutting a run worktree verifies the
   symlink exists and resolves to the subscriber's `state/`. If it does
   not, the dispatch fails loudly before an agent is spawned rather than
   after one has run and written into the void.
2. **A read-time assertion.** Before the tick concludes that an envelope or
   artefact is missing, it checks whether the run worktree's `state` is
   still a symlink. A missing file with a broken symlink is reported as a
   dispatch fault, not as an agent that wrote nothing. These are different
   diagnoses and they send an operator to different places.
3. **Path resolution that does not depend on the symlink alone.** Decide
   and implement one contract: either the paths handed to agents are
   absolute and point at the subscriber's state, or they stay relative and
   the symlink is asserted at both ends. State which you chose and why in
   the handoff envelope. Do not leave a relative path whose only guarantee
   is a symlink nothing checks.
4. **A regression smoke.** A dispatch whose worktree has had its `state`
   symlink replaced by a real directory must fail in a way that names the
   symlink. Prove it fails today and passes after.
5. **`docs/lessons.md` gains a gotcha** describing the silent
   misdirection and how to recognise it: an envelope or artefact that the
   agent's own log says it wrote, which the tick cannot find.

## Constraints

- The symlink is deliberate. Do not remove it, and do not "fix" it by
  giving run worktrees their own state; per-stage state was never the
  design and the whole dispatch loop assumes one shared store.
- Do not weaken the verifier prompt's existing scope exclusion for `state/`
  paths. That text is correct and stops verifiers failing stages over the
  symlink.
- No change to what an envelope or an artefact contains.
- Historical stages that failed this way are not to be re-scored. Fix the
  mechanism; the record stands.

## Acceptance criteria

1. Cutting a run worktree produces a `state` symlink resolving to the
   subscriber's `state/`. Show it for a fresh dispatch.
2. A worktree whose `state` symlink has been replaced by a real directory
   causes the next dispatch to fail before an agent starts, with a message
   naming the symlink.
3. With the symlink broken, a missing artefact is reported as a dispatch
   fault rather than as an aborted verifier, and no verifier attempt is
   burned. Show the attempt counter unchanged.
4. The same holds for a missing worker envelope: reported as a dispatch
   fault, not `worker_envelope_missing_after_exit`.
5. The path contract chosen in deliverable 3 is implemented consistently:
   grep the tree and show no remaining relative `state/` path handed to an
   agent that is resolved against `repo_root` by its reader.
6. The regression smoke fails on the pre-fix tree and passes after.
7. `docs/lessons.md` carries the new gotcha, and it names the symptom
   before the cause.

## Contract test

Replay stage 51's 2026-08-25 failure: cut a worktree, remove the `state`
symlink and replace it with a real directory, dispatch a verifier that
writes a valid artefact, and confirm the loop now reports a dispatch fault
naming the symlink instead of scoring the verifier aborted and burning an
attempt.

## Out of scope

- The verifier panel path (`spawn-verifier-panel.sh`), which is broken here
  for an unrelated reason: it requires `auth.claude.mode: api` and its
  roster still names the superseded Claude Opus 4.8 and Claude Sonnet 4.6.
  That is its own card.
- Re-scoring or re-running any historical stage.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return the fresh-dispatch symlink, both fault paths with their messages and
the untouched attempt counter, the grep proving the path contract is
consistent, the smoke failing before and passing after, and the lessons.md
entry.

## Family-specific notes

None
