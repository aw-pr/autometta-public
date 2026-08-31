# Stage card 90: the verifier reaches for the SDK first

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/90-the-verifier-reaches-for-the-sdk-first
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 28-per-role-family-sdk-transport
- **Path claims:** scripts/spawn-verifier.sh, docs/sdk-verifier.md, .autometta.local.yaml.example
- **Pairing rationale:** resolver-default logic with subtle provenance rules
  is Claude-tier work; the codex verifier exercises the resolution table from
  outside and cannot be fooled by a prose claim about which branch ran.

## Objective

With the Claude SDK route on subscription auth (card 89) and the codex SDK
route shipped (card 28), the CLI stops being the transport of first resort.
The operator's decision: SDK by default wherever the family's auth mode
supports it. Flip the resolution for an **unset** `verifier.<family>.transport`
from `cli` to: `sdk` when the resolved auth mode has an SDK path (claude:
api or subscription; codex: api), otherwise `cli`. An explicit `transport:
cli` in the manifest and the `AUTOMETTA_CLAUDE_TRANSPORT` /
`AUTOMETTA_CODEX_TRANSPORT` env overrides are honoured exactly as today, and
every resolution logs its provenance (default-sdk, fallback-cli, manifest,
env) so a dispatch never takes a transport silently.

## Inputs (read these in your own context)

- scripts/spawn-verifier.sh
- docs/sdk-verifier.md
- .autometta.local.yaml.example

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/spawn-verifier.sh`: the resolution order above, with one logged
   provenance word per dispatch.
2. `docs/sdk-verifier.md`: the resolution table updated; the old
   cli-by-default sentence replaced, not contradicted elsewhere in the doc.
3. `.autometta.local.yaml.example`: the transport block's comments state the
   new default and how to pin `cli`.

## Constraints

- No behaviour change for any explicit setting: manifest and env values
  resolve exactly as before the card.
- `codex` + `subscription` resolves to `cli` with a logged fallback, never
  an error: the subscription dispatch keeps working out of the box.
- The worker role stays CLI: sandbox-as-role-boundary is load-bearing and
  this card must not touch `spawn-worker.sh`.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash -n scripts/spawn-verifier.sh` passes.
2. A resolution probe (dry-run or `--print-transport` if the worker adds
   one) shows: unset + claude + subscription -> `sdk (default-sdk)`; unset +
   codex + subscription -> `cli (fallback-cli)`; unset + codex + api ->
   `sdk (default-sdk)`; manifest `cli` -> `cli (manifest)`; env override
   beats manifest.
3. One real verifier dispatch on this repo (claude family, subscription)
   goes down the SDK branch with no transport key set, shown by its log
   line.
4. `docs/sdk-verifier.md` contains no remaining sentence steering the SDK
   route to API keys or naming `cli` as the default.
5. `git diff --stat` on the run branch touches only the three claimed paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Worker and orchestrator transports (card 23 / card 28 design memo).
- Any change to auth mode resolution itself.
- Live usage display (card 91).

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the resolution probe output for every
row of criterion 2 and the log line from criterion 3.

## Family-specific notes

None
