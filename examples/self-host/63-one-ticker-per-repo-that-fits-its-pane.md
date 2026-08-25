# Stage card 63: one ticker per repo, and it fits its pane

## Metadata

- **Authored:** 2026-08-25
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/63-one-ticker-per-repo-that-fits-its-pane
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** a rendering card judged on captures, so the family
  that did not lay it out reads the captures back.

## Objective

The repo ticker answers one question: **do I need to intervene?** Today it
answers a different one, badly. It renders every registered repo when the
operator is watching one queue, it truncates columns to roughly 40
characters inside a pane that is 119 wide, and its FAILURES table is
unbounded, running to roughly 45 rows covering 90 days and five repos, so
the pane cannot be read without scrolling.

None of that is a space problem. It is a decision problem: nothing has
decided what belongs in a live view and what belongs in a report.

After this card the ticker shows one repo, fits its pane without scrolling,
and every line earns its place by bearing on whether to act.

## What the ticker shows, in order

### 1. NOW, the live stage

The headline. Stage id in full, the phase (worker running, verifying,
landing), the acting family and identity in short form, elapsed against the
card's declared wall-clock budget, tokens spent on this stage so far, and
when verifying, the attempt number against the cap.

Elapsed against budget is the progress indicator. It is a real measurement:
`budget_seconds` is already on every record in `state/active-agents/` and
the card's `Worker wall-clock` is already parsed by `scripts/tick.sh`. Past
100 per cent it reads as over budget rather than resting at 99.

### 2. NEXT, the queue

Opens with the counts, because "how much is left" is the first thing an
operator wants and nothing currently says it: cards done and cards
outstanding, with the number currently escalated called out separately so
outstanding is not read as work in progress.

Then the next three stage ids with the family that will work each. Nothing
else.

### 3. ESCALATIONS, what is outstanding

Only items that are waiting on a human right now: a halt or pause with its
reason and expiry, and any stage sitting in `stalled` or `verifier_failed`
that has not already been re-queued, with its preserved wip pin so the work
is findable.

This section is also the feedback loop for the unattended mandate. An
escalation is by definition something the loop could not resolve on its
own, so a recurring one is evidence that the controller's mandate is drawn
too narrowly, and a section that empties itself overnight is evidence it is
drawn about right. Nothing else in the system records that.

### 4. SPEND AND LOSS, one table

Spend and loss belong together, priced, because the interesting number is
not what was spent but what was spent for nothing:

```
                       tokens      est cost
  spent today            8.8M        $13.00
  lost today             2.6M         $4.10
  lost 7d              137.9M       $XXX.XX
  cap                  150.0M   host-default (6% used)
```

Loss is non-pass dispatch spend, which `scripts/aggregate-dashboard.sh`
already computes per row along with `cost_usd_est`. It is currently only
rendered as a bare token count at the bottom of the failures table.

### 5. FRESHNESS, one line

How long since the last tick, stated plainly, and made loud past a stated
threshold. On 2026-08-24 the tick stopped firing for 57 minutes and nothing
on screen said so.

## Constraints

- **One repo. No fleet data.** A fleet view may return later as its own
  session; it is not this pane's job and must not be folded back in.
- **No fabricated progress.** Elapsed against budget measures time spent,
  not work done, and the ticker must not imply otherwise. Do not derive a
  percentage from log growth: codex streams and claude writes in one burst
  at the end, so the same number means opposite things per family.
- **The cost column is currently wrong for OpenAI and must say so.** Codex
  dispatches record `output_tokens` as zero on nearly every row, so any
  total is close to Anthropic-only. Label it until card 59 lands. A
  confidently wrong currency figure is worse than an annotated one.
- **Bounded height.** The healthy view fits without scrolling. Sections
  that have nothing to say render nothing, not an empty frame.
- **Use the width available, proportionally.** Measure the terminal and
  allocate column widths against it, the way lazygit does: each column
  declares a minimum and a share of the remainder, and grows or shrinks
  with the window. A 119-column terminal must not truncate a stage id to
  40 characters. When space genuinely runs out, degrade by dropping whole
  columns in a stated order rather than cutting every column at once.
- **One process draws the screen.** Do not use tmux panes as the layout
  engine. Splitting the view across rigid panes is what forces each
  fragment to render blind to the others and to the space they collectively
  have. The renderer owns the whole window and lays out within it.
- **Keep the data and the renderer separable.** `aggregate-dashboard.sh`
  already produces the numbers as JSON; the renderer consumes that and
  nothing else. This card ships a bash renderer, but the boundary must be
  clean enough that a richer TUI could replace it later without touching
  the data path or re-deriving a single figure.
- The failures history moves to a command rather than a pane. Nothing is
  deleted; it stops competing for live space.

## Acceptance criteria

1. The repo ticker renders one repo and contains no data from any other
   subscriber. Show the capture.
2. A healthy run fits in its pane with no scrollback, at 119 columns and at
   80. Show both captures.
3. NOW shows a live stage with elapsed against the card's budget, and the
   figure matches the card's declared wall-clock and the agent record.
   Verify by arithmetic, not by eye.
4. A stage past its budget reads as over budget, not as 99 per cent or 100
   per cent.
5. ESCALATIONS lists only outstanding items, shows a wip pin where one
   exists, and renders nothing at all when there is nothing outstanding.
   The counts line agrees with it: escalated is a subset of outstanding and
   the arithmetic is shown.
6. SPEND AND LOSS shows spent and lost side by side with estimated cost,
   and carries the OpenAI under-reporting caveat.
7. FRESHNESS states the age of the last tick and is visibly loud past the
   threshold. Demonstrate both states.
8. No stage id is truncated at 119 columns. Columns resize with the
   terminal rather than sitting at fixed widths: show the same view at 80,
   119 and 160 columns and the differing allocations. At 80, show which
   columns drop and in what order.
9. The renderer reads only the aggregated JSON. Show that no figure is
   recomputed inside the renderer.
10. The failures history is reachable as a command and the live view no
    longer renders it.
11. The offline smoke sweep passes, with locale and TERM pinned as card 49
    established.

## Contract test

Render the ticker against a fixture holding: one stage in flight past its
budget, one stalled stage with a wip pin, one re-queued stage that must not
appear in ESCALATIONS, a halt with a reason, and a tick log two hours old.
Every section must be legible in one pane at 80 and at 119 columns.

## Out of scope

- The fleet view. Dropped from this pane by decision; a separate session is
  a later card if it is wanted.
- Fixing the codex token accounting, which is card 59. This card labels the
  gap, it does not close it.
- The web dashboard.
- **Adopting a TUI framework.** Ink, blessed, bubbletea and ratatui would
  all give focus, scrolling and resize events for free, and all of them
  require a runtime and a dependency tree that `CLAUDE.md` rules out: "no
  build, no test suite, and no package manifest - do not invent one". That
  is a decision to take deliberately, not a side effect of a layout card.
  This card ships a bash renderer behind a clean data boundary so the
  decision stays open.

## Budget

- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 60 minutes

## Verifier handoff

Return captures at both widths for a healthy run and for the fixture, the
arithmetic behind the elapsed-against-budget figure, the empty and populated
ESCALATIONS states, both freshness states, the spend and loss table with its
caveat, and the smoke sweep result.

## Family-specific notes

None
