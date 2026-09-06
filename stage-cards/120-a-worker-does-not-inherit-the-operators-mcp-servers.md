# Stage card 120: a worker does not inherit the operator's MCP servers

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/120-a-worker-does-not-inherit-the-operators-mcp-servers
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/spawn-worker.sh, scripts/spawn-verifier.sh, scripts/mcp-isolation-smoke.sh, docs/dispatch-contract.md, stage-cards/120-a-worker-does-not-inherit-the-operators-mcp-servers.md
- **Pairing rationale:** cross-family. The change is to the Claude dispatch line; the Codex seat
  verifies by inspecting the process tree of a real dispatch, which needs
  no knowledge of Claude's flag semantics.
- **Type:** Dispatch hygiene. Pipeline-eligible.

## Surfacing concern

On 2026-09-03 the stage 75 worker's only child process was an Obsidian
vault MCP server (`docs/runs/2026-09-03-evening-watch.md:23` in
emergence-lab). `scripts/spawn-worker.sh:256` starts `claude` with no MCP
configuration, so it loads the operator's user-level servers: tool
definitions in every prompt's context, a process per server per dispatch,
and access a card never asked for. Nothing in any card needs them.

## Objective

Claude workers and verifiers start with exactly the MCP servers the
manifest names, and by default none.

## Inputs (read these in your own context)

- `scripts/spawn-worker.sh:240-270` and the matching block in
  `scripts/spawn-verifier.sh`
- `claude --help` for `--mcp-config` and `--strict-mcp-config`
- `docs/dispatch-contract.md`, the dispatch and sandbox section
- the manifest schema (`schemas/manifest.json` or wherever `verifier.claude.transport`
  lives), for where a per-repo MCP allowlist would sit

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. Both spawn scripts pass `--strict-mcp-config --mcp-config <file>` to
   `claude`, where the file is `{"mcpServers":{}}` written to the run's
   scratch area by default, or the path named by a manifest key
   `dispatch.claude.mcp_config` when set.
2. `scripts/mcp-isolation-smoke.sh`: with a fake `claude` on `PATH` that
   records its argv, a worker dispatch and a verifier dispatch both carry the
   two flags and the default file is empty JSON; with the manifest key set,
   the named file is passed. Frozen block around those assertions.
3. `docs/dispatch-contract.md`: one paragraph in the sandbox section, and
   the manifest key documented.

## Constraints

- Codex dispatch lines untouched.
- The SDK routes (`verify-sdk-agent.py`) are out of scope unless they read
  the same config, in which case say so and leave them.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. A real Claude worker dispatch on the operator's machine shows no MCP
   server child processes (`pstree` or `ps -o ppid`), and the transcript's
   first row lists no MCP tools.
2. `scripts/mcp-isolation-smoke.sh` passes; the flag assertion fails against
   the pre-change spawn scripts.
3. `scripts/local-route-smoke.sh` and `scripts/state-writable-smoke.sh` are
   no more red than on clean `dev`.

## Contract test

- **Test file:** scripts/mcp-isolation-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/120-a-worker-does-not-inherit-the-operators-mcp-servers.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/mcp-isolation-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Giving cards a way to request specific servers beyond the manifest key.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If `--strict-mcp-config` is refused by the installed `claude` version,
report the version and use `--mcp-config` with an empty file only, noting
that user-level servers may still load.

## Verifier handoff

Dispatch a real stage in a fixture and look at the process tree; do not
trust the argv smoke alone, since a flag can be present and ignored. Check
the transcript for MCP tool names.

## Family-specific notes

None
