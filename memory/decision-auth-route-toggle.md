---
name: decision-auth-route-toggle
description: Per-family auth route switch (subscription default, api opt-in) via the canonical op-fetch wrapper from the auth-route-security skill. Mode in .autometta.local.yaml, refs in op-refs.sh + op-refs.local.sh, SA token from ~/.config/op/service-account.env.
metadata:
  type: project
---

Card 14 adds a per-family auth route toggle on top of the
`auth-route-security` skill's canonical pattern. Every dispatch runs
through `op-fetch`, which exec's the child with `env -i` plus an
allowlist plus only the named refs the route requires.

**Two-layer config:**

1. **Mode** lives in `.autometta.local.yaml` (gitignored under `*.local`)
   in the *subscribed* repo:
   ```yaml
   auth:
     codex:    { mode: api }            # or subscription
     claude:   { mode: subscription }
   ```
   Override per dispatch via `AUTOMETTA_<FAMILY>_MODE`.

2. **References**:
   - `op-refs.sh` — committed at the autometta repo root; placeholder refs
     (`op://YOUR_VAULT/...`); searches for a local override in
     `$AUTOMETTA_LOCAL_REFS`, then `~/.config/autometta/op-refs.local.sh`
     (XDG, recommended), then `<repo-root>/op-refs.local.sh` (dev only).
   - `op-refs.local.sh.example` — committed template documenting the
     XDG path as canonical.
   - `~/.config/autometta/op-refs.local.sh` — gitignored, mode 0600;
     real op:// references. The XDG location is the one place visible
     to both the dev checkout and the brew-installed CLI.

3. **Service-account token** for op-fetch comes from `$OP_SERVICE_ACCOUNT_ENV`
   (default `~/.config/op/service-account.env`). op-fetch sources it,
   uses it per call, never exposes it to the child.

4. **Sibling CODEX_HOME** at `${AUTOMETTA_CODEX_HOME:-~/.codex-api-only}`
   carries an `auth.json` with `auth_mode: "apikey"`. Codex prefers its
   own auth.json over the `OPENAI_API_KEY` env var; without isolation,
   the default chatgpt-mode auth at `~/.codex/auth.json` overrides any
   op-fetch'd key and the dispatch silently bills the subscription.
   Spawn scripts export `CODEX_HOME` and pass it through op-fetch via
   `--pass CODEX_HOME` whenever codex is in api mode. They fail closed
   if the sibling is missing or has the wrong `auth_mode`. One-time
   setup is in `docs/setup.md` section 7 and lessons.md gotcha #8.

**Why subscription is the default:**

- Existing dispatches were all on subscription. Flipping the default
  would silently start API spending the moment this lands.
- Subscription is the safer failure mode under config drift.

**Why every dispatch (including subscription) goes through op-fetch:**

- `env -i` strips any stray `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` in
  the parent shell. Without this, a stale export from `.zshenv` or a
  forgotten test session could silently flip a "subscription" dispatch
  to API billing.
- Per the skill's route-isolation rule, "Codex CLI" route fetches
  nothing (uses `~/.codex/auth.json`) and must have `OPENAI_API_KEY`
  absent; "Claude OAuth" route similarly must have `ANTHROPIC_API_KEY`
  absent. Wrapping every launch in op-fetch enforces that by
  construction.

**Why op-fetch rather than `op read` + `export`:**

- `op read` returns the value to the parent shell, where it leaks into
  every child via inheritance. The earlier (now-superseded) iteration
  of card 14 used this pattern and was wrong.
- `op-fetch` reads the SA token, calls `op read`, then `exec env -i`
  with the resolved value — the parent shell never sees it.
- `op-fetch` is the canonical wrapper from the auth-route-security
  skill; flagging "any remaining use of `op run --env-file` or raw
  `op read` in dispatch paths" is part of the skill's review checklist.

**Why no `key_source` in `.autometta.local.yaml`:**

- The earlier iteration put `key_source: op://...` directly in the
  manifest. That conflated mode (per-repo) with refs (per-machine),
  and put real op:// strings outside the placeholder file the skill
  designates. The current shape is correct: the manifest carries
  only the mode, references live in `op-refs.local.sh`.

**Why fail-closed on a missing ref / placeholder:**

- The operator chose `mode: api` to keep their subscription quota; if
  the resolver silently fell back to subscription, the dispatch would
  burn the very tokens the toggle was meant to spare. A loud abort
  before the agent launches is the only correct behaviour.

**Why per-family, not per-role, for v1:**

- Per-family covers the current use case ("OpenAI sub tokens scarce,
  use API for Codex; Claude Pro plentiful, keep that on subscription").
- Per-role (e.g. codex worker on subscription, codex verifier on api)
  is a real future need but deferred until it bites.

**LaunchAgent interaction:**

- API keys are NOT auto-injected into the macOS LaunchAgent plist.
  The plist is plain text in `~/Library/LaunchAgents/` and a key
  written there leaks into Time Machine and any process that can read
  the file.
- Instead, the LaunchAgent-driven tick invokes `op-fetch` at tick
  time. The SA token is read from `~/.config/op/service-account.env`
  which works under the Aqua user session.

Cross-reference: [[decision-orchestrator-commits-on-verifier-pass]],
[[decision-phat-controller-no-daemon-subscriber-registry]],
[[decision-launchagent-over-cron-on-macos]],
[[decision-agent-observability-registry]].
