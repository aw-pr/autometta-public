# Stage card 153: a reader never sees half a payload

## Metadata

- **Authored:** 2026-10-11
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/153-a-reader-never-sees-half-a-payload
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/attach-card-text.py, docs/dashboard.md
- **Pairing rationale:** a small, well-specified Python change: Sonnet
  writes it and Terra verifies it offline. The Claude worker alternates
  with 154's Codex worker, so the pair may overlap on disjoint claims.

## Surfacing concern

`scripts/aggregate-dashboard.sh` writes `data.json` and `data.js` through a
temporary file and `mv`. `dashboard.sh` then runs `attach-card-text.py`,
which reopens both files with `open(path, "w")` and rewrites them in place.
Under `--serve` that happens every five seconds on a payload of about
1.2MB. On 2026-10-11 two of the orchestrator's direct reads of the
emergence-lab `data.json` caught it half written. The page tolerates a
single failed poll, but a reader that lands in the window gets a parse
error or, for `data.js` over `file://`, a broken page.

## Objective

`attach-card-text.py` replaces both files by writing a temporary file in
the same directory and renaming it over the target, so any reader sees the
old payload or the new one, never part of either. A payload it cannot read
is left untouched.

## Inputs (read these in your own context)

- `scripts/card-text-atomic-smoke.sh`: the frozen contract; read it first.
- `scripts/attach-card-text.py`.
- `scripts/dashboard.sh`, where it is called (read, do not edit).

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/attach-card-text.py`: write each output through a temporary
   file created in the target's directory, then `os.replace` it onto the
   target. Remove the temporary file if anything fails before the rename.
   Keep the files' existing permissions: the aggregator creates them 0600.
   Exit non-zero, leaving both files as they were, if `data.json` cannot
   be parsed.
2. `docs/dashboard.md`: one sentence where the payload files are described
   saying both writers replace them by rename.

## Constraints

- The frozen block in `scripts/card-text-atomic-smoke.sh` is read-only.
- The payload content is unchanged: the same card text, the same `data.js`
  prefix and suffix.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/card-text-atomic-smoke.sh` passes on the run branch, run by
   the verifier, and `scripts/check-contract-test-gate.sh print
   scripts/card-text-atomic-smoke.sh` prints the digest recorded below.
2. `scripts/dashboard-liveness-smoke.sh` and `scripts/dashboard-clock-smoke.sh`
   still pass.
3. The verifier runs the script on a copy of a 0600 `data.json` and shows
   the result is still 0600.
4. `python3 -m py_compile scripts/attach-card-text.py` passes and
   `git diff --stat` touches only the claimed paths.

## Contract test

- **Test file:** scripts/card-text-atomic-smoke.sh
- **Assertions digest:** `sha256:e4ec184e66b20d2f09baae68d237a2ee01c3a0812f443bd8b6ae37dc1f141c2f`

The orchestrator authored the frozen block on 2026-10-11. It fails today at
its first assertion, because `data.json` keeps its inode across the rewrite.
A throwaway reference implementation passed every block, including a reader
polling through twenty rewrites with no partial parse.

## Out of scope

- The aggregator's own writes, which already rename.

## Budget

- **Worker wall-clock:** 20 minutes
- **Verifier wall-clock:** 15 minutes
- **Spend basis:** planning allowance 2M tokens under the 2026-10-11 drain.

## Dispatch envelope

Write `state/envelopes/153-a-reader-never-sees-half-a-payload.json` using `schemas/envelope.json`. List
changed deliverables, the exact smoke commands and their results, and any
criterion you could not satisfy with why. Do not self-verify or land your
own branch. The verifier writes `state/verifiers/153-a-reader-never-sees-half-a-payload.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.
