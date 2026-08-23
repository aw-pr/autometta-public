#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# health-check.sh: cheap invariants that hold for any autometta checkout.
#
#   1. every script under scripts/ parses.
#   2. at most one loaded launchd job runs the fleet tick.
#
# Exit 0 when all hold, 1 on the first violation.

self_path="scripts/$(basename "$0")"

for script_path in scripts/*.sh; do
  [[ -e "$script_path" ]] || continue
  [[ "$script_path" == "$self_path" ]] && continue

  if bash -n "$script_path"; then
    printf 'ok: %s\n' "$script_path"
  else
    printf 'fail: %s\n' "$script_path"
    exit 1
  fi
done

# `autometta tick` takes no repo argument: it iterates every enabled
# subscriber in ~/.phat-controller/subscribers. So a second tick job does not
# tick a second repo, it ticks the whole fleet a second time, and every
# subscriber reaches its cap in a fraction of the intended window. The three
# per-repo jobs the fleet plist replaced tripled the rate and left the fleet
# halted through the 2026-08-15 window; com.autometta.tick.emergence-lab-surface-v2,
# added 2026-08-19 and named for one repo but carrying the same argument-free
# `autometta tick`, doubled it again and halved the time to cap through the
# 2026-08-23 windows. The fleet plist has carried "Do not add a second tick
# job per repo" as a comment since the first occurrence. A comment is not an
# enforcement, which is why this check exists.
#
# Matches the job by what it runs, not by what it is called: the duplicate was
# named for a repo, so a label-pattern check would have missed it. A plist is
# counted only when launchd has it loaded -- an uninstalled copy sitting in
# LaunchAgents is inert and not a fault.
#
# Two env overrides exist so the guard can be exercised without bootstrapping
# a real second job into the operator's launchd: AUTOMETTA_LAUNCHD_DIRS is a
# colon-separated search path, and AUTOMETTA_LAUNCHD_LOADED_LABELS stands in
# for the launchctl query as a space-separated label list. Neither is set in
# normal operation.
tick_jobs() {
  local uid plist args argv0 label dir
  uid="$(id -u)"
  local -a search_dirs=()
  if [[ -n "${AUTOMETTA_LAUNCHD_DIRS:-}" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] && search_dirs+=("$dir")
    done < <(printf '%s\n' "$AUTOMETTA_LAUNCHD_DIRS" | tr ':' '\n')
  else
    search_dirs=("$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons)
  fi
  for dir in ${search_dirs[@]+"${search_dirs[@]}"}; do
   for plist in "$dir"/*.plist; do
    [[ -f "$plist" ]] || continue
    args="$(plutil -extract ProgramArguments json -o - -- "$plist" 2>/dev/null || true)"
    [[ -n "$args" ]] || continue
    # plutil escapes the path separators, so normalise before matching.
    args="${args//\\\//\/}"
    argv0="$(printf '%s' "$args" | sed -nE 's/^\["([^"]*)".*/\1/p')"
    case "$(basename "${argv0:-}")" in
      autometta)
        printf '%s' "$args" | grep -q '"tick"' || continue
        ;;
      tick.sh)
        ;;
      *)
        continue
        ;;
    esac
    label="$(plutil -extract Label raw -o - -- "$plist" 2>/dev/null || basename "$plist" .plist)"
    if [[ -n "${AUTOMETTA_LAUNCHD_LOADED_LABELS:-}" ]]; then
      case " $AUTOMETTA_LAUNCHD_LOADED_LABELS " in
        *" $label "*) ;;
        *) continue ;;
      esac
    elif ! launchctl print "gui/${uid}/${label}" >/dev/null 2>&1 \
         && ! launchctl print "system/${label}" >/dev/null 2>&1; then
      continue
    fi
    printf '%s\t%s\n' "$label" "$plist"
   done
  done
}

if command -v launchctl >/dev/null 2>&1 && command -v plutil >/dev/null 2>&1; then
  loaded_tick_jobs="$(tick_jobs || true)"
  tick_job_count="$(printf '%s' "$loaded_tick_jobs" | grep -c . || true)"
  if (( tick_job_count > 1 )); then
    printf 'fail: %s loaded launchd jobs run the fleet tick; exactly one is allowed\n' \
      "$tick_job_count"
    printf '%s\n' "$loaded_tick_jobs" | sed 's/^/  /'
    printf '  `autometta tick` iterates the whole fleet, so each extra job multiplies\n'
    printf '  every subscriber'"'"'s tick rate and its time to clock_tick_cap.\n'
    printf '  Remove the extras:  launchctl bootout gui/%s/<label> && rm <plist>\n' "$(id -u)"
    exit 1
  fi
  printf 'ok: %s loaded launchd job(s) run the fleet tick\n' "$tick_job_count"
else
  printf 'skip: launchd tick-job check (launchctl/plutil unavailable)\n'
fi
