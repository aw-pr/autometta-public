# Stage card 50: stage cards live in stage-cards/

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/50-stage-cards-live-in-stage-cards
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Gate:** queue-empty
- **Pairing rationale:** a rename that threads through dispatch resolution,
  where the failure mode is a tick that cannot find a card any more. Codex
  verifies cross-family by actually resolving cards from both old and new
  layouts, not by reading the diff.

## Objective

The operator's ask, 2026-08-24: stage cards are the working queue of this
repo and of every subscriber, and they live under `examples/`, which says
"sample material" to every human and agent that reads the tree. They are
not examples; they are the work.

Worse, the estate already disagrees with itself. Autometta's own cards are
at `examples/self-host/*.md`; emergence-lab's are at `docs/stages/*.md`;
both paths are hardcoded as fallbacks in `tick.sh` (`stage_card_for_id`
and the glob default), `list-cards.sh`, and the manifest `subscribe-repo.sh`
writes. Two conventions plus scattered literals is how the next subscriber
invents a third.

One canonical home: **`stage-cards/`** at the repo root, in autometta and
in every subscriber. Descriptive, top-level, the same word the docs already
use for the thing.

## Inputs (read these in your own context)

- `scripts/tick.sh` — `stage_card_glob_defaults` and `stage_card_for_id`,
  the two resolution sites.
- `scripts/list-cards.sh` — its own glob default and the `PLAN.md` path.
- `scripts/subscribe-repo.sh` — the manifest it writes for a new
  subscriber.
- `scripts/add-stage.sh` — confirm it is path-agnostic (it takes the card
  path as an argument).
- `.autometta.local.yaml.example`, `schemas/state.yaml.json`,
  `skills/autometta-setup/SKILL.md`.
- `docs/dispatch-contract.md`, `MANUAL.md`, `README.md` — the prose that
  names the old path.
- `git grep -l 'examples/self-host'` and `git grep -l 'docs/stages'` for
  the full reference list; do not trust this card's enumeration over the
  grep.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `git mv examples/self-host stage-cards` in this repo, history
   preserved. `PLAN.md` moves with the cards.
2. The canonical glob is `stage-cards/*.md` everywhere a default lives:
   `tick.sh`, `list-cards.sh`, `subscribe-repo.sh`,
   `.autometta.local.yaml.example`. The old globs
   (`examples/self-host/*.md`, `docs/stages/*.md`) remain recognised as
   legacy fallbacks in `stage_card_for_id` and the glob defaults, each
   with a one-line comment naming them legacy, so no existing subscriber
   breaks on the day this lands.
3. This repo's own `.autometta.local.yaml` (gitignored, operator file)
   updated in the same working session the move lands, so the very next
   tick resolves cards from the new path. The handoff states it was done.
4. `skills/autometta-setup/SKILL.md` — new adoptions get `stage-cards/`,
   and a short migration note for existing subscribers: `git mv docs/stages
   stage-cards`, edit `stage_card_globs`, done. The note must say the
   legacy globs keep working, so migration is unhurried.
5. Docs and prose (`docs/dispatch-contract.md`, `MANUAL.md`, `README.md`,
   and whatever the grep finds) name `stage-cards/` as the home. Historical
   documents (`docs/incidents/`, `docs/lessons.md`, `memory/`) keep their
   original paths where they describe past events; rewrite references only
   where a reader would follow them today.
6. Relative links inside the moved cards themselves still resolve
   (`PLAN.md`'s table links are relative and survive the move; verify
   rather than assume).

## Constraints

- **Run only when this repo has no stage `pending` or `in_progress`.**
  Check `state/state.yaml` first and halt with a message if the queue is
  live; a card that moves the queue out from under an in-flight dispatch
  is the exact failure this card exists to make impossible.
- Do not edit any subscriber repo. The migration note is the deliverable;
  running it is the operator's, per repo.
