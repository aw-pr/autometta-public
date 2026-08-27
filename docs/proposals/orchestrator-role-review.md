# The controller is a seeded agent, not a script

Operator design review, 2026-08-24, after card 54 landed. Supersedes the
control flow card 54 shipped; the mechanism it shipped is kept.

## What card 54 built, and why it is the wrong shape

`scripts/phat-controller.sh` is a script that occasionally asks an agent for a
verdict. It enumerates four remediations in bash, scans for two stage
statuses, and dispatches an agent for exactly one narrow judgement: which
kind of FAIL is this. The script decides and acts.

Two things fell out of that shape on the evening it landed:

- The mandate manifest is not a mandate. It says so in its own header: it
  tunes thresholds and cadence only, and the four actions are fixed in the
  script. An operator at configure time can turn dispatch off and change a
  cap. They cannot say what the role is for.
- The blocker that actually happened was not on the list. Stage 54's first
  attempt went `stalled` with `worker_envelope_missing_after_exit`. The only
  occurrence of the string "stalled" in `phat-controller.sh` is inside the word
  "installed". Preserving the stranded work, correcting the `state` symlink
  the worker left behind, re-briefing, requeueing, and re-pairing the stage
  away from a spent subscription were all outside its mandate. On that
  evidence the queue would have sat stalled until morning.

The list was short because an enumerated list is what a script can hold. The
remit wanted is the initiative an orchestrator session actually exercises,
and initiative does not enumerate.

## The inversion

An agent that occasionally calls scripts, rather than a script that
occasionally calls an agent.

The role is seeded at configure time with a persona, a mandate, and the
repo facts it would otherwise rediscover. It decides. What remains of
`phat-controller.sh` becomes its verbs: preserve stranded work to a wip branch,
requeue, detect a stale halt, merge an awaiting integration, run the
smokes. Those are tested and worth keeping. The scan-and-choose-remediation
loop on top of them goes.

Per card 56 the role is named **phat-controller**, the name that card frees
from the tick loop. "Warden" does not survive this proposal.

## What bounds it

Authority is bounded by a short negative list rather than an action
enumeration, because the recoverable actions do not need enumerating and
the unrecoverable ones are few.

The governing distinction: the controller may change **what is recorded and
where**, never **what was asked for or whether it was met**. Anything in the
first class is auditable and revertible in git. Anything in the second is
the record of intent, and a queue-minder that can edit intent can make any
stage pass.

Forbidden, without exception:

1. Editing a card's acceptance criteria, objective, or specification. It
   proposes instead, in the `PROPOSED-AMENDMENT` form card 54 already
   defined, and the proposal waits for a human or an interactive session.
   This is the anti-gaming rule and it is the reason for the whole list.
2. Verifying its own dispatches. Cross-family verification stands.
3. Rewriting history, pushing non-fast-forward, or moving a publish branch
   outward.
4. Lifting its own spend caps. It works inside the envelope or it stops.
5. Resolving a merge conflict. Conflicts surface.

Everything else the role can reach is in git, reversible, and attributable.

## Spend authority is set at configure time

The right level varies by run, by hour, and by day of the week, so it is
not a constant that belongs in a committed default. The setup skill asks
for it when the job is configured and writes the answer into the seed.

The controller then spends to that authority without asking, because there
is nobody to ask, and halts when it is exhausted rather than escalating
into a wait that nothing will service.

## Mechanical reach is full, gated by the verdict tool

Committing a verifier PASS, pushing, and advancing a trunk by fast-forward
are all in. None of them changes what was built; they change where it is
recorded, and each is auditable and revertible.

Pushing is the one that varies, and `git-push-check` already encodes the
distinction this role needs. Its three verdicts read directly as a
human-presence protocol:

| Verdict | Controller behaviour |
|---|---|
| `PUSH` | Act. Private working branch, nothing downstream sees it. |
| `ASK` | Escalate, record, and carry on with other work. Never block the queue on an answer nobody is awake to give. |
| `HOLD` | Stop, and report the reason. |

No new policy surface: the controller inherits the fleet's existing one.

## Leave the seam for a second controller

Long runs, measured in days rather than an evening, invite a known pattern:
a second controller reviewing the first, on the theory that a role marking
its own homework drifts. That is not in scope now, and building it now
would be speculative.

What is in scope is not foreclosing it. The controller records each
decision as structured data before acting on it, rather than only
performing the action and leaving a git commit as the sole trace. A
decision journal costs little while the controller is alone, and it is the
whole input a reviewing controller would need later. Retrofitting one
afterwards would mean reconstructing intent from effects.

## Artefacts

1. **The context seed**, rendered when the job is configured. Persona,
   mandate, the negative list, the spend authority just answered for, and
   the repo facts an orchestrator would otherwise rediscover: paths,
   families and their auth modes, branch policy, where state lives, the
   repo's own gotchas. Operator-owned and editable after rendering.
2. **The skill**, one source of truth loaded by both a headless pass and an
   interactive session. `skills/autometta-warden/` is most of this already,
   renamed and rescoped.
3. **The verbs**, what remains of `scripts/phat-controller.sh` once the decision
   layer moves into the agent.

## Disposition of card 54

Not superseded. Its mechanism is the half worth keeping, and its
`PROPOSED-AMENDMENT` contract survives intact into the negative list above.
The follow-on card inverts the control flow and rehomes the mandate; it
does not start again.
