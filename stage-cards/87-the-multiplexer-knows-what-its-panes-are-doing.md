# Stage card 87: the multiplexer knows what its panes are doing

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/87-the-multiplexer-knows-what-its-panes-are-doing
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** docs/herdr-spike.md
- **Pairing rationale:** this is an evidence-gathering spike, not a design
  decision: run the commands, record what happened, and refuse to guess where
  a probe failed. That is workhorse tier. The value is entirely in whether the
  report distinguishes a verified result from an assumed one, which is what a
  Claude verifier reading it cold will catch. No code lands, so the usual
  worker-family alternation does not matter here.

## Objective

Dispatch currently learns that a worker finished by polling its handoff
envelope. That is blind to the case an envelope cannot express: an agent
stopped on an approval prompt, alive and waiting, indistinguishable from one
still thinking. herdr claims to make that state observable per pane
(idle / working / blocked / done / unknown) and to expose it to scripts as
`herdr agent wait --until <state>`.

Establish whether that claim holds for the two agent families this repo
dispatches, and whether the local session tooling in ~/Scripts/agent-sessions
could sit on herdr rather than tmux. Produce evidence, not an opinion. This
card decides nothing and changes no dispatch code.

## Inputs (read these in your own context)

- docs/dispatch-contract.md
- docs/observability.md
- schemas/ (the handoff envelope schema only)

The session tooling under review lives outside this repo and outside this
card's tree. Read it through the operator, not by path: the card records what
must be probed, and the operator supplies the local paths at dispatch time.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `docs/herdr-spike.md`, at most 1500 words, five sections:
   - **What was run:** herdr version, install route, and the exact commands
     issued, in order.
   - **Agent detection:** whether herdr classifies a live Claude Code pane and
     a live Codex pane, and what each of the five states looked like in
     practice. State explicitly which states were observed and which were not
     reached.
   - **The blocked probe:** the result of `herdr agent wait --until blocked`
     against an agent genuinely sitting on an approval prompt, for each
     family. This is the single result the card exists for.
   - **Reboot restore:** whether herdr's native agent session restore brings a
     Claude and a Codex conversation back by session reference after the
     server is stopped, or whether the session id must still be recorded
     externally.
   - **Verdict:** adopt, adopt-partially, or reject, with the one finding that
     decides it.
2. A `Limits` subsection at the end of the verdict naming every claim in the
   document that was read from vendor documentation rather than observed on
   this machine.

## Constraints

- Nothing under `scripts/`, `bin/`, or `state/` changes. This card produces one
  document.
- No dispatch code is wired to herdr. A recommendation to do so is in scope;
  doing it is not.
- Every state transition reported must have been observed. A state the probe
  never reached is reported as not reached, never inferred from the docs.
- herdr stays on its stable channel (`herdr channel set stable`). Do not use
  the preview channel for any probe.
- No probe touches a remote host or an SSH session.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the
stage.

1. `docs/herdr-spike.md` exists, is at most 1500 words, and carries the five
   sections and the `Limits` subsection named above.
2. The blocked probe is reported for both agent families, each with the exact
   command and its exit status. A family that could not be probed says so and
   says why; silence about a family is a failure.
3. Every state named as observed has a command in the "What was run" section
   that would produce it. The verifier traces at least three such claims back
   to their command.
4. The `Limits` subsection is non-empty and names at least the reboot-restore
   claim if that was not tested by an actual server stop.
5. `git status --porcelain` shows changes confined to `docs/herdr-spike.md`.
6. `grep -c '—' docs/herdr-spike.md` returns 0.
7. No absolute home-directory path appears in the document.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Migrating any Autometta dispatch path off its current polling.
- Any change to the handoff envelope schema.
- The local `~/Scripts/agent-sessions` launchers themselves. Their portability
  to herdr is a question this card answers about herdr; the port is separate
  work in another repo.
- Anything touching the WindWatch VM or another remote host.
- Benchmarking herdr against tmux for speed or memory.

## Budget

- **Worker wall-clock:** 3000s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the herdr version probed, the exit status
of each `herdr agent wait` invocation, and the list of states that were never
reached.

## Family-specific notes

The blocked probe is family-asymmetric by construction. Claude Code raises an
approval prompt only when not launched with `--dangerously-skip-permissions`,
and Codex only when not launched with `--dangerously-bypass-approvals-and-sandbox`.
The local launchers pass both flags, so a blocked state cannot occur under
them. The probe must start each agent without its bypass flag, which is the
opposite of how this repo dispatches. Say so in the document: if blocked is
unreachable under normal dispatch flags, that is the finding, and it weakens
the case for adoption considerably.
