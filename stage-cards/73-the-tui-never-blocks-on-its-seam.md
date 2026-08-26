# Stage card 73: the TUI never blocks on its seam

## Metadata

- **Authored:** 2026-08-26
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/73-the-tui-never-blocks-on-its-seam
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 72-the-run-page-knows-where-the-run-starts
- **Pairing rationale:** presentation work stays with the premium pair
  that built the TUI. Serial batch, so family alternation for pipeline
  overlap does not apply.

## Objective

The operator ran the landed TUI and reported a blank pane at startup and
dead keys. The cause is structural: `app.py`'s event loop calls
`payload_from_aggregator` inline, a blocking `subprocess.run`, and on this
repo `aggregate-dashboard.sh --repo` takes 37 seconds against a 5 second
poll interval. The loop blocks 37 seconds, renders, listens for keys for
about 100ms, finds `next_poll` already past, and blocks again. The page is
frozen for over 99 percent of its life. Card 74 attacks the 37 seconds;
this card removes the coupling, because a UI that freezes for the length
of its data call is broken at any seam latency.

## Inputs (read these in your own context)

- `scripts/lib/tui/app.py`, the event loop and `payload_from_aggregator`.
- `scripts/lib/tui/render.py`, only as far as adding the loading and
  data-age states.
- `scripts/tui-smoke.sh`, for the capture harness this card's assertions
  extend.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. **The poll leaves the UI thread.** A background worker (Python stdlib
   threading is sufficient) runs the aggregator and hands completed
   payloads to the loop through a queue; the loop never calls the seam
   directly. One poll in flight at a time; a poll that finishes after a
   newer one started is discarded, never rendered over fresher data.
2. **The first frame is immediate.** The page renders inside one second
   of launch with an honest loading state ("first poll running..."), and
   fills in when the payload arrives. No blank pane, ever.
3. **Keys are always live.** Selection, page switches, pinning and quit
   respond during an in-flight poll. `q` exits promptly even mid-poll
   (the worker thread must not hold the exit hostage; daemon thread or
   equivalent, with the terminal still restored cleanly).
4. **Data age is visible.** When the rendered payload is older than the
   poll interval, the status panel shows its age ("data 41s old"), so a
   slow seam reads as a slow seam, never as a fresh page.
5. **A poll failure renders, it does not freeze.** The existing
   `state_error` path still works from the worker thread.
6. **Smoke coverage**: the capture harness gains a stub aggregator that
   sleeps a configurable time, and asserts the first frame appears with
   the loading state before the stub returns, that a key sequence issued
   during the sleep is applied (the resulting frame proves it), that the
   payload frame replaces the loading frame after the stub returns, and
   that the data-age line appears when the stub outlives the interval.
   The assertions measure the app's behaviour; the stub supplies latency,
   never the expected frames.

## Constraints

- Python stdlib only. Threads, not asyncio rewrite; the loop's structure
  stays recognisable.
- No change to `aggregate-dashboard.sh` (card 74 owns the seam's speed;
  the two cards must not collide).
- Curses cleanup stays unconditional on every exit path, including exit
  during an in-flight poll.
- The capture mode (`--capture`, `--fixture`) keeps working unchanged for
  the existing smokes.

## Acceptance criteria

1. With a stub seam sleeping 10 seconds and a 5 second interval, the
   first frame renders within one second showing the loading state.
   The smoke asserts the timing and the frame.
2. Keys sent while the stub sleeps take effect: the smoke pins a card and
   switches pages mid-poll and the frames prove it.
3. `q` during an in-flight poll exits within one second and leaves a
   restored terminal (`stty -a` sane, demonstrated).
4. The data-age line renders when the payload is older than the interval
   and disappears when a fresh payload lands; the smoke shows both frames.
5. A stub that exits non-zero mid-run yields the `state_error` render,
   keys still live. Shown.
6. A stale poll finishing after a newer one is discarded; the smoke
   drives two overlapping stub latencies and asserts the newer payload's
   marker is what renders.
7. Against the real repo (its seam still slow until card 74 lands), the
   TUI launches to a loading frame within one second and responds to
   keys throughout. A wall-clock demonstration in the envelope.
8. All existing TUI smokes pass unchanged.
9. The new smoke passes with locale and TERM pinned, fails on the pre-fix
   tree, and its helpers fail loudly on anything absent.

## Contract test

Launch against a stub seam sleeping 10 seconds at a 5 second interval:
loading frame inside one second, a mid-sleep key sequence honoured and
proven in frames, the payload frame supplanting the loading frame, a
data-age line once the payload outlives the interval, a clean sub-second
quit mid-poll, and the existing capture smokes green throughout.

## Out of scope

- Making the aggregator faster (card 74).
- Multiple concurrent polls or speculative polling.
- Any change to what the seam emits.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the timed first-frame capture, the mid-poll key frames, the quit
timing with the restored terminal, the data-age frames, the state_error
frame, the stale-poll discard proof, the real-repo demonstration, and the
smoke runs before and after.

## Family-specific notes

None
