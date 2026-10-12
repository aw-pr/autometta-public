# Stage card 155: a run knows its first-attempt rate

## Metadata

- **Authored:** 2026-10-12
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/155-a-run-knows-its-first-attempt-rate
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/first-attempt-history.sh, bin/autometta, docs/observability.md
- **Pairing rationale:** a read-only walk over git history with a fully
  specified output, so Terra writes it and Sonnet verifies it offline. It
  dispatches first because it is the instrument the next two cards are
  judged by (run-design section 1). The worker family alternates with
  156's Claude worker.
- **Open decisions:** none

## Surfacing concern

Nothing in the repo says how often a card lands on attempt 1.
`scripts/aggregate-dashboard.sh` derives `attempts` only from
`state/cost-log.jsonl`, which starts on 2026-09-06, and
`scripts/requeue-stage.sh` resets `verifier_attempts` on requeue. The
2026-10-12 analysis had to replay the state branch by hand to find that
most failed attempts with a known cause traced to the card, not the worker.
Cards 156 and 157 change how cards are written; without a rate any session
can recompute, nobody can tell whether they helped.

Git already holds what is needed. Landings carry an `Autometta-Worker`
trailer (120 of them in this repo, 210 in emergence-lab), failed attempts
are preserved as `wip(<stage-id>): attempt N` commits, phat-controller
re-briefs are `<stage-id>: phat-controller re-brief citing <sha>` commits
with no trailer, and orchestrator re-briefs append a `## Re-brief` section
to the card.

A read-only Codex GPT-5.6 Sol cold read of this batch on 2026-10-12
raised 22 items across the three cards; each is answered in the card text.

## Objective

`autometta first-attempts <repo>` lists every landed stage with whether it
landed with no failed attempt and no re-brief anywhere in its history, and
prints the rate, computed from git history and the cards on disk alone.

## Inputs (read these in your own context)

- `scripts/first-attempt-history-smoke.sh`: the frozen contract; read it first.
- `scripts/failures-history.sh`: the argument and exit-code shape to follow.
- `bin/autometta`: the `failures` case and the usage block.
- `docs/observability.md`: the Commands section.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/first-attempt-history.sh` (new, executable), invoked as
   `first-attempt-history.sh <repo_root> [--json] [--since <n>]`:
   - It reads `git -C <repo_root> log --all`. A landing is a commit whose
     subject starts with `<stage-id>: `, where the id matches
     `^[0-9]+[a-z]?-[a-z0-9-]+$`, that carries an `Autometta-Worker:`
     trailer, and whose subject does not start with
     `<stage-id>: phat-controller re-brief`. A stage counts once however
     many branches carry a landing for it; `landed_commit` is the full SHA
     of its earliest landing by committer date, a tie going to the first
     that `git log --all --reverse --date-order` lists. The
     `phat-controller re-brief` exclusion holds even when such a commit
     carries a trailer.
   - `wip_attempts` is the number of distinct N across subjects
     `wip(<stage-id>): attempt N` on any ref. `controller_rebriefs` counts
     commits whose subject starts with `<stage-id>: phat-controller re-brief`.
     `rebriefs` counts lines starting with `## Re-brief` in the card
     `<stage-id>.md` under `stage-cards/`, else `docs/stages/`, of the
     repo, and is 0 when no card is found. All three count every ref at
     any time, before or after the landing: a stage that needed rework at
     any point is not clean.
   - `first_attempt_clean` is yes only when all three counts are 0. Only
     landed stages are listed.
   - Table output is a header line, one tab-separated row per stage in the
     column order the smoke asserts, earliest landing first, then
     `first-attempt clean: <clean> of <landed> landed stages (<pct>%)`
     with the percentage rounded to the nearest integer, or `(n/a)` in
     place of the percentage when nothing landed.
   - `--since <n>` keeps stages whose leading number is at least n.
     `--json` prints one object with `landed`, `clean`, `rate` (clean over
     landed as an unrounded number from 0 to 1, null when nothing landed)
     and `stages`, in table order, a list of objects with the six table
     fields, `first_attempt_clean` as a boolean.
   - Exit 2 on a usage error, non-zero when the path is not a git
     repository, 0 otherwise, including for a repository with no commits.
