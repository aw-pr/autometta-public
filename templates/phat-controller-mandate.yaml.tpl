# Committed template for phat-controller's mandate manifest. Copied to
# $AUTOMETTA_HOME/phat-controller-mandate.yaml (gitignored, operator-owned)
# the first time a pass runs with no operator copy present. Editing the
# operator copy changes behaviour at the next pass with no code edit; editing
# this template only changes what a fresh controller home starts from.
#
# WHAT LIVES HERE AND WHAT DOES NOT. This file holds thresholds and cadence:
# numbers a script must act on without asking an agent. It does not hold the
# role, the mandate, or the prohibitions. Those are prose an agent reads, and
# they live in the rendered context seed
# ($AUTOMETTA_HOME/phat-controller-seed.md, from
# templates/phat-controller-seed.md.tpl). One fact, one owner: if you find
# yourself wanting to write a sentence here, it belongs in the seed.
#
# The spend authority is the case that spans both. The operator's answer, in
# their own words, goes in the seed. Its machine-readable half is mirrored
# below by scripts/render-controller-seed.sh so a pass can stop without
# parsing prose. Neither is a committed default: this template ships the
# spend_authority block empty on purpose.
#
# Budget figures (token caps, wall-clock caps, drain state) live in each
# repo's state/budget.json and the controller's host defaults (card 47); this
# file never restates them.

# Written by scripts/render-controller-seed.sh --token-ceiling / --expires
# when a job is configured. Empty means the only hard stops are each repo's
# own budget.json caps.
spend_authority:
  token_ceiling:
  expires_at:

# Written only when the operator answers the setup question. Zero is an
# explicit answer meaning off; null means this older job has not been asked.
#
# percent/action are the daytime default and, absent the optional overnight
# block below, the only rule there is -- this is every host's setting until
# card 124, unchanged. When overnight IS declared, quota_reserve_settings
# (scripts/quota-window.sh) resolves the reserve for the current moment
# instead of returning this static pair: overnight.percent applies inside
# the window, percent/action apply outside it. overnight.percent: 0 is the
# operator's declared "spend the session down on purpose" answer for that
# window; it is not the same zero as a top-level percent: 0, which means
# the reserve is off everywhere, all the time.
#
#   window_reserve:
#     percent: 20
#     action: hold
#     overnight:
#       start: "22:00"
#       end: "01:00"
#       percent: 0
#     timezone: local
#
# overnight.start/end are read in the clock named by `timezone`. Only
# "local" is supported today: the window describes when the operator is
# asleep, and a person's sleep does not move with UTC. Across a DST change
# the wall-clock boundaries ("22:00", "01:00") do not shift, but the
# window's actual duration does -- the two transition nights a year give a
# nominal 3-hour window either 2 or 4 real hours. Accepted, not fixed: see
# docs/tick-loop.md.
#
# A window whose end is earlier than its start (as above) crosses midnight
# and is one interval, not two: "now is inside" means now >= start OR
# now < end, never start <= now < end, which never matches at all for a
# wrapping window and fails silently rather than loudly.
window_reserve:
  percent:
  action:
  # overnight:
  #   start:
  #   end:
  #   percent:
  # timezone: local

escalation:
  # A verifier_failed stage at or above this many verifier_attempts is a
  # repeated failure. The controller reads this; it does not enumerate what
  # to do about it.
  attempt_cap: 3
  # How many times the same verb may be applied to the same stage while it
  # stays stuck before a blocking escalation replaces a third attempt.
  # Tracked per stage in <repo>/state/phat-controller-state.json; the counter
  # is dropped once the stage resolves.
  same_remediation_without_progress_cap: 2
  # Auth routes listed here count as metered spend. A pass that would move
  # work onto one of them without the operator having said so is an
  # escalation, not a decision.
  metered_spend:
    auth_routes:
      - api
    allow_within_budget: true
    unexpected_provider_signal_pattern: >-
      402[[:space:]]+Payment Required|payment required|billing required|insufficient (credit|credits|funds)|purchase credits|add (funds|credits)

cadence:
  # The default interval scripts/install-launchagent-phat-controller.sh reads
  # at provisioning time. Changing it does not rewrite an already-loaded
  # LaunchAgent; re-run the installer after editing it.
  pass_interval_minutes: 15

# Which subscriber repos the controller minds. Empty means every enabled
# subscriber in the registry, the same convention a drain's repos list uses in
# scripts/budget.sh. Non-empty is an allow-list of absolute repo paths.
repos: []

dispatch:
  # The identity a scheduled pass is dispatched as. Claude and Codex use the
  # same auth-route isolation as worker and verifier dispatch. Prohibition 2
  # stands whichever is chosen: the controller never verifies its own
  # dispatches.
  identity: "Claude Sonnet 5 <claude-sonnet-5@local>"
  effort: high
  timeout_seconds: 900

reporting:
  # Tone for surfaced summaries: escalation lines, PROPOSED-AMENDMENT notes,
  # the interactive session's opener.
  voice: >-
    Concise and factual. State what was found, what was done or not done,
    and why, in that order. No editorialising, no hedging past what the
    evidence supports.

retention:
  # state/phat-controller-transcripts/<pass_id>.log, one per pass. Pruned at
  # the start of every pass (pc_prune_transcripts): a transcript older than
  # this many days is deleted and dropped from the index alongside it.
  # Private-tier like the rest of state/ -- gitignored, never on the publish
  # branch, and *.log is additionally refused by the pre-commit never-commit
  # guard if anything ever tries to force-add one.
  transcript_days: 14
