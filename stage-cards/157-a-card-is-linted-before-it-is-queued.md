# Stage card 157: a card is linted before it is queued

## Metadata

- **Authored:** 2026-10-12
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/157-a-card-is-linted-before-it-is-queued
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/card-lint.sh, docs/dispatch-contract.md
- **Pairing rationale:** the hardest card in the batch: a parser whose
  whole value is precision, since a lint that cries wolf gets waved
  through. Sol writes it; Opus reads it as an adversary, in the other
  family. The worker family alternates with 156's Claude worker.
- **Open decisions:** none

## Surfacing concern

The 2026-10-12 analysis found that most card-caused failures were visible
in the card text before dispatch, and that `scripts/add-stage.sh` checks
only the metadata it parses: the digest regex at `scripts/add-stage.sh:146`
does not check that the test file exists, that its block names this card,
or that the digest matches. Examples that a deterministic check would have
caught: card 113 attempt 1 spent 822k tokens finding an unclaimed schema;
card 101 named two test files against one digest and failed card 152
(commit 2315016); card 107 was queued with a digest placeholder.

The rules below were measured before this card was written. A throwaway
reference over cards 145 to 154 reported nothing but the missing Open
decisions line, which no card before 155 has. Two looser rules were
dropped because they fired on good cards: any backticked token with a
slash counted as a path (`n/a`, `/opt/homebrew/bin/python3`), and any
path anywhere in Deliverables counted as a deliverable (145 and 154 name
files "not yours to change" there).

A read-only Codex GPT-5.6 Sol cold read of this batch on 2026-10-12
raised 22 items across the three cards; each is answered in the card text.

## Objective

`scripts/card-lint.sh` reports each card-defect class it can see in a card
exactly once and only when it is there; by default it warns and exits 0,
and with `--strict` any finding fails it.

## Inputs (read these in your own context)

