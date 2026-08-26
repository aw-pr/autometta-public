# Stage card 76: Llama sits the verifier bake-off

## Metadata

- **Authored:** 2026-08-26
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/76-llama-sits-the-verifier-bake-off
- **Worker effort:** medium
- **Verifier effort:** high
- **Requires GUI:** false
- **Verifier panel:** false
- **Gate:** stage-completed: 75-the-run-rows-name-models-and-line-up
- **Pairing rationale:** the worker must reach the local Ollama server
  at localhost:11434, and the codex workspace-write sandbox denies
  network (the card 36 failure class), so the worker seat is Claude by
  necessity, not quota: Sonnet drives the harness, Fable verifies at
  higher effort because the numbers feed a published write-up. The
  operator's OAI clearance stands for any card without this constraint.

## Objective

Card 46 built the verifier bake-off: every candidate answers the same
benchmark manifest of ten stages and its verdicts are scored for
agreement against the frontier verifier's recorded verdicts. Eight
candidates have sat it; `local-llama4-scout` (Meta's Llama 4 Scout via
Ollama, committed to the candidate table in 3bfcc4a) has not. This card
finishes the bake-off with Llama as the alternative verifier candidate
and brings the documentation to a state a public write-up can be built
from: the operator intends an explainer article and possibly publishing
the results in the repo on GitHub.

## Inputs (read these in your own context)

- `scripts/verifier-bake-off.sh` and its `--help` output; the candidate
  is `local-llama4-scout`.
- `scripts/verifier-bake-off-caller.py`, only as far as its output
  schema.
- `examples/bake-off/manifest.json`, the ten benchmark stages.
- `examples/bake-off/frontier/`, the reference verdicts.
- `docs/verifier-bake-off.md`, the results document this card completes;
  study how existing candidates' results are tabulated and match it.
- One existing candidate directory (for example
  `examples/bake-off/local-gpt-oss-120b/`) as the artefact shape
  reference.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. **A full run**: `verifier-bake-off.sh batch --candidates
   local-llama4-scout` over all ten manifest stages, producing one
   verdict JSON and one metadata JSON per stage under
   `examples/bake-off/local-llama4-scout/`, same shape as the existing
   candidate directories. Local candidate: no cloud caps apply, the
   420 second local timeout does. A stage that times out or errors is
   recorded as such in its metadata, rerun once, and reported honestly
   if it fails twice; a hole in the results is a result.
2. **The results document completed**: `docs/verifier-bake-off.md`
   gains the llama4-scout row(s) in the candidate and results tables:
   overall agreement with the frontier verdicts, per-stage
   agree/disagree, any timeouts, wall-clock per stage, and tokens if
   the caller reports them. Figures are computed from the artefacts on
   disk (show the computation in the envelope), never estimated.
3. **The document made publish-ready**: a short methodology section (or
   the existing one tightened) that a reader outside this repo can
   follow -- what the benchmark stages are, what agreement means, what
   the frontier reference is, how to reproduce a run, and the caveats
   the doc already records (roster rotation, rate caps, timeout
   tuning). British English, no em dashes, no AI-tell vocabulary; the
   persona-west audit rules apply to committed prose.
4. **A recommendation paragraph updated or confirmed**: with all nine
   candidates scored, does the free-verifier recommendation change?
   State it either way, with the figures that decide it.

## Constraints

- The cloud candidates are already scored; do not rerun them. Groq and
  OpenRouter are not to be touched -- beyond the worker's own session,
  this card spends nothing but local wall-clock.
- Do not modify the harness, the caller, the manifest, or any existing
  candidate's artefacts. If the harness misbehaves, that is a finding
  for the envelope, not a fix in this card.
- Do not overwrite `examples/bake-off/frontier/`.
- The Ollama server must be confirmed up before the batch
  (`ollama list` shows `llama4:scout`); if it is not, stop and say so
  rather than burning the attempt.

## Acceptance criteria

1. `examples/bake-off/local-llama4-scout/` holds a verdict JSON and a
   metadata JSON for every manifest stage, schema-matching the existing
   candidate directories (spot-checked against one).
2. The agreement figures in `docs/verifier-bake-off.md` recompute from
   the artefacts: the verifier independently derives overall and
   per-stage agreement from the JSONs and matches the document's
   numbers exactly.
3. Any timeout or error stage is visible in both the metadata and the
   document, not silently absent.
4. The methodology section lets an outside reader reproduce a local
   candidate run with commands that exist; every referenced path and
   flag is real.
5. The document passes the prose rules: British English, no em dashes,
   no AI-tell vocabulary.
6. The recommendation paragraph exists, names the winning
   configuration, and its cited figures appear in the results table.
7. `git status` shows no change outside `examples/bake-off/
   local-llama4-scout/` and `docs/verifier-bake-off.md`.

## Contract test

After the batch: ten stage artefact pairs under the candidate directory;
an independent recomputation of agreement from those artefacts equals
the documented figures; the reproduction commands in the methodology
section run as written against the committed tree; no file outside the
declared paths changed.

## Out of scope

- Rerunning any other candidate.
- Changing the harness, caller, manifest or frontier artefacts.
- The explainer article itself (the operator writes it; this card only
  guarantees the material it draws on).
- Promoting llama4-scout into the live verifier rotation; that is a
  separate decision the recommendation paragraph informs.

## Budget

- **Worker wall-clock:** 150 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return the artefact listing, the agreement recomputation alongside the
documented figures, any timeout or error stages with their metadata, the
prose-rule check, and the reproduction commands as run.

## Family-specific notes

Claude worker: the batch is one long-running bash invocation per the
manifest; drive it with the repo's own harness and read the artefacts it
writes. Do not parallelise stages against a single Ollama server. A
codex-family worker cannot take this seat: workspace-write denies the
localhost network the harness depends on.

## Re-brief (attempt 2, 2026-08-26, 22:45)

Attempt 1 died by stopping short, not by erring: the worker started the
batch, watched stage 02 time out and stage 05 begin, then wrote a
sign-off ("I'll pause here and pick back up automatically") and exited
at 1.97M tokens. A headless `claude -p` session is one-shot; nothing
resumes it, and the batch died with the session. Three partial metadata
files were discarded with the worktree.

The correction is behavioural and is now part of the brief: **run the
batch as one foreground invocation and stay with it to completion.**
`verifier-bake-off.sh batch --candidates local-llama4-scout` blocks
until all ten stages are done; do not background it, do not exit while
it runs, do not narrate progress in place of finishing. The 150 minute
worker wall-clock exists precisely to sit through ten local inferences
at up to 420 seconds each plus reruns. Leaving the session before the
batch returns is a failed attempt, whatever the log says.
