# Stage card 14-auth-route-toggle: Per-family auth route switch (subscription default, API opt-in) with 1Password-backed key resolution

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Opus 4.7 <claude-opus-4-7@local> (same-family build by exception)
- **Verifier:** deferred to operator review at commit
- **Pairing rationale:** The work is the new dispatch credential plumbing. Verifying it cross-family before it lands forces a circular dispatch (we would need the very thing being built to dispatch the verifier safely). Operator review on commit, then real cross-family verification on the next dispatched stage that exercises `mode: api`.

## Surfacing incident

The operator's OpenAI ChatGPT subscription token allowance is the immediate constraint — running real dispatches at scale via Codex burns through the plan, while the OpenAI API key sits in 1Password unused. Today every dispatch in this repo runs whatever auth the host's `codex` / `claude` CLIs happen to be logged into (in practice, OAuth subscription for both). There is no per-repo, per-family, or per-dispatch switch.

## Objective

Add a per-family auth route toggle that lets the operator say "Codex on API, Claude on subscription" (or the inverse, or both on API, etc.) per repo, with an env-var override at dispatch time, and the API key sourced from 1Password by default. Default for both families stays `subscription` so existing dispatches are unaffected.

## Inputs

- `scripts/spawn-worker.sh:115` — the `case "$family"` block where codex / claude are launched.
- `scripts/spawn-verifier.sh:117` — the verifier equivalent.
- `bin/autometta:45-126` — the CLI dispatch case block.
- `.publish-guard.local.example` — the canonical template-as-documentation pattern this card mirrors.
- `scripts/check-deps.sh` — confirms `yq` is already a hard dep, so the resolver can use it.

## Deliverables

1. `scripts/auth-route.sh` — resolver. Argument: `<family>` (`codex` | `claude`). Emits shell commands to stdout: either `export OPENAI_API_KEY='...'` / `export ANTHROPIC_API_KEY='...'` or `unset` of the same. On failure, emits an error fragment that exits 1 in the caller's shell.
2. `scripts/auth.sh` — backs `autometta auth status` (per-family mode + redacted key source) and `autometta auth check <family>` (PASS / FAIL / subscription, without spending a token).
3. `bin/autometta` — adds the `auth)` route to the case block and updates the usage block.
4. `scripts/spawn-worker.sh` — invokes `auth-route.sh "$family"` immediately before the `case "$family"` dispatch.
5. `scripts/spawn-verifier.sh` — same pattern.
6. `.autometta.local.yaml.example` — new template file documenting the schema, the auth block, the `op://` / `env:` / `.env.local` key sources, and the env-var override.
7. `docs/setup.md` — new section "7. Auth routes" (and renumber Uninstall to section 8).
8. `memory/decision-auth-route-toggle.md` — decision memory: why subscription is the default, why fail-closed on missing key, why per-family not per-role for v1, why `op://` is the preferred key source, why the LaunchAgent does not auto-inject keys into its plist.
9. `CLAUDE.md` — adds the `eval "$(scripts/auth-route.sh codex)"` line into the documented manual orchestrator dispatch pattern.

## Acceptance criteria

1. `scripts/auth-route.sh codex` in a repo with no `.autometta.local.yaml` prints `unset OPENAI_API_KEY`.
2. `scripts/auth-route.sh claude` in the same conditions prints `unset ANTHROPIC_API_KEY`.
3. With `.autometta.local.yaml` containing `auth.codex.mode: subscription`, the resolver still prints `unset OPENAI_API_KEY`.
4. With `auth.codex.mode: api` and `key_source: env:OPENAI_API_KEY` and the env var pre-exported, the resolver prints `export OPENAI_API_KEY='...'`.
5. With `auth.codex.mode: api` and no resolvable key, the resolver emits an error fragment containing `auth-route: failed to resolve OPENAI_API_KEY` and the caller's shell exits 1.
6. `AUTOMETTA_CODEX_MODE=subscription scripts/auth-route.sh codex` returns `unset` regardless of the manifest content.
7. `autometta auth status` prints a per-family table with mode and key source.
8. `autometta auth check codex` reports either `subscription`, `PASS` (with redacted credential), or `FAIL` (with the error path). It does not print the raw key.
9. `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh` invoke the resolver before the `case "$family"` dispatch; the resolver's `eval` is at the right line (see Deliverables 4, 5).
10. The cd-fix at `9e282f3` is not reverted (regression guard).
11. `.autometta.local.yaml.example` covers every documented `key_source` form (subscription / api+op / api+env / fallback).
12. No files outside the deliverables set are modified — except this stage card itself.

## Out of scope

- Per-role auth (codex worker on subscription, codex verifier on api). Future card if it bites.
- LaunchAgent plist key injection. The plist stays env-free; the resolver runs at tick time under the Aqua session and reaches `op` via the GUI 1Password helper.
- `autometta auth check --smoke` that hits a real API endpoint. The cheap probe (op-read success / env-var presence) is in scope; the real ping is not.
- Key rotation. The operator manages this in 1Password.

## Budget

- **Worker wall-clock:** 30 minutes (orchestrator-led same-family build).
- **Verifier wall-clock:** n/a — operator review at commit.
