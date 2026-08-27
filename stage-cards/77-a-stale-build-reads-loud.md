# Stage card 77: a stale build reads loud

## Metadata

- **Authored:** 2026-08-26
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/77-a-stale-build-reads-loud
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** the premium display pair again: the deliverable
  is a warning an operator must notice, and the detection already
  exists. Cross-family, fresh codex window.

## Objective

Card 36 (now superseded) spent three attempts and 76.5M tokens on a
problem whose root was silent drift: subscribers dispatch against the
installed Homebrew keg, the keg had fallen behind the checkout, and
nothing on any screen said so. The 2026-08-23 incident recorded the same
class in the other direction. The durable fix the operator asked for is
not another recovery card, it is a standing warning: **when a repo is
running an out-of-date build, every surface an operator looks at says
so.**

The detection exists already. `scripts/check-installed-build.sh`
compares the installed keg against the checkout file by file, states
which root the LaunchAgent tick actually executes, and exits 0 on
agreement, 1 on drift naming each differing file, 2 when a side is
unreadable. This card wires that verdict into the observability the
last two days built, rather than inventing a second detector.

## Inputs (read these in your own context)

- `scripts/check-installed-build.sh`, the existing detector; do not fork
  its logic.
- `scripts/aggregate-dashboard.sh`, the data seam every surface reads.
- `scripts/alert-statuses.sh`, the single definition of the
  alert-worthy set (card 43's discipline: one definition, every
  renderer follows).
- `scripts/lib/repo-ticker-render.py`, `scripts/lib/fleet-ticker-render.py`,
  `scripts/lib/tui/render.py`, the surfaces.
- `scripts/heartbeat.sh`, if the check is best run on its cadence; the
  card leaves the cadence choice to the worker, justified in the
  envelope (per tick is acceptable now the seam costs a quarter second,
  but the check itself walks two trees, so measure it first).

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. **The verdict joins the aggregate payload, additively**: per repo,
   whether the executing root is stale against the checkout, the two
   shas (installed, checkout HEAD), and when the check last ran.
   Existing consumers keep their payload unchanged.
2. **Every operator surface renders it when it fires**: the repo
   ticker, the fleet view (per subscriber), and the TUI status panel
   show a loud one-line warning naming both shas (for example
   `BUILD STALE installed 496c7cc, checkout ae099a4`). Silence when
   current; this is a warning, not a status line that always renders.
3. **The check runs on a cadence that cannot silently lapse** (tick or
   heartbeat, worker's call with the measurement that justifies it),
   and a check that errors (exit 2) renders as `build check unreadable`
   rather than as freshness.
4. **Smoke coverage**: fixture roots that agree, drift, and are
   unreadable; asserts the warning appears on all three surfaces on
   drift, is absent when current, shows the unreadable state honestly,
   and that the payload figures come from the one detector script (no
   second comparison implementation anywhere).

## Constraints

- Do not fork or reimplement the comparison; `check-installed-build.sh`
  is the detector. Extend it only if a machine-readable output mode is
  missing, keeping its human mode and exit contract intact.
- Additive payload change only.
- Python stdlib and bash only.
- The smoke supplies fixture data and never the expected verdict.

## Acceptance criteria

1. On a fixture with drifted roots, the repo ticker, fleet view and TUI
   status panel each show the warning naming both shas. Three captures.
2. On agreeing roots, no build line renders on any of the three.
3. On an unreadable root, all three render the unreadable state, and it
   is visually distinct from both current and stale.
4. The aggregate payload carries the verdict, shas and check time;
   existing consumer smokes pass unmodified.
5. Exactly one comparison implementation exists; the smoke asserts the
   renderers and aggregator contain none of their own.
6. The cadence decision is stated in the envelope with the measured
   cost of one check.
7. Smokes pass with locale and TERM pinned, fail on the pre-fix tree,
   helpers fail loudly.

## Contract test

Three fixture states (current, stale, unreadable) rendered on all three
surfaces at 80 and 119 columns: the stale warning names both shas, the
current state renders nothing, the unreadable state renders as its own
condition, and every figure traces to one invocation of the detector.

## Out of scope

- Auto-reinstalling the keg or any remediation; this card only makes
  the condition impossible to miss.
- Emergence-lab recovery (superseded with card 36; that repo fixes its
  own stages).
- The HTML dashboard (follow-on when the TUI treatment transfers).

## Budget

- **Worker wall-clock:** 75 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the three-state captures on all three surfaces, the payload
diff showing the additive fields, the single-implementation check, the
cadence measurement, and the smoke runs before and after.

## Family-specific notes

None
