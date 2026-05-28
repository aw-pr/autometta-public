<!--
Stage card template, part of the dispatch-contract pattern library. Reusable in any repo. Do not add project-specific content here. Fill in every <<placeholder>> before dispatching a worker. Section headings are load-bearing, do not rename them. -->

# Stage card <<stage-id>>: <<stage-title>>

## Metadata

- **Authored:** <<date-authored>>
- **Orchestrator:** <<orchestrator-identity>>
- **Worker:** <<worker-identity>>
- **Verifier:** <<verifier-identity>>
- **Verifier panel:** false
- **Pairing rationale:** <<why-this-worker-verifier-pair>>

## Objective

<<objective>>

## Inputs (read these in your own context)

<!--
Paths are relative to repo root, not absolute. Do not embed /Users/... or any other home-dir path here; cards must remain portable across clones and machines. The worker is expected to cd to repo root before reading. -->

<<list-of-input-file-paths>>

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

<<numbered-list-of-deliverables-with-paths-and-descriptions>>

## Constraints

<<list-of-hard-constraints>>

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

<<numbered-list-of-acceptance-criteria>>

## Out of scope

<<list-of-explicitly-excluded-items>>

## Budget

- **Worker wall-clock:** <<worker-wall-clock-budget>>
- **Verifier wall-clock:** <<verifier-wall-clock-budget>>

## Verifier handoff

<<instructions-for-what-the-worker-returns-on-completion>>

## Family-specific notes

<!--
If any step in this card is genuinely specific to one agent family (e.g. stdin redirect for Codex exec, OAuth session for Claude Code), document it here with the family name explicit. Leave this section as "None" if the card is fully family-neutral. -->

<<family-specific-notes-or-none>>
