# Committed template for the warden's mandate manifest. Copied verbatim to
# $PHAT_CONTROLLER_HOME/warden-mandate.yaml (gitignored, operator-owned) the
# first time scripts/warden.sh runs and no operator copy exists yet. Editing
# the operator copy changes warden behaviour at the next pass with no code
# edit; editing this template only changes what a *fresh* controller home
# starts from.
#
# This file tunes THRESHOLDS AND CADENCE ONLY. The four actions the warden
# may take are fixed in scripts/warden.sh and are not configurable here or
# from the rendered prompt -- see docs/phat-controller.md "The warden role"
# and examples/self-host/54-a-warden-pass-minds-the-queue.md, "What the
# warden may do". Adding a fifth action is a card, never an edit to this
# file.
#
# Budget figures (token caps, wall-clock caps, drain state) live in each
# repo's state/budget.json and the controller's host defaults (card 47);
# this file never restates them.

escalation:
  # A verifier_failed stage at or above this many verifier_attempts is
  # escalated (operator halt) rather than triaged again.
  attempt_cap: 3
  # How many times the SAME remediation may apply to the SAME stage while it
  # stays stuck before the warden escalates instead of trying a third time.
  # Tracked per stage in <repo>/state/warden-state.json; the counter is
  # dropped once the stage reaches completed or superseded.
  same_remediation_without_progress_cap: 2
  # Remediation 1 is the only remediation that dispatches an agent. Before
  # every such dispatch the warden checks the repo's own spend caps
  # (state/budget.json via budget_spend_caps_blown) and escalates instead of
  # spending if any are already exhausted -- that is "metered spend beyond
  # the budget file's caps", checked mechanically rather than guessed. This
  # flag exists so an operator can turn triage dispatch off entirely (an
  # overnight run on a metered account, say) without touching
  # scripts/warden.sh.
  triage_dispatch_enabled: true
  # Auth routes listed here count as metered. They may run only while the
  # repo's normal budget gate is open, unless allow_within_budget is false,
  # in which case the warden escalates without dispatching them at all.
  # Keep provider payment/error wording here so an operator can tune the
  # unexpected-payment signal without changing code.
  metered_spend:
    auth_routes:
      - api
    allow_within_budget: true
    unexpected_provider_signal_pattern: >-
      402[[:space:]]+Payment Required|payment required|billing required|insufficient (credit|credits|funds)|purchase credits|add (funds|credits)

cadence:
  # The default interval scripts/install-launchagent-warden.sh reads at
  # provisioning time. Changing it does not rewrite an already-loaded
  # LaunchAgent; re-run the installer after editing it.
  pass_interval_minutes: 15

# Which subscriber repos the warden minds. Empty means every enabled
# subscriber in the registry -- the same convention a drain's repos list
# uses in scripts/budget.sh. Non-empty is an allow-list of absolute repo
# paths.
repos: []

dispatch:
  # Identity dispatched for remediation 1's triage judgement. Claude and
  # Codex use the same auth-route isolation as worker/verifier dispatch.
  triage_identity: "Claude Sonnet 5 <claude-sonnet-5@local>"
  triage_effort: high
  triage_timeout_seconds: 600

reporting:
  # Tone for the warden's surfaced summaries (PROPOSED-AMENDMENT notes,
  # escalation lines, the interactive skill's session opener). Loaded
  # verbatim into the rendered triage prompt.
  voice: >-
    Concise and factual. State what was found, what was done or not done,
    and why, in that order. No editorialising, no hedging past what the
    evidence supports.
