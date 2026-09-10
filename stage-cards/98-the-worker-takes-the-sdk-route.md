# Stage card 98: the worker takes the SDK route

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/98-the-worker-takes-the-sdk-route
- **Worker effort:** high
- **Verifier effort:** high
- **Requires network:** true
- **Verifier panel:** false
- **Gate:** stage-completed: 23-sdk-controller-experiment
- **Path claims:** scripts/worker-sdk-experiment.py, tests/worker-sdk-experiment/, docs/experiments/worker-sdk-postmortem.md, memory/decision-worker-sdk-experiment.md, docs/philosophy.md
- **Pairing rationale:** cross-family, the card-23 pattern: Codex builds a
  deliberately minimal prototype; Claude verifies that the prototype's
  failure modes are honestly reported, because part of the expected value
  is a negative result.
- **Type:** Experiment-with-postmortem. Not production wiring, whatever
  the outcome.

## Surfacing concern

Workers are CLI by design and the reasons are structural: the CLI harness
supplies the agentic tool loop, and `codex exec --sandbox workspace-write`
supplies the role boundary that makes worker self-verification
structurally impossible (load-bearing belief: the sandbox is the role
boundary). The SDK route, proven for verifiers in cards 15a-16 and 28 and
made the default in card 90, offers things the CLI cannot: per-message
live usage (card 91 shows it for verifiers only), prompt-cache control,
and structured envelopes without log parsing. The question "can workers
ride the SDK too?" will keep coming up (operator raised it 2026-08-31).
Answer it once, bounded, with a postmortem as decision memory, per the
card-23 pattern and the gating in
`docs/design/orchestrator-sdk-transport.md`.

## Objective

Build a deliberately minimal `scripts/worker-sdk-experiment.py` that runs
one worker dispatch through the Claude Agent SDK: an agentic session with
file-edit and shell tools scoped to a scratch worktree, given a synthetic
stage card, expected to produce the deliverable and write the handoff
envelope. Run it against two synthetic stages, one that succeeds and one
that must fail (a deliverable outside the scoped tree). Write a postmortem
comparing the SDK worker against the CLI worker across five axes: sandbox
enforcement, tool-loop fidelity, observability parity (registry,
heartbeat, log), live usage and prompt-cache behaviour, and failure
recovery when the process dies mid-turn. The postmortem is the
deliverable; the script is the apparatus. A codex-side worker thread is
assessed in the postmortem from the card-23 findings and the SDK
documentation, not built, unless building it costs nothing extra.

## Inputs (read these in your own context)

- stage-cards/23-sdk-controller-experiment.md and its postmortem
  (docs/experiments/sdk-controller-postmortem.md), which this card is
  gated on
- docs/design/orchestrator-sdk-transport.md (the gating and manifest
  surface this would eventually extend)
- scripts/spawn-worker.sh (the CLI baseline being compared)
- scripts/verify-sdk.py (the proven SDK auth-route and envelope handling
  to reuse)
