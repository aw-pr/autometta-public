# Benchmarks

Bench runs that exercise the autometta dispatch contract end-to-end against a real target repo. Each bench has its own directory (`bench-NNN/`) containing a brief, a scorecard, and one lane sub-directory per orchestrator family that ran it.

## Layout

```
benchmarks/
├── README.md          # this file
└── bench-NNN/
    ├── brief.md       # task spec + acceptance command + scoring hints
    ├── scorecard.md   # the rubric tooled with empty cells, filled in after
    ├── claude/        # Claude (Opus / Sonnet orchestrator) lane
    │   └── bench-summary.md
    └── codex/         # Codex CLI orchestrator lane (may be empty until run)
```

## What is being benchmarked

Not raw single-shot code generation. The thing on trial is the orchestrator's ability to drive the autometta dispatch contract: authoring the stage card, dispatching workers at the right tier, running cross-family verification, integrating diffs, banking lessons, and stopping at the right boundary.

The bench briefs are deliberately multi-stage so the orchestrator has to use the contract rather than a single prompt. Same target, two orchestrator families, same scorecard, real diff with a machine-checkable acceptance command.

## Why these live in autometta

The bench runs are the fastest signal on whether changes to the contract (or the phat-controller loop on top) have made it harder or easier to drive. Lessons banked in `memory/` cross-reference specific bench entries.

Source of truth for the raw bench tasks themselves is the [`bench-marks`](https://github.com/tw-one/bench-marks) repo; the copies in this directory are sanitised snapshots taken at the point of the run.
