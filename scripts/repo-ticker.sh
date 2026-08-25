#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# repo-ticker.sh: the one ticker per repo (card 63). Answers one question --
# do I need to intervene? -- for exactly one subscriber, in five sections:
# NOW, NEXT, ESCALATIONS, SPEND AND LOSS, FRESHNESS. Owns the whole pane it
# is given; nothing here assumes a neighbouring tmux pane.
#
# Args: <repo_root> [--once]
#
# Data comes from exactly one place: `aggregate-dashboard.sh --repo
# <repo_root>`, re-run on every refresh so the figures are always as fresh as
# this render, never a shared data.json that might be minutes stale. The
# renderer (scripts/lib/repo-ticker-render.py) does no reading of its own --
# no state.yaml, no cost-log.jsonl, no transcripts -- so there is exactly one
# place a figure could be wrong.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: %s <repo_root> [--once]\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"
once=false
if [[ "${2:-}" == "--once" ]]; then
  once=true
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./alert-statuses.sh
. "$script_dir/alert-statuses.sh"
alert_statuses_json="$(alert_stage_statuses_json)"

# Deprecated for one release: PHAT_CONTROLLER_TICKER_INTERVAL.
refresh_interval="${AUTOMETTA_TICKER_INTERVAL:-${PHAT_CONTROLLER_TICKER_INTERVAL:-5}}"
# How long since the last tick before FRESHNESS reads loud. The 2026-08-24
# incident (docs/lessons.md) went 57 minutes silent with nothing on screen
# saying so; this defaults well below that.
freshness_threshold="${AUTOMETTA_TICK_FRESHNESS_THRESHOLD:-1200}"

render_once() {
  local width height payload
  width="${AUTOMETTA_TICKER_COLUMNS:-${COLUMNS:-$(tput cols 2>/dev/null || printf 80)}}"
  height="${AUTOMETTA_TICKER_ROWS:-${LINES:-$(tput lines 2>/dev/null || printf 24)}}"
  payload="$("$script_dir/aggregate-dashboard.sh" --repo "$repo_root" 2>/dev/null)" || payload=""
  AUTOMETTA_TICKER_PAYLOAD="$payload" AUTOMETTA_ALERT_STATUSES_JSON="$alert_statuses_json" \
    python3 "$script_dir/lib/repo-ticker-render.py" \
    "$repo_root" "$width" "$height" "$refresh_interval" "$freshness_threshold"
}

if "$once"; then
  render_once
  exit 0
fi

printf '\033[?25l\033[2J'
trap 'printf "\033[?25h\n"; exit 0' INT TERM EXIT
# Every line ends with erase-to-end-of-line, or a shorter line leaves the
# previous frame's tail showing through (the fleet pane's 04b6dec bug).
while true; do
  frame="$(render_once)"
  frame="${frame//$'\n'/$'\033[K'$'\n'}"
  printf '\033[H%s\033[K\033[J' "$frame"
  sleep "$refresh_interval"
done
