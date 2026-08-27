# Stage card 81: a measured table declares its shelf life

## Metadata

- **Authored:** 2026-08-27
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/81-a-measured-table-declares-its-shelf-life
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/candidate-viability.sh, docs/measurement-shelf-life.md
- **Pairing rationale:** mechanical acceptance with a prose half, so the
  workhorse tier is the right worker. The verifier is the other family and
  reads the prose, which is where a cheap pass would show.

## Objective

`docs/verifier-bake-off.md` measured eight verifier candidates on 2026-08-24.
Three days later six of its eight rows could no longer be reproduced, because
`codex-cli 0.149.1` began refusing any `--oss` model without thinking support
(gotcha 13). Nothing in the repo noticed. The regression was found by hand,
while doing something else, and only because a dispatch failed.

The general problem is that a measured table about third-party software has a
shelf life the table does not state and nothing checks. The bake-off is the
instance; the pattern will recur for every rate table, model id and CLI
behaviour the repo records.

Build the cheap half of the answer: a script that answers "are the candidates
in this table still dispatchable" without spending a token, and a short piece of
prose that says how measured claims in this repo are expected to age.

## Inputs (read these in your own context)

- docs/verifier-bake-off.md
- docs/lessons.md
- scripts/models.sh
- scripts/rates.sh

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/candidate-viability.sh`, which reads the local candidate model ids
   out of `docs/verifier-bake-off.md`, checks each against the machine's actual
   Ollama state, and prints one line per candidate saying whether it is pulled
   and whether it still carries the capability `codex exec --oss` requires. It
   exits non-zero when any candidate the document presents as usable is not.
   It spends no tokens, needs no network beyond the local Ollama socket, and
   degrades to a clear skip when Ollama is not running.
2. `docs/measurement-shelf-life.md`, at most 400 words, stating which classes
   of claim in this repo are measurements of third-party behaviour rather than
   of our own code, what makes them expire, and what an agent should do on
   finding one that has. It must name the bake-off as the worked example.
3. A pointer to both from `docs/verifier-bake-off.md`, added inside the existing
   caveat block, not as a new section.

## Constraints

- Do not re-run the bake-off or alter a single measured figure. The numbers are
  the historical record and are not this card's to touch.
- Do not add a scheduled job, cron entry or LaunchAgent. This card ships a
  script an operator or a controller pass can run, nothing that runs itself.
- Parse the document, do not hard-code the candidate list. A table that grows a
  row must not need this script edited.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash scripts/candidate-viability.sh` exits non-zero on this machine today,
   because four documented local candidates no longer carry thinking support,
   and its output names all four.
2. It exits 0 when pointed at a table whose candidates are all viable, shown
   with a fixture.
3. It prints a clear skip and exits 0 when Ollama is not reachable.
4. `bash -n scripts/candidate-viability.sh` passes.
5. `docs/measurement-shelf-life.md` is at most 400 words and names the bake-off.
6. `grep -c '—' docs/measurement-shelf-life.md` returns 0.
7. No measured figure in `docs/verifier-bake-off.md` is changed, shown by a diff
   restricted to the caveat block.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Re-measuring any candidate.
- Cloud candidates (OpenRouter, Groq): they are not `--oss` dispatches and are
  a different check.
- Any change to which models autometta dispatches to by default.

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the script's output on this machine and
the word count of the prose deliverable.

## Family-specific notes

None
