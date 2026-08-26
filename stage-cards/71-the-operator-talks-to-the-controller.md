# Stage card 71: the operator talks to the controller

## Metadata

- **Authored:** 2026-08-26
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/71-the-operator-talks-to-the-controller
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 70-the-history-page-covers-every-card
- **Pairing rationale:** same seats as cards 69 and 70; the page extends
  the same skeleton. Serial batch, so family alternation for pipeline
  overlap does not apply.

## Objective

Page 3 of the TUI: the controller's record, and a way to talk back. Card 61
already built the mechanism, and this card deliberately adds no new one:
the controller journals every decision to
`state/phat-controller-journal.jsonl`, reads operator messages from
`state/phat-controller-inbox/pending/`, archives them to `processed/`, and
answers into `state/phat-controller-outbox/`. The filesystem is the message
bus; this page is a window onto it plus a way to drop a file into it.

The signed-off mock (docs/proposals/instrumentation.md holds the brief):

```
┌─[0]─Controller ────────────────────────────────────────────────────────────────────────────────────────────────┐
│ 07:41  decision  dispatched worker for 68-pipeline-pair (sol, attempt 2)                                        │
│ 07:38  outcome   verifier PASS on 67-outlier-says-so; committed f1637a2                                         │
│ 07:12  refusal   inbox msg-014 asked to raise cap — outside mandate, replied in outbox                          │
│ ── inbox ───────────────────────────────────────────────────────────────────────────────────────────────────────│
│ you   06:55  why did card 36 escalate three times?                                                              │
│ ctrl  07:02  attempts hit verifier_attempt_cap; acceptance needs a network the sandbox denies. Parked.          │
│ > _                                                                                    (writes to inbox/, enter)│
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Inputs (read these in your own context)

- `docs/proposals/instrumentation.md`, the operator's brief.
- Cards 69 and 70's deliverables under `scripts/lib/tui/` and
  `scripts/tui.sh`.
- `scripts/phat-controller.sh`: `pc_journal_path`, `pc_inbox_dir`,
  `pc_inbox_pending_dir`, `pc_inbox_processed_dir`, `pc_outbox_dir`, the
  journal row shape, and the inbox message format `pc_inbox_scan` expects.
  The page must write what the controller already reads; the controller is
  not modified to suit the page.
- `docs/` material from card 61 describing the record and inbox contract,
  if present.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. **The journal strip**: tab `[3]` renders the tail of the controller
   journal for this repo, newest last, one line per entry: time, kind
   (decision, outcome, refusal), and the entry's own summary text.
   Scrollable with `j`/`k`; a bounded window, with "and N earlier" where
   rows were withheld.
2. **The conversation strip**: operator messages and controller replies
   interleaved by time, drawn from the inbox (pending and processed) and
   outbox. A pending message not yet read shows as such; a refusal shows
   as a refusal.
3. **The input line**: `m` (from any page) or focusing the input on page 3
   opens a single-line composer; `enter` writes the message as a file in
   `state/phat-controller-inbox/pending/` in exactly the format
   `pc_inbox_scan` consumes, `esc` cancels. The page confirms the write by
   rendering the pending message, never by claiming success it did not
   observe.
4. **Freshness honesty**: the controller reads its inbox at the start of a
   pass, so a reply arrives on the next controller pass, not now. The
   input line's confirmation says so ("queued for the controller's next
   pass"), and the conversation strip refreshes on the same poll interval
   as the rest of the TUI.
5. **One seam discipline, adapted**: journal, inbox and outbox are the
   message bus itself, so this page reads those files directly through one
   small reader module (not scattered opens), and touches nothing else on
   disk. Writes are confined to `pending/`. The reader tolerates a missing
   journal or empty dirs on a repo the controller has never minded (fresh
   subscriber) and renders an honest empty state.
6. **Smoke coverage** (`tui-messages-smoke.sh` or an extension of the card
   69 smoke): fixture journal, inbox and outbox; asserts the interleaving
   order, the pending and refusal renderings, the empty state, that a
   composed message lands in `pending/` byte-compatible with what
   `pc_inbox_scan` parses (assert by running the real parser over it, not
   a copy of its regex), and the bounded journal window with its
   "and N earlier" line.

## Constraints

- Python stdlib and bash only.
- **Do not modify `phat-controller.sh`.** If the inbox format is awkward to
  produce, that is a finding for the envelope, not a licence to change the
  consumer.
- No daemon, no socket, no attach to any live session. Files only.
- Pages 1 and 2 are settled by their own cards; the shared skeleton may be
  extended, not reshaped.
- The smoke asserts against the real `pc_inbox_scan` parsing, never a
  duplicated pattern.

## Acceptance criteria

1. Tab `[3]` renders journal and conversation strips from a fixture repo
   with six journal entries, two operator messages (one pending, one
   processed), one controller reply and one refusal. Show 119 and 80
   column captures.
2. Interleaving is by time and correct against the fixture; pending and
   refusal states are visibly distinct.
3. Composing a message writes one file into `pending/`, rendered
   immediately as pending with the queued-for-next-pass note; the smoke
   feeds that file to `pc_inbox_scan` (the real function, sourced) and it
   parses.
4. `esc` cancels without writing; the smoke asserts `pending/` is
   unchanged.
5. The empty state on a fresh fixture repo renders honestly (no crash, no
   fabricated rows), and says what will populate it.
6. The journal window is bounded with "and N earlier" when the fixture
   journal exceeds it, and no strip pushes the page past the pane at any
   of the three widths.
7. All reads go through the one reader module; writes touch only
   `pending/`. Verified against the code, not the claim.
8. The smoke passes with locale and TERM pinned, fails on the pre-fix
   tree, and its helpers fail loudly on anything absent.
9. `phat-controller.sh` is untouched (`git diff --stat` shows no change to
   it).

## Contract test

Against a fixture repo carrying six journal entries, a pending message, a
processed message with its outbox reply, and a refusal: render page 3 at
80, 119 and 160 columns with correct interleaving and distinct states;
compose a message and prove the written file parses under the real
`pc_inbox_scan`; cancel a second compose and prove nothing was written;
render the fresh-repo empty state.

## Out of scope

- Modifying the controller, its mandate, or its pass cadence.
- Attaching the Claude TUI or any interactive session to the headless
  agent; the file bus is the whole mechanism.
- Notifications when a reply lands (the poll refresh is the mechanism).
- Multi-line composition.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return the width captures, the interleaving check against the fixture, the
compose-and-parse proof under the real `pc_inbox_scan`, the cancel proof,
the empty state, the bounded-journal evidence, the reader-module check, the
untouched-controller diffstat, and the smoke before and after.

## Family-specific notes

None
