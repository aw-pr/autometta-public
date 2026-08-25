# Stage card 68: a pipeline pair runs two stages at once

## Metadata

- **Authored:** 2026-08-25
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/68-a-pipeline-pair-runs-two-stages-at-once
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** the tick is bash and the change is bounded but
  concurrency-shaped; the codex family has landed the last two tick.sh
  stages first attempt, and the claude family verifies with no stake in
  the design.

## Objective

The tick runs one stage in flight per repo, so a run's wall-clock is the sum
of every worker plus every verifier. The verifier is the long pole (62 to 70
minutes against workers of 7 to 60), which means nearly half of a run's
clock time is a worker slot sitting idle under a running verifier. The
2026-08-24/25 autometta batch took two calendar days for this reason and no
other: the tokens were the same either way.

`skills/autometta-run-design/SKILL.md` section 4 already defines the
contract this card implements: a **pipeline pair** is two adjacent stages
where worker N+1 may dispatch while verifier N is still running, permitted
only under declared preconditions, with a strict ordered landing. The skill
declares; nothing in the tick yet executes. This card is the mechanism.

The failure asymmetry is what makes the landing tractable, and it is worth
restating because it is the design's centre: if stage N **fails**, nothing
landed and dev never moved, so N+1 fast-forwards exactly as it does today.
The only new work is the case where N **passes** and N+1 must move onto the
new dev.

## Inputs (read these in your own context)

- `skills/autometta-run-design/SKILL.md`, section 4, the contract being
  implemented. Where this card and the skill disagree, stop and escalate
  rather than picking one.
- `scripts/tick.sh`: `current_stage` selection, `ensure_run_worktree`, the
  landing fast-forward, `budget_gate_dispatch` call sites.
- `scripts/add-stage.sh`, the gate parser, for how a card metadata line
  becomes machine-readable state (the path-claims line follows its pattern).
- `docs/tick-loop.md`, which must describe the pair when this lands.
- `docs/incidents/2026-08-24-run-lessons-log.md` entry 17: the verifier
  completion signal must be pid-checked, and this card widens the number of
  live agents, so that check is a precondition here, not an optional fix.

## Deliverables

1. **A `Path claims:` metadata line on the stage card**, parsed at queue
   time like `Gate:` is, holding the paths a stage may modify. A card with
   no claims line simply never joins a pipeline pair; the parser refuses a
   claims line it cannot parse, at queue time, the same refusal shape as an
   unparseable gate.
2. **Dispatch-under-verifier, bounded at one pair.** While stage N is in
   its verifier phase, the tick may dispatch worker N+1 when ALL hold:
   both stages carry path claims and the claims are disjoint; the two
   worker families differ; and remaining budget headroom covers two
   dispatches at the repo's p95 from `state/cost-log.jsonl`. At most two
   stages are ever in flight; there is no deeper nesting.
3. **Per-stage flight state replaces the single `current_stage` assumption**
   wherever the pair needs it: reap, heartbeat, and landing must each
   address the stage they mean, not "the" stage. The single-flight path
   through the code stays the default and stays behaviourally unchanged
   when no pair is active.
4. **Ordered landing.** N lands before N+1 is considered, always. If N
   failed, N+1 lands by plain fast-forward. If N landed, N+1 is rebased
   onto the new dev only when the two diffs are file-disjoint (verified
   against the actual diffs, not the declared claims); the rebase is
   refused and escalated as a controller escalation on any overlap or
   conflict. No conflict is ever resolved headlessly.
5. **Drop to serial on failure.** Any FAIL or stall in an active pair
   disables pairing for the repo until the affected stage's re-brief lands;
   the tick says so in its log when it does it.
6. **The verifier completion signal is pid-checked before it is consumed**
   (run-lessons entry 17), for both members of a pair and for the
   single-flight path.
7. **An offline smoke in the shape of `scripts/gate-smoke.sh`**: fixture
   repo, two claimed cards, no auth, no network, no spend. It must cover:
   pair formed when preconditions hold; refused on overlapping claims, on
   same-family workers, and on thin headroom; N-fails-then-N+1-ffs;
   N-lands-then-N+1-rebases when disjoint; escalation on a manufactured
   conflict; and drop-to-serial.
8. **Docs:** `docs/tick-loop.md` gains the pair's lifecycle;
   `docs/setup.md` mentions the claims line; the run-design skill's
   "mechanical status" paragraph is updated to say the mechanism exists.

## Constraints

- The dispatch contract is untouched: one card per dispatch, sandbox as the
  role boundary, cross-family verification. A pair is two ordinary
  dispatches overlapped, not a new kind of dispatch.
- `budget_gate_dispatch` still guards every spawn individually, on top of
  the pair's headroom precondition, and the pair adds no new place where
  spend can start without it.
- No daemon, no lock server: the pair is coordinated through `state.yaml`
  and the existing `state/.tick.lock`, same as everything else.
- Pairing is opt-in per adjacent pair via path claims. A repo whose cards
  carry no claims behaves exactly as today, byte-for-byte in its tick log.

## Acceptance criteria

1. A card's `Path claims:` line is parsed at queue time into stage state;
   an unparseable line is refused at queue time. Show both.
2. With two claimed, disjoint, family-alternating cards and ample headroom,
   the tick dispatches worker N+1 while verifier N runs. Show the tick log
   and both live registrations.
3. Overlapping claims, same-family workers, or headroom under two p95
   dispatches each independently prevent the pair, with the reason in the
   tick log. Show all three refusals.
4. N fails, N+1 lands by fast-forward. Show it.
5. N lands, N+1's file-disjoint diff is rebased and lands; a manufactured
   file overlap is refused and escalates instead of rebasing. Show both.
6. A FAIL in an active pair drops the repo to serial and the tick log says
   so; pairing resumes after the re-brief lands.
7. The smoke passes offline and fails on the pre-fix tree.
8. With no claims lines present, a full fixture run produces a tick log
   with no pairing decisions in it: the single-flight path is unchanged.
9. The verifier artefact is only consumed after the writer's pid is gone,
   in both single and paired flight. Show the check.

## Contract test

On the fixture repo, run one full pipeline pair end to end: dispatch N,
enter its verifier phase, dispatch N+1 under it, land N, rebase and land
N+1, with the smoke asserting the ordered landing and both stage records
completed. Then rerun the same fixture with claims removed and show the
serial log unchanged.

## Out of scope

- Deeper nesting than one pair, DAG scheduling, and any cross-repo
  coordination (cross-repo parallelism already works and needs nothing).
- Pre-dispatch spend estimation. The p95 headroom rule reads history only.
- Retrofitting claims onto existing completed cards.

## Budget

- **Worker wall-clock:** 150 minutes
- **Verifier wall-clock:** 60 minutes

## Verifier handoff

Return the queue-time parse and refusal, the live pair evidence, the three
precondition refusals, both landing paths, the escalation on conflict, the
drop-to-serial log lines, the smoke before and after, the unchanged serial
log, and the pid-checked consumption evidence.

## Family-specific notes

None