- The legacy fallbacks stay until a later card retires them; this card
  adds no deadline.
- `state/state.yaml` records stage ids, not card paths; nothing in state
  needs rewriting. Confirm this against the schema rather than trusting
  the card.
- Terminal stages' cards move with the rest; `stage_card_for_id` must
  still resolve a completed stage's card for retro-grade and requeue.
- British English, no em dashes.

## Acceptance criteria

1. After the move, a fixture repo with cards only in `stage-cards/`
   dispatches: `stage_card_for_id` resolves a card there, and
   `list-cards.sh` lists it.
2. A fixture repo with cards still in `docs/stages/` (emergence-lab's
   layout) resolves and lists identically to before the change.
3. A fixture repo with cards still in `examples/self-host/` resolves and
   lists identically to before the change.
4. In this repo, with the operator manifest updated, `autometta tick`
   dry-run (or the tick's resolution path exercised directly) finds card
   50 itself at its new path.
5. `git log --follow stage-cards/45-a-free-verifier-tier-on-local-weights.md`
   shows history crossing the move.
6. `git grep -c 'examples/self-host'` over tracked files returns only the
   legacy-fallback sites and deliberately historical documents, each of
   which is named in the handoff.
7. `bash -n` on every shell file touched; every existing offline smoke
   script still passes (`sdk-cache-smoke.sh` requires live API credentials
   and is not run: say so).

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Migrating any subscriber repo's cards; the note in the setup skill is
  the deliverable.
- Retiring the legacy globs.
- Renaming anything else under `examples/` or `docs/`; only the stage-card
  home moves.
- Card content changes of any kind.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the three fixture resolutions (new, docs/stages legacy,
examples/self-host legacy), the `--follow` history evidence, the grep
residue list with each site justified, and confirmation the queue was
empty when the move landed.

## Family-specific notes

None

## Re-brief, attempt 2 (2026-08-25)

Attempt 1 was verified by a Claude verifier and returned **FAIL on 1 of 7
criteria**. Six passed, including every substantive one: the new
`stage-cards/` fixture resolves and lists, both legacy fixtures behave exactly
as before, the operator manifest finds stage 50's own card at its new path,
and `git log --follow` crosses the move. The work is preserved at `3e206b0` on
`wip/50-stage-cards-live-in-stage-cards-attempt-1`.

**The entire remaining job is one comment.**

The failing criterion asks that every legacy-fallback code site carry a
one-line comment marking it as legacy. The verifier checked all 40 residual
`examples/self-host` hits across 32 files and justified 39 of them: historical
incident docs and lessons, bake-off artefacts, the moved cards' own frozen
prose, and five code sites that already carry the comment
(`scripts/tick.sh:315` and `:352`, `scripts/list-cards.sh:65` and `:117`,
`scripts/aggregate-dashboard.sh:115`). `bin/autometta:256` was judged
acceptable on a shared comment two lines above its block.

The one gap is **`scripts/retro-grade-batch.py`, in `card_for_stage`**. It
resolves through the same three-tier order as `tick.sh` and `list-cards.sh`,
and it carries no legacy marker anywhere near it; the verifier grepped the
whole file for "legacy" and found nothing.

Add the one-line comment there, in the same words the other five sites use, so
the file matches its siblings. Change nothing else.

**Do not restructure, re-run the move, or revisit the six passing criteria.**
Restore the preserved tree from `3e206b0` (restore the files, do not
cherry-pick the preservation commit) and produce one commit as any other stage
does.

**One judgement to record rather than act on.** The verifier noted that the
bake-off artefacts under `examples/bake-off/` were left alone as historical
records, which is right, but that the card's historical-docs list names only
`docs/incidents/`, `docs/lessons.md` and `memory/`. It called that an
interpretive extension rather than a violation. If the card is ever revised,
add `examples/bake-off/` to that list explicitly. Do not change the card as
part of this attempt.
