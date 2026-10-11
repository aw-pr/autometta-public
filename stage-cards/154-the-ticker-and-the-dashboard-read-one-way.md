# Stage card 154: the ticker and the dashboard read one way

## Metadata

- **Authored:** 2026-10-11
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/154-the-ticker-and-the-dashboard-read-one-way
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/agent-ticker.sh, docs/observability.md
- **Pairing rationale:** Terra for a refactor with a precise contract; Opus
  verifies, as it found the defect while verifying 149. The Codex worker
  alternates with 153's Claude worker, so the pair may overlap on disjoint
  claims.

## Surfacing concern

`scripts/agent-ticker.sh` carries its own copy of the transcript reader,
and both it and `scripts/lib/transcript-tokens.py` advance the same
`transcript_offset` in the active-agents registry. Card 149 taught the
library to count each Claude message once and to keep a burn series, and
card 149's worker taught the ticker to count each message once too, but
the ticker never learned the series, the cache figure or the activity
counts. Card 149's verifier reproduced the result: when the ticker
consumes a chunk, the library never sees it, so the burn series loses its
points, the turn count falls behind and `% cached` stays low for the rest
of the run. Two copies of one parser drift; that is the defect.

## Objective

The ticker's ACTIVE panel reads transcripts through the library's
`transcript_metrics`, so there is one reader. Alternating the ticker and
the dashboard over one registry ends exactly where one library pass over
the whole transcript ends.

## Inputs (read these in your own context)

- `scripts/ticker-shared-reader-smoke.sh`: the frozen contract; read it
  first.
- `scripts/agent-ticker.sh`: the ACTIVE panel's embedded Python, in
  particular `transcript`, `transcript_tokens` and the loop that prints
  `tokens:`.
- `scripts/lib/transcript-tokens.py`: `transcript_metrics` and
  `resolve_transcript`.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/agent-ticker.sh`: remove the embedded `transcript_tokens` and
   load `scripts/lib/transcript-tokens.py` (by path, resolved from the
   ticker's own `script_dir`, so a brew install and a dev checkout both
   find it) and call its `transcript_metrics`. Keep the ticker's `+`
   catching-up suffix, computed from the registry offset against the file
   size. Keep its own transcript resolution only if the library's
   `resolve_transcript` cannot serve; prefer the library's. The printed
   line is otherwise unchanged.
2. `docs/observability.md`: one sentence saying the ticker and the
   dashboard share one transcript reader and one registry state.

## Constraints

- The frozen block in `scripts/ticker-shared-reader-smoke.sh` is read-only.
- `scripts/lib/transcript-tokens.py` is not yours to change; if it cannot
  serve the ticker as it is, say so in the envelope rather than editing it.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/ticker-shared-reader-smoke.sh` passes on the run branch,
   run by the verifier, and `scripts/check-contract-test-gate.sh print
   scripts/ticker-shared-reader-smoke.sh` prints the digest recorded below.
2. `scripts/agent-burn-smoke.sh`, `scripts/agent-activity-smoke.sh`,
   `scripts/repo-ticker-smoke.sh`, `scripts/ticker-fit-smoke.sh` and
   `scripts/fleet-ticker-smoke.sh` still pass; record any failure that
   already exists on the base commit separately.
3. The verifier runs `scripts/agent-ticker.sh <repo-root> --once` while it
   is itself the live agent and quotes its own ACTIVE line, whose token
   figure matches the library's `stage_tokens` for its pid.
4. `bash -n scripts/agent-ticker.sh` passes and `git diff --stat` touches
   only the claimed paths.

## Contract test

- **Test file:** scripts/ticker-shared-reader-smoke.sh
- **Assertions digest:** `sha256:f8312dbfa04b581960371a6ada9535d98ad0b06bdcb23be035309acfe7b241ed`

The orchestrator authored the frozen block on 2026-10-11. It fails today at
its first assertion: the alternated run reads 3 turns and 3 series points
against a single pass's 5 and 5, with the totals agreeing, which is the
drift card 149's verifier reported. A throwaway reference implementation
that loads the library passed every block.

## Out of scope

- The ticker's RECENT and SCHEDULED panels.
- Any change to the library.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** planning allowance 3M tokens under the 2026-10-11 drain.

## Dispatch envelope

Write `state/envelopes/154-the-ticker-and-the-dashboard-read-one-way.json` using `schemas/envelope.json`. List
changed deliverables, the exact smoke commands and their results, and any
criterion you could not satisfy with why. Do not self-verify or land your
own branch. The verifier writes `state/verifiers/154-the-ticker-and-the-dashboard-read-one-way.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.