- docs/observability.md (the registry contract an SDK worker would have
  to satisfy)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/worker-sdk-experiment.py`: the minimal SDK worker prototype.
   No LaunchAgent or tick integration, a hard wall-clock cap, docstring
   marked `EXPERIMENT, do not productionise`. Reuses the op-fetch
   auth-route contract from the verifier SDK entrypoints; no new secrets
   handling.
2. `tests/worker-sdk-experiment/stage-A.md`: synthetic stage, trivial
   in-tree deliverable.
3. `tests/worker-sdk-experiment/stage-B.md`: synthetic stage whose
   deliverable path lies outside the scoped worktree, so the sandbox
   axis is tested by an attempt that must be refused.
4. `docs/experiments/worker-sdk-postmortem.md`: Hypothesis; What was
   built; What was observed (both stages' logs); Comparison matrix over
   the five axes; Decision and reasoning; What changes about future
   design conversations. The Decision concludes one of "workers stay
   CLI", "workers may take the SDK route", or "hybrid per family", in
   plain words.
5. `memory/decision-worker-sdk-experiment.md`: the decision memo, linked
   to [[decision-per-role-family-sdk-transport]].
6. `docs/philosophy.md`: at most five additive lines referencing the
   postmortem under the sandbox-is-the-role-boundary belief.

## Constraints

- The experiment never touches real `state/`, dispatches nothing through
  the tick, and is not installable: no reference from `bin/autometta`,
  any plist, or `scripts/install-homebrew-local.sh`.
- The scoped worktree is a throwaway under the tests directory or /tmp;
  the experiment must not write the repo's working tree beyond its
  claimed paths.
- Subscription auth only; the experiment must not require an API key.
- End-to-end under 30 minutes wall-clock, capped in the script.
- The postmortem reaches an explicit Decision; ambivalence fails the
  card.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `scripts/worker-sdk-experiment.py --help` prints usage and exits 0;
   `python3 -m py_compile` passes.
2. Stage A run: the deliverable exists in the scratch worktree and a
   handoff envelope validating against the worker envelope shape was
   written by the SDK session itself.
3. Stage B run: the out-of-tree write was refused, the refusal is in the
   log, and the envelope reports failure honestly.
4. The postmortem has every required section, the matrix covers exactly
   the five axes, and the Decision is explicit.
5. Live usage: the postmortem states whether per-message usage reached
   the registry entry shape card 91 defined, with evidence.
6. The decision memo exists and links as specified.
7. The experiment is unreferenced by the installable surface (criterion
   9 of card 23, same check).
8. `git diff --stat` on the run branch touches only the claimed paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Productionising an SDK worker, whatever the Decision; that is a
  separate card triggered by the postmortem.
- The codex-side SDK worker build (assessed on paper unless free).
- Any change to spawn-worker.sh, tick.sh, or the manifest surface.
- Cross-machine or multi-repo dispatch.

## Budget

- **Worker wall-clock:** 3000s
- **Verifier wall-clock:** 2400s

## Verifier handoff

Leave the working tree dirty. Report both synthetic runs' evidence
verbatim, the sandbox-refusal log line, the live-usage finding, and
confirm the Decision section reaches a plain-words conclusion.

## Family-specific notes

The prototype uses the Claude Agent SDK on the subscription route proven
by card 89. The codex SDK thread model differs (cumulative usage totals,
card 91 notes); the postmortem must not generalise Claude findings to
codex without saying so.

## Re-brief note (2026-08-31 22:45 BST, minder)

Same auth-route finding as card 23's re-brief note: build on the
`claude-agent-sdk` package, never the raw `anthropic` client, which 429s
instantly on subscription OAuth. `scripts/verify-sdk.py` is the broken
pattern, not prior art. A first-request 429 means the auth route, not
load; stop and report rather than retry.


## Re-brief note (2026-09-01, orchestrator) — before first dispatch

Card 23 landed while this card sat queued, and what it found is the reason
this note exists. Read
[`docs/experiments/sdk-controller-postmortem.md`](../docs/experiments/sdk-controller-postmortem.md)
section "The sandbox is the finding" before you write any code: it cost three
attempts and roughly seventeen million tokens to learn, and none of it needs
learning twice.

A Claude Agent SDK session spawned from inside a dispatched role hits two
sandbox walls, one at a time.

1. **The socket.** Codex's `workspace-write` denies network to every shell
   command a model starts. The session cannot reach the API and dies on
   `FailedToOpenSocket` before its first tool call. This card now declares
   `- **Requires network:** true`, which lifts it, so you should not see this
   one. If you do, say so plainly rather than working around it.

2. **The session directory.** With the socket open, the session next dies on
   `EPERM ... mkdir '~/.claude/session-env/<session-id>'`: the same sandbox
   confines writes to the workspace, and Claude Code wants a per-session
   directory under `$HOME`. **This one is not solved, and solving it is part of
   your job.** The obvious candidate is pointing the session's config directory
   inside the run worktree, which is writable, via `CLAUDE_CONFIG_DIR` or by
   setting `HOME` for the child process. Try it, and report what actually
   happened: if it works, say which knob and quote the run; if it does not,
   quote the error and stop rather than escalating the sandbox.

**Do not widen the sandbox to make this pass.** `Requires GUI: true` would drop
the role to `danger-full-access` and hand the agent the machine; that would
make the experiment succeed by removing the very confinement it is supposed to
be measured under, which destroys the result. If the SDK worker can only run
unconfined, that is the finding, and the postmortem should say so.

Card 23's Decision was keep cron+tick, and its central evidence was that a
resident session needs the dispatch sandbox opened before it can start. Your
axis "sandbox enforcement" is where the worker-side version of that question
gets answered, so treat it as the load-bearing row of your matrix rather than
one of five. If the honest answer is that the SDK worker cannot be confined the
way the CLI worker is, say it in plain words in the Decision.

The rest of the card is unchanged. `scripts/verify-sdk.py` remains prior art
for envelope handling only: it drives the raw `anthropic` client against the
Messages API, which is refused instantly with a 429 on subscription OAuth. Use
`claude-agent-sdk` for anything that must talk to a model.
