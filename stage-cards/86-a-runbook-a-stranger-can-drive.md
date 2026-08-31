# Stage card 86: a runbook a stranger can drive

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/86-a-runbook-a-stranger-can-drive
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** docs/runbook.md, README.md
- **Pairing rationale:** condensing existing docs into an operational sequence
  is workhorse-tier writing; the Claude verifier reads it as the stranger it
  is written for, which is where a lazy paste-up of setup.md would show. The
  codex worker also alternates families with card 82's Claude worker, making
  this card the pipeline partner for the 82 verifier window.

## Objective

The UAT feedback asks for "an up-to-date runbook so a human or agent knows
how to run it", and the README review moved detail out to reference docs
without giving the operator a single ordered sequence to drive from. Write
the runbook: the shortest ordered path from a cold machine to a fed queue
running overnight, and the daily drive loop for a fleet already set up. It
condenses and links; it does not duplicate. Every command in it must exist.

## Inputs (read these in your own context)

- README.md (Your first dispatch, Updating an existing repo, Billing routes)
- docs/setup.md
- docs/observability.md
- docs/phat-controller.md
- bin/autometta

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `docs/runbook.md`, at most 1200 words, two parts:
   - **Cold start:** install, auth verification, subscribing a repo, authoring
     and queueing cards, arming the heartbeat, the pre-flight checks before
     walking away (`auth status`, `check-build`, budget file, drain state).
   - **Daily drive:** morning review after an overnight run (status, tui,
     dashboard, controller log), reading a halt and clearing it, re-queueing
     after a FAIL (naming the autometta-requeue path), landing awaiting
     integrations, and the end-of-day queue feed.
   Each step is one or two imperative sentences plus the command, with a link
   to the doc that owns the detail. No section longer than its target doc's
   own summary.
2. A pointer to the runbook from README.md: one line in the reading order and
   one in the decision tree's overnight branch. No other README changes.

## Constraints

- Every command line in the runbook must name a real subcommand of
  `bin/autometta` or a real script under `scripts/`; nothing aspirational.
- Link, do not duplicate: a topic with an owning doc gets one or two
  sentences and the link, never a restatement.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `docs/runbook.md` exists, is at most 1200 words, and has the two parts
   named above.
2. Every `autometta <subcommand>` in the runbook appears in `bin/autometta`,
   and every `scripts/*.sh` path in it exists; the verifier lists each
   command checked.
3. The README diff touches exactly two lines plus surrounding whitespace: the
   reading-order entry and the decision-tree pointer.
4. `grep -c '—' docs/runbook.md` returns 0.
5. A stranger test by the verifier: following only the cold-start part,
   every referenced file and doc resolves from a fresh clone's perspective
   (no gitignored file is assumed present, no absolute path appears).

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Any change to setup.md, observability.md or phat-controller.md.
- The machine-dependency audit from the same UAT list (ollama, token scripts):
  that is its own card.
- Screenshots.

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the word count, the command-by-command
existence check, and the README diff.

## Family-specific notes

None
