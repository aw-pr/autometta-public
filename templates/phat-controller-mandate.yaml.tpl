# Committed template for phat-controller's mandate manifest. Copied to
# $AUTOMETTA_HOME/phat-controller-mandate.yaml (gitignored, operator-owned) by
# scripts/init-host.sh. Editing the operator copy changes behaviour at the next
# tick with no code edit; editing this template only changes what a fresh
# controller home starts from.
#
# WHAT LIVES HERE. Numbers a script must act on without asking anyone: the
# quota reserve and curfew fields the tick reads
# (quota_gate_family_dispatch in scripts/tick.sh) and the escalation
# thresholds the phat-controller.sh verbs read. There is no controller agent
# and nothing renders this file: edit the fields by hand. Every field is
# optional, and a missing one takes the default stated beside it.
#
# Budget figures (token caps, wall-clock caps, drain state) live in each
# repo's state/budget.json and the controller's host defaults (card 47); this
# file never restates them.

# Claude reserve, and Codex only with AUTOMETTA_CODEX_QUOTA_POLICY=reserve.
# Default Codex subscription admission instead uses fresh quota below 100%;
# the active card may finish in overage, then further cards wait.
# Edited by hand. Unanswered (empty)
# is NOT off: the loop then holds a 20% reserve (no new card past 80% of any
# reported window, 5-hour or weekly, per family). Zero is the explicit
# answer meaning off, as is action: off. The same line binds a manual
# scripts/spawn-worker.sh dispatch, which exits 4 rather than starting a
# card; AUTOMETTA_IGNORE_RESERVE=1 overrides that one spawn.
#
# percent/action are the daytime default and, absent the optional overnight
# block below, the only rule there is -- this is every host's setting until
# card 124, unchanged. When overnight IS declared, quota_reserve_settings
# (scripts/quota-window.sh) resolves the reserve for the current moment
# instead of returning this static pair: overnight.percent applies inside
# the window, percent/action apply outside it. A lower overnight percentage
# spends more of the session while retaining the stated headroom.
#
#   window_reserve:
#     percent: 20
#     action: hold
#     claude_window: 5-hour
#     overnight:
#       start: "22:00"
#       end: "09:00"
#       percent: 10
#       stop_outside: false
#     timezone: local
#
# overnight.stop_outside: true stops new workers outside the window; it defaults off.
#
# overnight.start/end are read in the clock named by `timezone`. Only
# "local" is supported today: the window describes when the operator is
# asleep, and a person's sleep does not move with UTC. Across a DST change
# the wall-clock boundaries ("22:00", "09:00") do not shift, but the
# window's actual duration does -- the two transition nights a year give a
# nominal 11-hour window either 10 or 12 real hours. Accepted, not fixed: see
# docs/tick-loop.md.
#
# A window whose end is earlier than its start (as above) crosses midnight
# and is one interval, not two: "now is inside" means now >= start OR
# now < end, never start <= now < end, which never matches at all for a
# wrapping window and fails silently rather than loudly.
window_reserve:
  percent:   # empty = default 20; 0 = off
  action:    # empty = default hold; hold | observe | off
  claude_window:   # empty = every Claude window; 5-hour = session only
  codex_admit_percent:   # empty = 100; no new Codex card at or past this % used
  # pace spreads each selected family's weekly window over the days left.
  # The week is cut into slot_hours slots; a slot may spend the remaining
  # headroom over the slots left, so a family that ran ahead holds new cards
  # until the calendar catches up. A new card is held while any listed
  # subscription family it names is ahead; an admitted card's verifier always
  # runs. run_cap_slots
  # kills a Codex dispatch once the weekly window has risen that many slot
  # allowances since it started (0 = no kill): a plan with no session limit
  # has nothing else to stop a runaway. AUTOMETTA_IGNORE_PACE=1 bypasses.
  # pace:
  #   action: hold         # hold | observe | off
  #   slot_hours: 12
  #   families: [codex]
  #   run_cap_slots: 1
  # overnight:
  #   start:
  #   end:
  #   percent:
  #   stop_outside: false
  # timezone: local

escalation:
  # A verifier_failed stage at or above this many verifier_attempts is a
  # repeated failure.
  attempt_cap: 3
  # How many times the same verb may be applied to the same stage while it
  # stays stuck before a blocking escalation replaces a third attempt.
  # Tracked per stage in <repo>/state/phat-controller-state.json; the counter
  # is dropped once the stage resolves.
  same_remediation_without_progress_cap: 2
  # Auth routes listed here count as metered spend. Moving work onto one of
  # them without the operator having said so is an escalation, not a decision.
  metered_spend:
    auth_routes:
      - api
    allow_within_budget: true
    unexpected_provider_signal_pattern: >-
      402[[:space:]]+Payment Required|payment required|billing required|insufficient (credit|credits|funds)|purchase credits|add (funds|credits)

# Which subscriber repos `phat-controller.sh picture --all` covers. Empty means every enabled
# subscriber in the registry, the same convention a drain's repos list uses in
# scripts/budget.sh. Non-empty is an allow-list of absolute repo paths.
repos: []
