<!--
Stage card template, part of the dispatch-contract pattern library. Reusable in any repo. Do not add project-specific content here. Fill in every <<placeholder>> before dispatching a worker. Section headings are load-bearing, do not rename them. -->

# Stage card <<stage-id>>: <<stage-title>>

## Metadata

- **Authored:** <<date-authored>>
- **Orchestrator:** <<orchestrator-identity>>
- **Worker:** <<worker-identity>>
- **Verifier:** <<verifier-identity>>
- **Base branch:** <<base-branch>>
- **Run branch:** <<autometta/stage-id>>

<!--
Dispatch happens in an ephemeral worktree cut from the base branch (`git worktree add ../<repo>-run-<stage-id> -b autometta/<stage-id> <base-branch>`), never in the shared checkout; on PASS the orchestrator fast-forward-merges the run branch back into the base branch (or pushes it, if base moved, and notes that in HANDOFF). Pin both fields to branch names, never commit SHAs. -->

- **Worker effort:** <<low|medium|high|xhigh|max — optional, omit to leave the CLI on its default>>
- **Verifier effort:** <<low|medium|high|xhigh|max — optional. Honoured by the Claude and Codex CLI routes, the Claude SDK route, and every verifier panel member. Omit to leave each route on its default.>>
- **Requires GUI:** <<true if any role must drive a browser, screenshot, or otherwise reach the window server; omit otherwise. Codex roles are sandboxed and every browser aborts at NSApplication init without this, headless included. It grants that agent full machine access, so declare it only when the acceptance criteria genuinely need it.>>
- **Requires network:** <<true if any role must reach the network from a shell command it runs, for example a stage whose deliverable is itself an agent session; omit otherwise. Codex roles run under workspace-write, which denies the socket: an agent session started without this dies on "Unable to connect to API (FailedToOpenSocket)" before its first tool call. Unlike Requires GUI this keeps the filesystem sandbox and opens only the socket, so prefer it whenever the network is all that is missing.>>
- **Requires agent home:** <<true if a role spawns an agent session that needs to write under the Claude home directory, for example the per-session directory Claude Code creates at startup; omit otherwise. Reads of $HOME are already permitted, so this grants write access only, to that one directory, and the sandbox mode is unchanged. Without it an SDK session dies on "EPERM ... mkdir '~/.claude/session-env/<session-id>'".>>
- **Verifier panel:** false
<!--
Optional dispatch gate. Omit the Gate line for an ungated stage. These are the
only accepted forms; a prerequisite always uses its full stage id:

- **Gate:** stage-completed: 58-the-controller-decides-the-scripts-are-its-verbs
- **Gate:** queue-empty

The first waits for the named stage to read completed. The second waits until
no other stage is pending or in_progress. An unmet gate does not prevent the
card being queued and does not change its pending status.

Required dispatch metadata. Every card must choose exactly how it dispatches:
declare Path claims for pairing eligibility, or declare serial dispatch. Use
comma-separated repo-relative file or directory paths; add-stage refuses
absolute paths, dot segments and empty entries at queue time:

- **Path claims:** scripts/report.sh, docs/report.md
- **Dispatch:** serial
-->
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

## Contract test

<!--
Optional but recommended for any stage with executable acceptance. The assertions are frozen here at authoring time: the orchestrator writes them from the card's intent before the worker runs, the worker makes them pass without editing the block between the AUTOMETTA-CONTRACT-BEGIN/END markers, and the verifier rejects any assertion change whose new digest is not recorded below. The BEGIN marker in the test file names this card (card=<path-to-this-card>). Leave the whole section as "None" for prose-only or throwaway stages. Generate or regenerate the digest with `scripts/check-contract-test-gate.sh print <test-file>` and update the line below in the same commit as any deliberate assertion change. See docs/dispatch-contract.md (Contract tests). -->

- **Test file:** <<contract-test-path-or-None>>
- **Assertions digest:** <<sha256-of-frozen-block-or-None>>

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
