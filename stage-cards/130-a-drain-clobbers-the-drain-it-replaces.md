# Stage card 130: a drain clobbers the drain it replaces

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/130-a-drain-clobbers-the-drain-it-replaces
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Path claims:** scripts/drain.sh, tests/drain-scope-smoke.sh, docs/budget.md, stage-cards/130-a-drain-clobbers-the-drain-it-replaces.md
- **Pairing rationale:** cross-family. The worker seat designs a merge policy
  for a shared host-level file; the verifier's job is to construct the
  concurrent case the worker did not think of, which is easier from outside
  the design.
- **Type:** Budget correctness. Host-level shared state.

## Surfacing concern

`cmd_start` in `scripts/drain.sh` builds the drain file from its own arguments
and moves it into place:

```sh
jq -n ... '{version: 1, token_cap_total: $cap, expires_at: $expires, ...}' \
  > "$tmp_path"
mv "$tmp_path" "$drain_path"
```

`drain_path` is `$(budget_controller_home)/drain.json` — one file for the whole
host, shared by every repo that subscribes. A second `drain start` replaces the
first wholesale: its cap, its window, and its `repos` scope. No merge, and no
warning that a live drain covering someone else's repo has just been revoked.

This happened on 2026-09-06. A drain was started for emergence-lab at
10:06:04Z; a twenty-stage autometta batch started its own drain thirty seconds
later. `drain status` then reported an ACTIVE drain — correctly, but for the
other repo. emergence-lab silently fell back to its resting 100M cap with
98.7M already spent, leaving 1.3M of headroom while a stage was running. The
operator found it by reading the file, not from any signal.

Two properties are missing and they are separable. The file cannot express two
concurrent drains at all. And nothing tells the second caller that a first
exists.

## Inputs (read these in your own context)

- `scripts/drain.sh` — `cmd_start`, `cmd_status`, `cmd_end`
- `scripts/budget.sh` — `budget_drain_file`, the expiry-retirement path around
  line 123, and how a repo resolves its cap against the drain's `repos` scope
- `docs/budget.md` — what the drain is documented to promise

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `drain start` refuses to silently replace a live drain. At minimum it must
   report the drain in force — its cap, expiry and scope — and require an
   explicit flag to replace it. Decide whether replacement or merge is the
   right default and argue it in this card.
2. Union semantics for the `repos` scope where the two drains are compatible:
   starting a drain for repo B while a drain covers repo A should be
   expressible without revoking A. State what "compatible" means for the cap
   and the expiry, and what happens when it does not hold.
3. `drain status` says which subscribed repos are covered by the drain in
   force and which are not. Today it prints the scope list; a repo not on it
   reads as covered by a casual glance.
4. A smoke script covering: start over nothing; start over a live drain
   without the flag, which must refuse; start over a live drain with it; a
   second repo added to a live drain; expiry retirement with two repos in
   scope; and `status` naming an uncovered subscriber.

## Constraints

- The file stays a single JSON document at the same path. Do not introduce a
  directory of per-repo drains — every reader would need changing and the
  expiry-retirement path in `budget.sh` is shared.
- Backward compatible: a `version: 1` file written by the current script must
  still be read correctly by the new one.
- No change to resting caps or to the daily runaway cap.
- No change to how a repo resolves its cap beyond honouring the scope more
  accurately.
- Do not raise any cap as part of this card.

## Acceptance criteria

1. The repo's own verify gate is green.
2. The smoke script passes and covers all six cases as separately named
   assertions.
3. The 2026-09-06 sequence is reproduced as a test: drain for repo A, then a
   drain for repo B thirty seconds later, and repo A must still be covered
   afterwards or the second call must have refused.
4. A `version: 1` file from the current script is read without error.
5. `drain status` output names an uncovered subscriber in the case where one
   exists.
6. `docs/budget.md` describes the new semantics, including what happens on a
   refusal.

## Contract test

- **Test file:** `tests/drain-scope-smoke.sh`
- **Assertions digest:** to be declared by this card on landing. The file is
  new; compute the digest of its frozen block and write it into this card's
  Metadata in the same commit.

## Out of scope

- Changing resting caps, the runaway cap, or `window_reserve`.
- Per-repo drain files.
- The dashboard's rendering of drain state, beyond what `status` prints.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 40 minutes

## Escalation

If honouring a union scope turns out to require a cap semantics decision the
card does not settle — whose cap applies when two repos are covered by one
number — stop and put the question to the operator. Picking one silently is
how the original defect got shipped.

## Verifier handoff

Construct the concurrent case yourself, from two shells, and confirm the first
repo is still covered afterwards. Criterion 3 is the whole card; the rest is
scaffolding around it.