2. `bin/autometta`: a `first-attempts` subcommand that runs the script with
   its arguments, and its line in the usage block beside `failures`.
3. `docs/observability.md`: a short subsection under Commands saying what
   the rate counts, the definition of clean, and that it reads git and the
   cards only, so it covers the eras before the cost log.

## Constraints

- The frozen block in `scripts/first-attempt-history-smoke.sh` is read-only.
- Bash and the Python 3 standard library only, as the other scripts use;
  install nothing.
- Read-only against the target repository: no checkout, fetch, write or
  ref change.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of
the stage. Each criterion names the seat that judges it and the command
that produces its evidence; the verifier runs every command itself, in the
run worktree, offline.

1. Verifier: `bash scripts/first-attempt-history-smoke.sh` prints PASS and
   exits 0, and `scripts/check-contract-test-gate.sh print
   scripts/first-attempt-history-smoke.sh` prints the digest recorded below.
2. Verifier: `scripts/first-attempt-history.sh .` lists stage
   `116-the-reaper-does-not-forgive-a-real-state-directory` with one failed
   attempt and `no`, `107-status-says-when-the-loop-is-not-loaded` with at
   least one controller re-brief and `no`, and
   `153-a-reader-never-sees-half-a-payload` as `yes`. The verifier confirms
   each of the three rows against `git log --all --oneline` for that stage
   id and against the card on disk, not against the script's own output.
3. Verifier: `bin/autometta first-attempts . --since 135` prints the same
   summary line as `scripts/first-attempt-history.sh . --since 135`, and
   `bin/autometta` with no arguments shows `first-attempts` in its usage.
4. Verifier: clone the repository to a scratch directory
   (`git clone -q . "$(mktemp -d)/clone"`) and run the run worktree's
   `scripts/first-attempt-history.sh` against the clone, with and without
   `--json`; `git status --porcelain` and `git for-each-ref` in the clone
   print the same before and after.
5. Verifier: `git status --porcelain` in the run worktree lists only the
   claimed paths, new files included, apart from the card itself and
   `state/`.
6. Verifier: the new subsection under Commands in `docs/observability.md`
   states the definition of clean that the script implements, and names
   both the script and `autometta first-attempts`.

## Contract test

- **Test file:** scripts/first-attempt-history-smoke.sh
- **Assertions digest:** `sha256:f0f377d50a0fc85fd630b195c492525a714996f50022506da106766743775a18`
- **Oracle proof:** fails today at its first assertion, because the script
  does not exist. A throwaway reference implementation, written in a
  detached scratch worktree and then removed, passed every assertion; on
  this repo it reported 70 of 108 landed stages clean, and 13 of 15 from
  card 135 onward. A Codex cold read before queueing found the
  re-brief exclusion untested; the fixture's re-brief commit now carries a
  trailer and the landing SHA is asserted.

## Out of scope

- Classifying why an attempt failed; phat-controller's failure classes
  stay as they are.
- The dashboard, the ticker, `scripts/failures-history.sh` and
  `state/cost-log.jsonl`.

## Budget

- **Worker wall-clock:** 30 minutes (kill at 45)
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** `state/cost-log.jsonl` on 2026-10-12: worker median
  1.1M and p95 3.7M tokens, verifier median 1.2M and p95 3.4M. Plan 4M
  for the stage.

## Dispatch envelope

Write `state/envelopes/155-a-run-knows-its-first-attempt-rate.json` using
`schemas/envelope.json`. List changed deliverables, the exact smoke
commands and their results, and any criterion you could not satisfy with
why. If the card itself is wrong, stop with `status: fail` and say so in
`notes` rather than working round it. Do not self-verify or land your own
branch. The verifier writes
`state/verifiers/155-a-run-knows-its-first-attempt-rate.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.

## Family-specific notes

Codex: workspace-write is all this card needs; it requires no network and
no GUI. The smoke builds its fixture repositories under `mktemp -d`. Run
every command in the foreground.
