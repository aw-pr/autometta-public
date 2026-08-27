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
- **Gate:** stage-completed: 58-the-controller-decides-the-scripts-are-its-verbs
  That card creates the context seed and the setup prompt for spend authority;
  this card adds a second question to the same prompt rather than inventing a
  second place to configure the role.
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

**Autometta does not call that endpoint.** It is heavily rate limited, the
panel already polls it about every three minutes, and a second independent
poller on the same machine would contend with the app that is the reason
the reading exists. One caller, many readers: the panel publishes a
snapshot, and everything else reads the snapshot from disk. The Codex side
carries no such constraint, being local rollout logs, and may be read
directly.

That inverts the dependency in the useful direction. Autometta gains a
reading it never pays for, and the panel keeps sole ownership of the
credential and the poll cadence.

After this card the controller can ask two questions before it dispatches:
how much of this family's window is left, and when does it reset. What it
does with the answers is configured at setup, not hard-coded.

## Inputs (read these in your own context)

- `~/r/vibe-menuapp/Timer/QuotaSources.swift`, as a **reference for the
  shape of the data only**, not as something to reimplement. It shows the
  window keys the Anthropic source reports (`five_hour`, `seven_day`,
  `seven_day_opus`, `seven_day_sonnet`), each carrying `utilization` and
  `resets_at`, and how the Codex source derives `used_percent` per window
  from the rollout logs. `UsageMonitor.swift` shows the poll cadence and
  failure handling that this card must not duplicate.
- `docs/proposals/orchestrator-role-review.md` and card 58, for where the
  setup question belongs and how the seed carries an answer.
- `scripts/budget.sh`, particularly `budget_pause_until` and
  `budget_pause_active`, and card 52's grace rule for a reset time just
  past.
- `docs/lessons.md` gotcha 11, for what a credential read that blocks on a
  TCC prompt does to an unattended run.

## Deliverables

1. **A published snapshot contract**, defined here and consumed by a
   reader that makes no network call for the Anthropic family. Default
   location `${AI_QUOTA_DIR:-~/.local/state/ai-quota}/<family>.json`, one
   file per family, each holding `fetched_at`, a `source` string naming the
   publisher, and a `windows` array of `{key, label, utilization,
   resets_at}`. A file absent, unparseable, or older than a configurable
   staleness bound (default ten minutes) is an explicit unknown, never a
   zero and never a reason to block.

   The reader also handles the Codex family, which it may read directly
   from the rollout logs since nothing rate limits those, and presents both
   through one interface so callers do not care which is which.
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

- Autometta makes no request to the usage endpoint, holds no credential
  for it, and reads no Keychain entry for it. If a design seems to need
  one, the design is wrong: the snapshot is the interface. The verifier is
  expected to grep for an endpoint call and a Keychain read and to fail the
  stage on either.
- The probe is not on the hot path. A read that fails, times out, or
  returns an unknown must leave the loop behaving exactly as it does today
  rather than blocking a dispatch. Fail open, and say so in the log.
- Every credential read carries a watchdog. A Keychain read can block on a
  TCC prompt with nobody there to answer it, which is gotcha 11 in a new
  costume.
- Reading a snapshot file is cheap, but reading it once per tick is
  enough. Do not stat it in a loop, and do not make the dashboards
  independent readers on their own timers when one reading per tick can be
  passed to all of them.
- A reserve of zero means the feature is off. Off must be a supported
  answer, and must not degrade anything.

## Acceptance criteria

1. The reader parses a published snapshot for the Claude family and
   returns window label, used percentage and reset time. Show it against a
   fixture snapshot, so the criterion holds whether or not a publisher is
   installed on the verifying machine.
2. The reader returns a reading for the Codex family from the rollout logs,
   or an explicit unknown with the reason, and callers treat the two the
   same way.
3. A dispatch is held when the family's window is inside the configured
   reserve, and the resulting pause names the window's own reset time.
4. A dispatch proceeds unchanged when the reserve is zero or the reading is
   unknown. Show the loop behaving identically to today in both cases.
5. No credential material appears in any log, state file, envelope, or
   dispatched prompt. A published snapshot that wrongly carried a token
   must not be propagated by the reader either. Show the grep that proves
   both.
6. A snapshot that is absent, malformed, or past the staleness bound each
   produce an explicit unknown, are logged as such, and cost the tick
   nothing. Demonstrate all three.
7. The fleet pane and the web dashboard both show a window reading, and
   both degrade legibly when it is unknown.
8. Setup asks for the reserve and records the answer in the seed. Show a
   rendered seed and the run that produced it.
9. No process spawned by autometta contacts the usage endpoint or reads the
   Keychain. Show the grep over the diff and the absence across a live
   tick.

## Contract test

Replay stage 54's first attempt against a fixture snapshot showing the
five-hour window nearly exhausted, with a reserve configured: the dispatch
should be held rather than started, and the pause should carry the reset
time the snapshot reports. The comparison to make is
against what actually happened, which was a worker started into an
exhausted window and 24.9M tokens spent on a stage that recorded nothing.

## Out of scope

- Changing what the budget file counts, or adding a cap per provider. Card
  59 owns the meter; this card reads a different fact entirely and must not
  be confused with it.
- Automatically re-pairing a stage onto the other family when a window is
  short. That is the obvious next move and it is a separate card, because
  choosing a family is a judgement about billing rather than a threshold.
- **The publisher itself.** Writing the snapshot is a change to
  `~/r/vibe-menuapp`, which is outside this run's sandbox and belongs to
  that repo. This card defines the contract and consumes it against a
  fixture; the app is made to conform separately. Until it does, the
  reading is simply unknown and the loop behaves exactly as it does today,
  which is the whole point of criterion 4.

## Budget

- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 60 minutes

## Verifier handoff

Return the readings for both families, the held dispatch with its pause and
reset time, the unchanged behaviour at reserve zero and at unknown, all
three snapshot failure cases, the two dashboard surfaces, and the grep
proving nothing autometta spawns calls the endpoint or reads the Keychain.

## Family-specific notes

None
