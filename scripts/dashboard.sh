#!/usr/bin/env bash
# dashboard.sh — regenerate ~/.phat-controller/dashboard/{data.json,
# index.html, dashboard.js, dashboard.css, vendor/chart.min.js} and
# optionally open the page in the default browser.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
dashboard_dir="$controller_home/dashboard"

open_after=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --open) open_after=true ;;
    --help|-h)
      printf 'Usage: autometta dashboard [--open]\n'
      exit 0
      ;;
    *)
      printf 'unknown flag: %s\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$dashboard_dir/vendor"

# Refresh data.json from current subscriber state.
"$script_dir/aggregate-dashboard.sh"

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
