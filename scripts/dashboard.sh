#!/usr/bin/env bash
# dashboard.sh — regenerate ~/.autometta/dashboard/{data.json,
# index.html, dashboard.js, dashboard.css, vendor/chart.min.js} and
# optionally open the page in the default browser.
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --open) open_after=true ;;
    --repo)
      [[ $# -ge 2 ]] || { printf 'autometta dashboard: --repo needs a repo path\n' >&2; exit 1; }
      repo_target="$2"
      shift
      ;;
    --help|-h)
      printf 'Usage: autometta dashboard [--repo <repo-path>] [--open]\n'
      exit 0
      ;;
    *)
      printf 'unknown flag: %s\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

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

if "$open_after"; then
  case "${OSTYPE:-$(uname -s)}" in
    darwin*|Darwin*)
      open "$dashboard_dir/index.html"
      ;;
    linux*|Linux*)
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$dashboard_dir/index.html"
      else
        printf 'xdg-open not found; open %s manually.\n' "$dashboard_dir/index.html" >&2
      fi
      ;;
    *)
      printf 'unknown platform; open %s manually.\n' "$dashboard_dir/index.html" >&2
      ;;
  esac
fi
