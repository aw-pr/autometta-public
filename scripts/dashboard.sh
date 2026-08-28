#!/usr/bin/env bash
# dashboard.sh — regenerate ~/.autometta/dashboard/{data.json,
# index.html, dashboard.js, dashboard.css, vendor/chart.min.js} and
# optionally open the page in the default browser.
#
# --watch keeps regenerating on an interval instead of once. The page polls
# data.json on its own, so the pair is what makes the dashboard live: without
# a regenerator the page faithfully re-reads a file nobody is rewriting.
#
# --serve adds a local http server over the dashboard directory. It exists for
# one reason: a file:// origin cannot fetch, so the page falls back to
# re-injecting data.js, which some browsers cache harder than others. Served
# over http the poll is an ordinary no-store fetch. Both are foreground
# processes that die with the terminal, in the same shape as `autometta tui` —
# not daemons, and nothing supervises them.
#
# --repo narrows the page to one subscriber. It is the same document over a
# data.json the aggregator narrowed for it, written to a per-repo directory
# under the controller home, so a repo view never needs its own renderer and
# never writes inside the repo it is reporting on.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Self root, not the resolved root: the dashboard sources it copies are assets of its own tree.
autometta_root="$(autometta_self_root "$script_dir")"
controller_home="$(autometta_controller_home)"
dashboard_dir="$controller_home/dashboard"

open_after=false
repo_target=""
watch=false
serve=false
interval="${AUTOMETTA_DASHBOARD_INTERVAL:-5}"
port="${AUTOMETTA_DASHBOARD_PORT:-8787}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --open) open_after=true ;;
    --watch) watch=true ;;
    --serve) serve=true; watch=true ;;
    --interval)
      [[ $# -ge 2 ]] || { printf 'autometta dashboard: --interval needs seconds\n' >&2; exit 1; }
      interval="$2"
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || { printf 'autometta dashboard: --port needs a port\n' >&2; exit 1; }
      port="$2"
      shift
      ;;
    --repo)
      [[ $# -ge 2 ]] || { printf 'autometta dashboard: --repo needs a repo path\n' >&2; exit 1; }
      repo_target="$2"
      shift
      ;;
    --help|-h)
      printf 'Usage: autometta dashboard [--repo <repo-path>] [--open]\n'
      printf '                          [--watch] [--serve] [--interval <secs>] [--port <port>]\n'
      printf '\n'
      printf '  --watch     regenerate data.json every <interval> seconds (default 5) until interrupted\n'
      printf '  --serve     --watch plus a local http server, so the page polls by fetch rather than\n'
      printf "              by re-reading data.js off a file:// origin\n"
      printf '  --interval  seconds between regenerations (env: AUTOMETTA_DASHBOARD_INTERVAL)\n'
      printf '  --port      port for --serve (default 8787, env: AUTOMETTA_DASHBOARD_PORT)\n'
      exit 0
      ;;
    *)
      printf 'unknown flag: %s\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

[[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 1 ]] || {
  printf 'autometta dashboard: --interval must be a positive whole number of seconds\n' >&2
  exit 1
}
[[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
  printf 'autometta dashboard: --port must be a port number\n' >&2
  exit 1
}

aggregate_args=()
if [[ -n "$repo_target" ]]; then
  repo_resolved="$(cd "$repo_target" 2>/dev/null && pwd -P)" || {
    printf 'autometta dashboard: repo not found: %s\n' "$repo_target" >&2
    exit 1
  }
  dashboard_dir="$controller_home/dashboard/repos/${repo_resolved##*/}"
  aggregate_args=(--only "$repo_resolved" --out-dir "$dashboard_dir")
fi

mkdir -p "$dashboard_dir/vendor"

# Refresh data.json from current subscriber state.
"$script_dir/aggregate-dashboard.sh" ${aggregate_args[@]+"${aggregate_args[@]}"}

# Copy static assets. Source of truth is the repo's dashboard/ directory;
# the controller home is a regenerated mirror.
src_dir="$autometta_root/dashboard"
for asset in index.html dashboard.js dashboard.css; do
  if [[ -f "$src_dir/$asset" ]]; then
    cp "$src_dir/$asset" "$dashboard_dir/$asset"
  else
    printf 'WARN missing %s\n' "$src_dir/$asset" >&2
  fi
done

if [[ -f "$src_dir/vendor/chart.min.js" ]]; then
  cp "$src_dir/vendor/chart.min.js" "$dashboard_dir/vendor/chart.min.js"
else
  printf 'ERROR: vendored chart.min.js is missing at %s\n' "$src_dir/vendor/chart.min.js" >&2
  printf 'Run scripts/install-homebrew-local.sh to fetch it.\n' >&2
  exit 1
fi

printf 'Dashboard regenerated at %s\n' "$dashboard_dir/index.html"

page_url="file://$dashboard_dir/index.html"
server_pid=""

if "$serve"; then
  # Foreground-owned: the trap kills it on any exit path, including the
  # interrupt that ends --watch. Bound to loopback, because this reports on
  # every subscriber in the fleet and has no auth of its own.
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dashboard_dir" >/dev/null 2>&1 &
  server_pid=$!
  # shellcheck disable=SC2064
  trap "kill $server_pid 2>/dev/null || true" EXIT INT TERM
  page_url="http://127.0.0.1:$port/index.html"
  sleep 1
  if ! kill -0 "$server_pid" 2>/dev/null; then
    printf 'autometta dashboard: could not serve on port %s (already in use?)\n' "$port" >&2
    exit 1
  fi
  printf 'Serving at %s\n' "$page_url"
fi

open_page() {
  case "${OSTYPE:-$(uname -s)}" in
    darwin*|Darwin*) open "$1" ;;
    linux*|Linux*)
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$1"
      else
        printf 'xdg-open not found; open %s manually.\n' "$1" >&2
      fi
      ;;
    *) printf 'unknown platform; open %s manually.\n' "$1" >&2 ;;
  esac
}

if "$open_after"; then
  open_page "$page_url"
  if ! "$serve"; then
    printf 'Opened as a file:// page. It polls, but a file origin cannot fetch,\n' >&2
    printf 'so it re-reads data.js and depends on the browser not caching it.\n' >&2
    printf 'For a reliable live view: autometta dashboard --serve --open\n' >&2
  fi
fi

if "$watch"; then
  printf 'Regenerating every %ss. Ctrl-C to stop.\n' "$interval"
  # Only data.json and data.js are rewritten per cycle: the static assets are
  # already in place and copying them again every few seconds would race the
  # browser reading them. The page keys its re-render on generated_at, so a
  # cycle that finds nothing new costs one read and no repaint.
  while :; do
    sleep "$interval"
    if ! "$script_dir/aggregate-dashboard.sh" ${aggregate_args[@]+"${aggregate_args[@]}"} >/dev/null 2>&1; then
      printf '%s aggregate failed; retrying next cycle\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    fi
  done
fi