- `scripts/card-lint-smoke.sh`: the frozen contract; read it first.
- `scripts/check-contract-test-gate.sh`: `print` and the marker rules.
- `scripts/add-stage.sh`: the metadata it parses (read, do not edit).
- `templates/stage-card.md`
- `docs/dispatch-contract.md`, section "Contract tests".

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/card-lint.sh` (new, executable), invoked as
   `card-lint.sh [--strict] <card>...`. Read-only. For each card:
   - The repo root is `git -C <card's directory> rev-parse --show-toplevel`,
     or the directory the lint was started from when the card is not in a
     repository. The card's
     repo-relative path is computed on physical paths: on macOS `/var` is
     a symlink to `/private/var` and git reports the latter.
   - A section is the text under a `## ` heading, matched by prefix, so
     `## Inputs (read these in your own context)` is Inputs. Prose means
     card text outside fenced code blocks (between lines starting with
     three backticks) with inline code spans removed.
   - A path token is a backticked token that contains `/`, does not start
     with `/` or `~`, contains no space, `*`, `<`, `>`, `$` or `(`, and
     ends with a file extension or `/`; a trailing `:N` or `:N-M` line
     reference is dropped first. A name with no slash, such as
     `AGENTS.md`, is never checked: that is deliberate, because the looser
     rule fired on good cards.
   - Checks, each with its id:
     - `placeholder`: prose contains `<<`, one or more characters other
       than `<` and `>`, then `>>`.
     - `open-decisions`: the metadata line `- **Open decisions:** ` is
       missing, or its value, trimmed, is not `none` (any case, an
       optional full stop).
     - `pairing`: Worker and Verifier resolve to the same family and the
       Pairing rationale contains neither `same-family` nor `same family`,
       in any case.
       An identity containing `Claude` is claude; `Codex` or `GPT` is
       codex; `Gemini` is gemini; anything else is unresolved and not
       judged.
     - `budget`: the `Worker wall-clock` or the `Verifier wall-clock`
       metadata line is missing.
     - `headings`: any of Metadata, Objective, Deliverables, Acceptance
       criteria, Contract test or Budget is missing.
     - `inputs`: a path token in Inputs does not exist under the repo root.
     - `claims`: Path claims is declared and a numbered Deliverables item
       whose leading backticked token is a path token names a path that is
       neither a claimed path nor under one. Paths under `state/` and the
       card's own path are exempt.
     - `absolute-path`: a line contains `/Users` or `/home` immediately
       followed by a slash, code spans included: a backticked absolute
       path is the commonest form of the leak.
     - `contract-test`: Test file names a file (not `None`) and the file
       is missing, carries an `AUTOMETTA-CONTRACT-NONE` line, has no BEGIN
       marker or one whose `card=` is not this card's repo-relative path,
       or its
       digest from `check-contract-test-gate.sh print` (the copy beside
       `card-lint.sh`, not the target repo's vendored one) differs from
       the card's recorded `Assertions digest`.
   - Output, on stdout: one line per finding,
     `card-lint: WARN <card as given>: <check-id>: <message>` (`ERROR` in
     place of `WARN` under `--strict`), with a message that names the fix;
     at most one line per check per card, reporting the first problem
     that check finds; and `card-lint: OK <card as given>`
     for a card with no finding.
   - Exit: 2 on no arguments or a card that does not exist; under
     `--strict`, 1 when any card has a finding; otherwise 0.
2. `docs/dispatch-contract.md`: a short "Card lint" subsection under
   "Contract tests", after "The gate": what it checks, that the default
   warns and `--strict` refuses, that it reads cards only, and that a new
   card is run under `--strict` before `scripts/add-stage.sh`.

## Constraints

- The frozen block in `scripts/card-lint-smoke.sh` is read-only.
- `scripts/add-stage.sh`, `scripts/check-contract-test-gate.sh` and the
  template are not edited; wiring the lint into queueing is a later card,
  after the lint has run clean on a batch.
- Bash and the Python 3 standard library only; install nothing. BSD `sed`
  on this machine does not expand `\n` in a replacement.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of
the stage. Each criterion names the seat that judges it and the command
that produces its evidence; the verifier runs every command itself, in the
run worktree, offline.

1. Verifier: `bash scripts/card-lint-smoke.sh` prints PASS and exits 0, and
   `scripts/check-contract-test-gate.sh print scripts/card-lint-smoke.sh`
   prints the digest recorded below.
2. Verifier: `scripts/card-lint.sh --strict` on
   `stage-cards/155-a-run-knows-its-first-attempt-rate.md`, this card and
   `stage-cards/156-the-template-asks-what-the-card-has-not-decided.md`
   exits 0. These cards were written to the new template and linted by the
   reference before queueing.
3. Verifier: `scripts/card-lint.sh` in default mode over
   `stage-cards/14[5-9]-*.md` and `stage-cards/15[0-4]-*.md` exits 0 and
   reports no check other than `open-decisions`. The verifier reads two of
   those cards and confirms the lint's silence on them is right, not
   merely quiet.
4. Verifier: `shellcheck -S error scripts/card-lint.sh` exits 0.
5. Verifier: `git status --porcelain` prints the same before and after
   linting every card under `stage-cards/`.
6. Verifier: `git status --porcelain` in the run worktree lists only the
   claimed paths, new files included, apart from the card itself and
   `state/`.
7. Verifier: reading `scripts/card-lint.sh`, the message for each of the
   nine checks names the fix (what to add, remove or change), and the Card
   lint subsection in `docs/dispatch-contract.md` says what Deliverable 2
   gives it. The smoke checks only the check id, not the message.

## Contract test

- **Test file:** scripts/card-lint-smoke.sh
- **Assertions digest:** `sha256:872dfd6a2c2f6ec2e847d1f5a0a125786e3e531940a6fa1cb45d4e481c3aadc4`
- **Oracle proof:** fails today at its first assertion, because the script
  does not exist. A throwaway reference in a detached scratch worktree,
  then removed, passed every assertion after two fixes the worker will
  meet too: physical paths for the repo-relative card path, and the
  narrower path and deliverable rules above.

## Out of scope

- Wiring the lint into `scripts/add-stage.sh`, phat-controller or any skill.
- Style checks (em dashes, banned words) and `path:NN` citation checks:
  measured too noisy on existing cards to ship in the first version.
- Rewriting existing cards to pass.

## Budget

- **Worker wall-clock:** 45 minutes (kill at 60)
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** `state/cost-log.jsonl` on 2026-10-12: worker p95 3.7M
  tokens, verifier p95 3.4M; this is the largest card in the batch, so
  plan at p95, 7M for the stage.

## Dispatch envelope

Write `state/envelopes/157-a-card-is-linted-before-it-is-queued.json` using
`schemas/envelope.json`. List changed deliverables, the exact smoke
commands and their results, and any criterion you could not satisfy with
why. If the card itself is wrong, stop with `status: fail` and say so in
`notes` rather than working round it. Do not self-verify or land your own
branch. The verifier writes
`state/verifiers/157-a-card-is-linted-before-it-is-queued.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.

## Family-specific notes

Codex: workspace-write is all this card needs; the smoke is offline and
builds its fixture repository under `mktemp -d`. Run every command in the
foreground.
