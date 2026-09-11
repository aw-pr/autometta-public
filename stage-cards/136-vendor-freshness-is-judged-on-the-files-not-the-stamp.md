# Stage card 136: vendor freshness is judged on the files, not the stamp

## Metadata

- **Authored:** 2026-09-11
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** GPT-6 Astra <gpt-6-astra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/136-vendor-freshness-is-judged-on-the-files-not-the-stamp
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Gate:** stage-completed: 135-an-overnight-reserve-is-a-percentage-not-a-curfew
- **Dispatch:** serial
- **Pairing rationale:** Astra-assessment card, the second of two in this
  repo for the 2026-09-12 weekend slate (see card 135 for the slate's
  purpose). Same seats and the same reason: bash control-plane code against
  an orchestrator-written oracle, Sonnet running the oracle. Gated on 135
  and serial because both touch `scripts/tick.sh`, and because the two
  defects were found stacked in one log and the verifier of this card
  should read that log with 135 already landed.
- **Type:** Harness defect. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

Two code paths decide whether a subscriber's vendored copy of the dispatch
contract is stale, and neither looks at a file. `warn_if_vendor_stale`
(`scripts/tick.sh:2914-2940`, card 48) compares the stamp's `vendored_from`
sha with the autometta checkout's HEAD and logs `stale vendor: <repo> holds
the contract from X, autometta is at Y; run: autometta refresh-repo <repo>`
on every mismatch. `scripts/aggregate-dashboard.sh:338-348` (card 66) makes
the same sha comparison and sets `vendor_stale`, which the fleet ticker
(`scripts/lib/fleet-ticker-render.py:178,262-265`) renders as a
`vendor-stale` row. The check that does compare files,
`scripts/autometta-vendor-check.sh`, is vendored into every subscriber and
called by none of this.

So every autometta commit flags every subscriber, byte-identical files or
not. emergence-lab's own handoff records restamping at `58fa586` with all
six files "already byte-identical, so the recurring stale-vendor warning
was pure noise". On 2026-09-07 the noise cost a run twenty minutes: the tick
logged the line above, once per tick, over an empty dispatch log, and the
operator read it as the cause, ran `autometta refresh-repo` (0 new, 0
updated, 6 unchanged), restamped, committed, and only then found the real
stop, which is card 135. The line never said dispatch continues, and the
code comment at `scripts/tick.sh:2904-2907` that says it is "only ever a
warning" is not what an operator sees.

## Objective

Staleness means a vendored file differs from upstream, judged the way
`autometta-vendor-check.sh` already judges it (digest match, or a filled
`<<placeholder>>`). A stamp whose sha is behind while every file is current
is noted once as a stamp lag, with the count of current files, never called
stale, and never surfaced as a fleet warning. Every line either path logs
says in words that dispatch continues and names the one command that
restamps.

## Inputs (read these in your own context)

- `scripts/vendor-staleness-smoke.sh`, the frozen oracle; it fails at
  acceptance 1 on clean `dev`, which is correct
- `scripts/vendor-set.sh`, the single vendored-set definition and the
  digest / filled-placeholder helpers that already exist
- `scripts/autometta-vendor-check.sh:56-95`, the file-based classification
  to reuse, not reimplement
- `scripts/tick.sh:2895-2940`, `warn_if_vendor_stale` and its once-per-pass
  guard
- `scripts/aggregate-dashboard.sh:330-350`, the `vendor_stale` flag
- `scripts/lib/fleet-ticker-render.py:170-270`, where the flag is rendered
- `scripts/refresh-repo.sh:185-235`, which already restamps when nothing
  changed; do not duplicate it
- `docs/dispatch-contract.md:835-850`, the documented log line

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/vendor-set.sh`: one function, `autometta_vendor_drifted_files
   <repo-root> <source-root>`, that prints the repo-relative path of every
   vendored file that is missing locally or differs from upstream by more
   than filled placeholders, and prints nothing when the copy is current.
   It is the only classifier; `autometta-vendor-check.sh`, the tick and the
   dashboard all call it.
2. `scripts/tick.sh`: `warn_if_vendor_stale` calls the classifier. With no
   drifted files and a stamp sha that differs from HEAD it logs one line
   containing `vendor stamp behind`, `<N> vendored files current`,
   `dispatch continues` and `autometta refresh-repo <repo>`. With drifted
   files it logs one line containing `stale vendor:`, every drifted path,
   `dispatch continues` and the same command. A matching stamp over current
   files logs nothing, as today. The tick never writes into the subscriber
   tree: restamping stays the operator's `refresh-repo`, because a tick that
   dirtied a subscriber would trip that repo's dirty-tree guard on the next
   pass.
3. `scripts/aggregate-dashboard.sh`: `vendor_stale` is true only when the
   classifier prints something. Add `vendor_files_current` (integer) and
   `vendor_drifted` (array of paths) beside it; keep `vendor_from`.
