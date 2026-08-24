# Stage card 60: the controller can see the window

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/60-the-controller-can-see-the-window
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** after 58. That card creates the context seed and the setup
  prompt for spend authority; this card adds a second question to the same
  prompt rather than inventing a second place to configure the role.
- **Pairing rationale:** the credential being read belongs to the Claude
  family, so the other family writes the reader and the Claude side
  verifies that its own token never reaches a log.

## Objective

Autometta meters what it has spent. It cannot see what it has left.

Those are different facts, and the difference cost the queue an hour on
2026-08-24: stage 54's worker ran into an exhausted five-hour window,
exited with an empty log after 24.9M tokens and no handoff envelope, and
the loop recorded a `stalled` stage rather than a quota wall. The budget
file was nowhere near its cap. Nothing in the system knew the window was
nearly gone, so nothing could stop short of it.

The signal exists and is already read on this machine. The AI usage panel
in `~/r/vibe-menuapp` (`Timer/QuotaSources.swift`) reads subscription
utilisation from the endpoint Claude Code itself uses, and Codex
utilisation from its session rollout logs. It reports, per window, a used
percentage and a reset time.

After this card the controller can ask two questions before it dispatches:
how much of this family's window is left, and when does it reset. What it
does with the answers is configured at setup, not hard-coded.

## Inputs (read these in your own context)

- `~/r/vibe-menuapp/Timer/QuotaSources.swift`, the working reference. The
  Anthropic source is `https://api.anthropic.com/api/oauth/usage` with the
  credential read from the Keychain service `Claude Code-credentials`; the
  response carries a `limits` object whose `five_hour`, `seven_day`,
  `seven_day_opus` and `seven_day_sonnet` entries each hold `utilization`
  and `resets_at`. The Codex source reads `used_percent` per window from
  the rollout logs. Read `UsageMonitor.swift` for the polling cadence and
  the failure handling.
- `docs/proposals/orchestrator-role-review.md` and card 58, for where the
  setup question belongs and how the seed carries an answer.
- `scripts/budget.sh`, particularly `budget_pause_until` and
  `budget_pause_active`, and card 52's grace rule for a reset time just
  past.
- `docs/lessons.md` gotcha 11, for what a credential read that blocks on a
  TCC prompt does to an unattended run.

## Deliverables

1. **A quota probe**, one reader both families go through, returning per
   window: family, window label, used percentage, reset time, and an
   explicit unknown when it cannot tell. Autometta owns its own copy
   rather than depending on the menubar app being installed; the endpoint
   and log contract are what is shared, and the doc names the panel as the
   other consumer so the two can be compared when one breaks.
2. **A configured reserve.** The setup prompt from card 58 gains a second
   question: how much of a window to leave unspent, and what to do on
   reaching it. Like spend authority, this varies by run and is not a
   committed default.
3. **A pre-dispatch check.** Before dispatching a role, the controller
   compares that family's window against the reserve and either dispatches,
   or holds and pauses until the window's own `resets_at` rather than an
   operator's estimate of it.
4. **The reading is surfaced** wherever spend already is: the tick log, the
   tmux dashboard's fleet pane, and the web dashboard. A window near its
   limit should be visible before it bites, not diagnosed afterwards.
5. **`docs/observability.md` and `docs/cost-log.md` updated** to say what
   the probe reads, how often, and what an unknown means.

## Constraints

- The credential is read and used. It is never logged, never written to
  state, never included in an envelope, and never passed to a worker or
  verifier. The verifier is expected to look for it.
- The probe is not on the hot path. A read that fails, times out, or
  returns an unknown must leave the loop behaving exactly as it does today
  rather than blocking a dispatch. Fail open, and say so in the log.
- Every credential read carries a watchdog. A Keychain read can block on a
  TCC prompt with nobody there to answer it, which is gotcha 11 in a new
  costume.
- Poll no harder than the panel does, and cache. This is a courtesy
  endpoint, not a metric to scrape.
- A reserve of zero means the feature is off. Off must be a supported
  answer, and must not degrade anything.

## Acceptance criteria

1. The probe returns a parsed reading for the Claude family: window label,
   used percentage and reset time, shown against a live response.
2. The probe returns a reading for the Codex family, or an explicit unknown
   with the reason, and the caller treats the two the same way.
3. A dispatch is held when the family's window is inside the configured
   reserve, and the resulting pause names the window's own reset time.
4. A dispatch proceeds unchanged when the reserve is zero or the reading is
   unknown. Show the loop behaving identically to today in both cases.
5. No credential material appears in any log, state file, envelope, or
   dispatched prompt. Show the grep that proves it.
6. A probe that times out is logged as a timeout and costs the tick
   nothing. Demonstrate with an unreachable endpoint.
7. The fleet pane and the web dashboard both show a window reading, and
   both degrade legibly when it is unknown.
8. Setup asks for the reserve and records the answer in the seed. Show a
   rendered seed and the run that produced it.

## Contract test

Replay stage 54's first attempt with the probe in place and a reserve
configured: the dispatch should be held rather than started, and the pause
should carry the reset time the endpoint reports. The comparison to make is
against what actually happened, which was a worker started into an
exhausted window and 24.9M tokens spent on a stage that recorded nothing.

## Out of scope

- Changing what the budget file counts, or adding a cap per provider. Card
  59 owns the meter; this card reads a different fact entirely and must not
  be confused with it.
- Automatically re-pairing a stage onto the other family when a window is
  short. That is the obvious next move and it is a separate card, because
  choosing a family is a judgement about billing rather than a threshold.
- Any change to the menubar app.

## Budget

- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 60 minutes

## Verifier handoff

Return the live readings for both families, the held dispatch with its
pause and reset time, the unchanged behaviour at reserve zero and at
unknown, the timeout case, the two dashboard surfaces, and the grep showing
no credential material anywhere it should not be.

## Family-specific notes

None
