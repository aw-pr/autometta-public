# Stage card 92: the agents panel answers back

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/92-the-agents-panel-answers-back
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 91-the-burn-is-visible-while-it-burns
- **Path claims:** scripts/dashboard.sh, dashboard/dashboard.js, dashboard/dashboard.css, dashboard/index.html, docs/dashboard.md
- **Pairing rationale:** premium pairing for display work, the standing
  feedback rule: cheap tiers game display smokes, so Sol builds the surface
  and the Fable verifier sits where the operator will sit. Same seats as
  cards 69 to 71, whose skeleton this page extends.

## Objective

The UAT feedback asks: "in the agents panel can I click through and
communicate with the agent? That way for headless when we have the
phat-controller orchestrator I can send prompts to that." The mechanism
already exists and this card deliberately adds no new one: card 61's
filesystem bus (`state/phat-controller-inbox/pending/` in,
`state/phat-controller-outbox/` back, journal alongside), which the TUI's
messages page already reads and writes. The dashboard is the missing
window.

Make an agent row in the dashboard's agents panel clickable: a detail view
showing the agent's stage, role, phase, live registry entry and recent
journal lines, with a compose box that drops an operator message onto the
controller inbox addressed to that agent's stage (or to the controller
itself). Delivery stays pull-based: the controller reads the inbox on its
next pass; nothing in this card pushes into a running agent's process.

The write path exists only where a server does. Under `--serve`, the
existing regenerator process (already a `python3 -m http.server` wrapper)
gains a single POST route, bound to localhost, that validates and writes
the message file. On the static or `file://` page, the compose box degrades
honestly: it renders the exact TUI invocation and the message-file path to
use instead, and says why it cannot send.

## Inputs (read these in your own context)

- stage-cards/71-the-operator-talks-to-the-controller.md (the bus contract
  and the TUI page this mirrors)
- scripts/lib/tui/messages.py (how the TUI writes a valid inbox message)
- scripts/dashboard.sh (the --serve half)
- dashboard/dashboard.js and dashboard/index.html (the agents panel)
- docs/dashboard.md (the seam and poll model)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `dashboard/dashboard.js` + `dashboard/index.html` + `dashboard/dashboard.css`:
   clickable agent rows, the detail view, the compose box with its two
   modes (POST when served, copy-me instructions when static). Message
   status feedback after send: accepted (file written) or the error, never
   a silent swallow.
2. `scripts/dashboard.sh`: the localhost-only POST route in `--serve` mode,
   writing the same message shape the TUI writes, into the repo's
   `state/phat-controller-inbox/pending/`. Size-capped (4KB), plain text
   plus the addressed stage id; anything else is rejected with a reason.
   The route dies with the server; no new process, port or daemon.
3. `docs/dashboard.md`: a "talking back" subsection stating the bus path,
   the served-versus-static split, and that delivery is pull-based on the
   controller's cadence, not instant.

## Constraints

- Reuse card 61's bus and card 71's message shape exactly; a second message
  format is a defect, not an option.
- The POST route binds 127.0.0.1 only and exists only while `--serve` runs.
  No auth is added and none is claimed: the boundary is the loopback
  interface, and the doc says so plainly.
- An operator message is advice to the controller, not remote execution:
  the card ships no path by which page input reaches a shell, an agent
  prompt, or an env var. The controller decides what to do with it.
- The page must keep working read-only when the repo has no inbox
  directory yet.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash -n scripts/dashboard.sh` passes.
2. Under `--serve`, composing a message to a named stage writes exactly one
   file under `state/phat-controller-inbox/pending/` that the TUI messages
   page parses and displays without error, and the page reports acceptance.
3. The POST route rejects, with a reason shown on the page: a message over
   the size cap, a missing stage id, and a request from a non-loopback
   address (evidence may be curl against the served port).
4. On the static page (no server), the compose box renders the TUI
   invocation and inbox path instead of a send button, and no network
   request is attempted (shown by the browser console or a fetch stub).
5. A clicked agent row shows stage, role, phase and the registry entry's
   live fields for an in-flight agent from a fixture data.json.
6. `git diff --stat` on the run branch touches only the five claimed paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Pushing prompts into a running agent's process or pane: delivery is the
  controller's pull, full stop. (If herdr is ever adopted, that is a
  different card.)
- Any change to the controller's inbox-reading logic or cadence.
- Authentication beyond the loopback bind.
- The TUI (already has this per card 71).

## Budget

- **Worker wall-clock:** 3000s
- **Verifier wall-clock:** 2400s

## Verifier handoff

Leave the working tree dirty. Report the written message file verbatim, the
TUI messages page rendering it, the three rejection cases with evidence,
and the static-mode fallback rendering.

## Family-specific notes

None