4. `scripts/lib/fleet-ticker-render.py`: the `vendor-stale` row names the
   drifted files instead of the sha pair, and a behind-stamp-only repo gets
   no row.
5. `scripts/autometta-vendor-check.sh`: reports through the shared
   classifier and prints the same `vendor stamp behind` note when files are
   current but the stamp is not, exit 0. Its exit codes and its existing
   ORPHAN / GONE / FILLED / DRIFT / RETIRED lines are otherwise unchanged;
   the vendored copies in every subscriber are refreshed by the operator's
   `autometta refresh-all-repos` after this lands, not by this card.
6. `docs/dispatch-contract.md`: the documented log line is updated to both
   forms, with the sentence that a stamp lag is cosmetic and drift is what
   the word stale means.
7. `scripts/vendor-staleness-smoke.sh` passes. Scaffolding outside its
   markers is yours; the frozen block is not.

## Constraints

- One classifier. If after this card two files compute "is this vendored
  copy current" independently, the card has failed regardless of the
  smoke.
- The tick and the dashboard must not write to any subscriber's tree.
- Do not change the stamp format or the vendored set.
- Do not edit any frozen `AUTOMETTA-CONTRACT` block.
- Codex sandbox: the smoke reads this checkout, writes only under
  `mktemp -d` and the fixture's `AUTOMETTA_HOME`, and needs no network or
  GUI.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/vendor-staleness-smoke.sh` passes on the run branch and
   fails at "current files are not reported stale" against clean `dev`.
   Record both runs.
2. `grep -rn 'autometta_vendor_drifted_files' scripts/` shows the definition
   in `scripts/vendor-set.sh` and call sites in `scripts/tick.sh`,
   `scripts/aggregate-dashboard.sh` and `scripts/autometta-vendor-check.sh`,
   and `grep -n 'vendored_from_raw" == "\$autometta_current_sha' scripts/aggregate-dashboard.sh`
   finds nothing.
3. `bash scripts/refresh-smoke.sh`, `bash scripts/fleet-ticker-smoke.sh` and
   `bash scripts/dashboard-liveness-smoke.sh` are no more red than on clean
   `dev`.
4. Run `scripts/autometta-vendor-check.sh` from a scratch subscriber built
   the way the smoke builds one (current files, stamp `0000000`): exit 0,
   output contains `vendor stamp behind` and `6 vendored files current`.
   Append a line to one vendored file and rerun: exit 1, output names that
   file.
5. `git diff dev --stat` touches nothing under any subscriber path and no
   file outside this card's deliverables.
6. `bash -n` passes on every touched shell file and `python3 -m py_compile
   scripts/lib/fleet-ticker-render.py` exits 0.

## Contract test

- **Test file:** scripts/vendor-staleness-smoke.sh
- **Assertions digest:** `sha256:ed72e685c408d186310ef10e35dad611296c8b84d9a750e3e10ee95b0aabdf0b`

The file and its frozen block are already written by the orchestrator. Do
not author, extend or edit the block: satisfy it by changing the
implementation. If you become convinced an assertion is wrong, stop and
surface it as a blocker; the verifier recomputes this digest and fails the
stage if the assertions moved.

## Out of scope

- Restamping any subscriber. The operator runs `autometta refresh-all-repos`
  once this lands.
- Changing what the vendored set contains or how `refresh-repo` decides to
  copy.
- The curfew defect that shared the 2026-09-07 log; that is card 135.

## Budget

- **Worker wall-clock:** 75 minutes
- **Verifier wall-clock:** 40 minutes

## Escalation

If reusing `autometta_only_filled_placeholders` for acceptance 4 of the
smoke proves impossible without changing how `autometta-vendor-check.sh`
classifies a filled template, stop and report with the diff that shows why.
Loosening the placeholder rule would let a refresh overwrite a subscriber's
fills, which is the one thing that path must never do.

## Dispatch envelope

The worker envelope carries the usual `status`, `summary` and touched-file
list, plus an **Astra scorecard** block the slate is scored on:

- `deliverables_landed`: which of deliverables 1-7 are complete on this
  attempt, by number.
- `tokens_used`: the worker's own reading of its total tokens for the
  attempt, from its final usage line.
- `sandbox_blocked`: anything the Codex `workspace-write` sandbox refused
  (command and error text), or `none`.
- `oracle_first_failure`: which assertion in
  `scripts/vendor-staleness-smoke.sh` failed first before your change.

## Family-specific notes

Codex: `scripts/aggregate-dashboard.sh` reads `$AUTOMETTA_HOME/subscribers`
and writes `$AUTOMETTA_HOME/dashboard/data.json`; the smoke points
`AUTOMETTA_HOME` at its fixture so nothing reaches the live controller home.
Do not pass `--add-dir` for `$HOME/.autometta`.
