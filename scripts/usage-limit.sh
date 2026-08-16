#!/usr/bin/env bash
# usage-limit.sh — shared detection for provider limit refusals.
#
# A subscription worker that has run out of window does not crash and does not
# work: the CLI prints one short refusal and exits clean. On 2026-08-16 that
# looked like a 63-byte log reading
#
#   You've hit your session limit · resets 1:10pm (Europe/London)
#
# Nothing in the reap path could tell that apart from a stage that genuinely
# failed, so two stages that were never attempted were marked stalled and the
# refusals walked the consecutive-failure cap into a halt. A refusal is not a
# failure — the work has not been tried yet.
#
# Sourced by tick.sh (to treat a refusal as a non-event and park the loop) and
# by scan-usage-limits.sh (report-only, for the dashboard and the menu bar
# app). The pattern lives here so those two can never drift apart: the scanner
# previously matched "usage limit" and "limit reached" but not "session
# limit", so it missed the exact wording that halted the fleet.
#
# Detection is deliberately broad and the consequence is deliberately mild
# (wait and retry, never mark a stage bad), so a false positive costs one tick.

# Matched case-insensitively against the whole log.
USAGE_LIMIT_PATTERN='session[ _-]limit|usage[ _-]limit|limit reached|hit your .{0,24}limit|reached your .{0,24}limit|too many requests|rate[ _-]limit|overloaded_error|quota exceeded|credit balance|insufficient credit|at capacity|HTTP 429|status 429|"code": *429'

# Lines that merely *name* this machinery are not refusals. An agent working
# on the limit-handling code writes "scan-usage-limits.sh" into its own log
# and would otherwise park the whole loop; a verifier log did exactly that in
# testing. Applied after USAGE_LIMIT_PATTERN, never instead of it.
USAGE_LIMIT_EXCLUDE='scan-usage-limits|usage-limit\.sh|USAGE_LIMIT_|usage_limit_|--usage-limit'

# usage_limit_hit <log_path>
# Exit 0 and print the first matching line when the log carries a refusal.
# Exit 1 otherwise (including a missing log).
usage_limit_hit() {
  local log_path="${1:-}"
  [[ -n "$log_path" && -f "$log_path" ]] || return 1
  local hit
  hit="$(grep -iE "$USAGE_LIMIT_PATTERN" "$log_path" 2>/dev/null \
         | grep -ivE "$USAGE_LIMIT_EXCLUDE" 2>/dev/null \
         | head -n 1 || true)"
  [[ -n "$hit" ]] || return 1
  printf '%s\n' "$hit"
}

# usage_limit_reset_epoch <refusal_line>
# Print the epoch second at which the provider says the window resets, parsed
# from a trailing "resets 1:10pm" / "resets at 13:10" / "resets 1pm". Prints
# nothing when the line carries no reset time, which the caller should treat
# as "unknown, back off by a default".
#
# The clock is wall-clock local time and carries no date, so a time that has
# already passed today is read as tomorrow.
usage_limit_reset_epoch() {
  local line="${1:-}"
  [[ -n "$line" ]] || return 0
  python3 - "$line" <<'PY'
import datetime as dt
import re
import sys

line = sys.argv[1]
m = re.search(
    r"resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?",
    line,
    re.IGNORECASE,
)
if not m:
    sys.exit(0)

hour = int(m.group(1))
minute = int(m.group(2) or 0)
meridiem = (m.group(3) or "").replace(".", "").lower()

if meridiem == "pm" and hour != 12:
    hour += 12
elif meridiem == "am" and hour == 12:
    hour = 0

if not (0 <= hour <= 23 and 0 <= minute <= 59):
    sys.exit(0)

now = dt.datetime.now()
target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
if target <= now:
    target += dt.timedelta(days=1)
print(int(target.timestamp()))
PY
}
