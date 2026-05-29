# Design: MCP-served stage cards

Design-only. No code ships with this document. Implementation, if pursued, is a future card gated on a concrete multi-machine need (see migration path).

## Problem statement

Stage cards live on disk at `examples/self-host/*.md` (or the repo's configured globs). The dispatch contract assumes the worker can read the card by path, and `tick.sh` resolves that path with `stage_card_for_id`. This is fine on one machine. The moment autometta runs across two machines, three questions appear that the filesystem cannot answer on its own: which copy of a card is canonical, how is a stale copy detected, and how is a mid-flight edit propagated to a worker that has already read the path. MCP is the documented tool integration boundary for autometta. Serving cards as MCP resources, rather than as raw file paths, gives one named endpoint that answers those three questions while git stays the store of record.

## URI scheme

A card is addressed as:

```
stage://<repo>/<stage-id>@<version>
```

`<version>` is the git commit SHA that last touched the card file, short form. Literal example:

```
stage://autometta/22-mcp-served-cards-design@30faa66
```

Omitting `@<version>` resolves to the card as of the server's current `HEAD` (or working tree, see below). Pinning a version makes a dispatch reproducible and lets a verifier confirm it read the same bytes the worker did, which closes the card-sync race (lessons gotcha 2) by construction rather than by serialised writes.

## Server responsibilities

The server is read-only with respect to card storage. It exposes exactly:

- `resources/list`: enumerate the repo's cards as `stage://` URIs, one per card file matched by the configured globs.
- `resources/read`: given a `stage://` URI, return the card body. Unversioned reads come from the working tree; versioned reads come from `git show <sha>:<path>`.

The server has no write surface. A worker cannot create or edit a card through MCP. Card authorship stays a git operation by a human or orchestrator, exactly as today. The server is a view over git, not an owner of card state. Versioning is therefore not a feature the server implements; it reads the version git already records.

## Consumption by tick.sh (with fallback to filesystem)

Today `tick.sh` calls `stage_card_for_id "$repo_root" "$stage_id"` and hands the returned path to `spawn-worker.sh` / `spawn-verifier.sh`. The change is a single indirection. A new helper `scripts/resolve-card.sh <repo_root> <stage_id> [manifest]` returns a local file path either way:

1. If the repo manifest sets `cards.transport: mcp` (and the env override `AUTOMETTA_CARDS_TRANSPORT` does not say otherwise), the helper issues an MCP `resources/read` for `stage://<repo>/<stage-id>` against the locally configured card server, writes the returned body to a predictable path `/tmp/autometta-card-<stage-id>.md`, and prints that path.
2. If the manifest is unset, or the transport is `filesystem`, or the MCP call fails for any reason (server down, timeout, unknown URI), the helper falls back to the existing `stage_card_for_id` lookup and prints the on-disk path.

`tick.sh` replaces its direct `stage_card_for_id` calls with `resolve-card.sh`. Every other line (budget parsing, the prompt path passed to the spawn scripts, the verifier handoff) is unchanged because the contract is still "a worker reads a card at a path". The fallback is not optional. A failed MCP resolution must never stall a stage; it degrades to the filesystem path that works today.

## Relationship to "filesystem is the message bus"

This is a refinement, not a contradiction. The belief says one stage card per dispatch, the card path is the prompt, nothing is in flight. The load-bearing part is that a dispatch carries exactly one immutable unit of work and that nothing buffers between worker and verifier. MCP-served cards preserve both. The card is still one addressable unit, and pinning `@<version>` makes it more immutable than a bare path, not less. The distinction is that a card is an input the orchestrator authors before the dispatch, whereas handoff envelopes and verifier artefacts are messages the agents produce during the dispatch. The bus, the thing that must stay on the filesystem so a tick can read it, restart, and resume, is the message traffic in `state/handoffs/` and `state/verifiers/`. Those stay on disk untouched by this design. Cards are read-only inputs; serving a read-only input through a named endpoint that still reads from git changes how the worker fetches the prompt, not what the message bus is or where it lives. Conclusion: MCP-served cards refine card delivery; the filesystem remains the message bus for everything the agents emit.

## Multi-machine implications

This is the payoff, not the v1 scope. Once a card resolves through an endpoint rather than a path, the endpoint can be remote. A worker on machine B asks the same `stage://` URI and gets the canonical bytes the server reads from git, so "which copy is canonical" has one answer: whatever ref the server serves. Staleness is detectable because the version token is a git SHA, so a worker can be pinned and a verifier can assert the match. None of this is designed here. v1 is a single-machine server plus filesystem fallback. Multi-machine is the consequence of having the indirection in place, to be specified in its own card when a real two-machine workload lands.

## Migration path

Opt-in per repo, no big-bang, mirroring how card 14 added per-family auth modes to `.autometta.local.yaml`. A repo with no `cards.transport` key behaves exactly as today, filesystem only. A repo that sets `cards.transport: mcp` routes through `resolve-card.sh` with the filesystem fallback always armed. There is no flag day and no repo is forced onto MCP. The helper indirection lands first and is a no-op for every existing repo; the server is built and adopted later, per repo, when wanted.

## Smallest-possible-prototype card outline

**Stage NN-mcp-cards-proto** (single machine, read-only):

- **Objective:** a local MCP server that exposes this repo's `examples/self-host/*.md` as `stage://` resources, plus `scripts/resolve-card.sh` with mandatory filesystem fallback, behind `cards.transport: mcp`.
- **Deliverables:** `scripts/mcp-card-server` (read-only, no card framework dependency without justification per constraints); `scripts/resolve-card.sh`; a one-line `tick.sh` change swapping `stage_card_for_id` for `resolve-card.sh`; `.autometta.local.yaml.example` gains a `cards.transport` key; `docs/setup.md` note.
- **Acceptance:** `resolve-card.sh` returns the same card bytes with the server up and with it killed (fallback proven); a pinned `stage://...@<sha>` read matches `git show <sha>:<path>`; an unknown URI falls back rather than stalling; no existing repo behaviour changes with the key unset.
- **Out of scope for the prototype:** remote transport, auth, multi-machine sync, `resources/list` pagination.

This fits on one page and lifts directly into an implementation card.
