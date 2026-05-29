---
name: decision-mcp-cards
description: MCP-served stage cards design decisions: MCP not HTTP, git SHAs not server versioning, mandatory filesystem fallback, design-only until multi-machine
metadata:
  type: project
---

MCP-served stage cards is the design for delivering a stage card to a worker through an MCP resource rather than a raw file path, in service of future multi-machine running. The decisions below are load-bearing; changing them needs a conversation. See [[decision-sweep-stage]] for the sibling design card and its shape.

**Why MCP, not HTTP**

MCP is already the only tool integration boundary autometta accepts (belief in `docs/philosophy.md`). A bespoke HTTP card endpoint would be a second integration surface to secure, version, and document. Cards as MCP resources reuse the boundary we have committed to rather than adding RPC we have committed against.

**Why git SHAs, not server-side versioning**

Git is the state store. The commit SHA that last touched a card file is a free, audit-backed version token that the server reads rather than invents. A server-side version counter would duplicate state git already holds and create a second source of truth about card identity, which contradicts git-as-state. The `@<version>` in the URI is therefore a git SHA.

**Why fallback to filesystem is mandatory, not optional**

A card is the prompt. If MCP resolution fails and there is no fallback, the stage cannot dispatch and the loop stalls on infrastructure, not on the work. The filesystem path works today and must stay armed so a server outage degrades delivery rather than halting the loop. Operational failures are normal; the fallback is how this one is absorbed.

**Why design-only until a concrete multi-machine use case lands**

v1 single-machine MCP plus filesystem fallback buys nothing the filesystem does not already give us; its only value is readiness for multi-machine, which is not yet a real workload. Building the server before that need is speculative. The helper indirection can land cheaply when wanted; the server waits for a use case.
