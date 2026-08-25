#!/usr/bin/env bash
# Configure the phat-controller job: render the context seed if it is not
# there yet, then install its LaunchAgent on a separate schedule from the
# tick's (templates/launchagent.plist.tpl / scripts/install-launchagent.sh).
# Same AbandonProcessGroup care, but one fleet-wide label. A pass already
# walks every enabled subscriber, so installing one job per repo would run the
# same fleet pass several times concurrently.
#
# Configuring the job is where the spend authority is answered for. This
# script refuses to install a schedule with no seed rather than rendering one
# with a default, because there is no right default: the level varies by run,
# by hour and by day. Pass --spend-authority (and optionally --token-ceiling
# and --expires) through to scripts/render-controller-seed.sh, or render the
# seed first and re-run this.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
autometta_root="$(autometta_self_root "$script_dir")"
controller_home="$(autometta_controller_home)"
mandate_path="${AUTOMETTA_CONTROLLER_MANDATE:-$controller_home/phat-controller-mandate.yaml}"
mandate_template="$autometta_root/templates/phat-controller-mandate.yaml.tpl"
seed_path="${AUTOMETTA_CONTROLLER_SEED:-$controller_home/phat-controller-seed.md}"
default_interval=900

if [[ ! -f "$mandate_path" ]]; then
  [[ -f "$mandate_template" ]] || { printf 'MISSING mandate template %s\n' "$mandate_template" >&2; exit 1; }
  mkdir -p "$(dirname "$mandate_path")"
  cp "$mandate_template" "$mandate_path"
  printf 'PASS mandate copied %s\n' "$mandate_path"
fi
if command -v yq >/dev/null 2>&1; then
  mandate_minutes="$(yq -r '.cadence.pass_interval_minutes // 15' "$mandate_path" 2>/dev/null || echo 15)"
  if [[ "$mandate_minutes" =~ ^[0-9]+$ && "$mandate_minutes" -gt 0 ]]; then
    default_interval=$((mandate_minutes * 60))
  else
    printf 'invalid cadence.pass_interval_minutes in %s: %s\n' "$mandate_path" "$mandate_minutes" >&2
    exit 1
  fi
fi

usage() {
  printf 'Usage: %s <repo_path> [--interval N] [--spend-authority TEXT] [--token-ceiling N] [--expires ISO8601]\n' "$(basename "$0")" >&2
  exit 1
}

resolve_path() {
  local input_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input_path"
  else
    python3 - "$input_path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
  fi
}

xml_escape() {
  printf '%s' "$1" \
    | sed \
      -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

sed_escape() {
  printf '%s' "$1" | sed -e 's/[&|]/\\&/g'
}

replace_placeholder() {
  local key="$1"
  local value="$2"
  sed -e "s|{{${key}}}|$(sed_escape "$(xml_escape "$value")")|g"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'not macOS, skipping phat-controller LaunchAgent install\n'
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage
fi

repo_path="$(resolve_path "$1")"
shift
interval="$default_interval"

seed_argv=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      shift
      [[ $# -gt 0 ]] || usage
      interval="$1"
      ;;
    --spend-authority|--spend-authority-file|--token-ceiling|--expires)
      [[ $# -gt 1 ]] || usage
      seed_argv+=( "$1" "$2" )
      shift
      ;;
    *)
      usage
      ;;
  esac
  shift
done

if [[ ! -d "$repo_path" ]]; then
  printf 'MISSING repo %s\n' "$repo_path" >&2
  exit 1
fi
if [[ ! "$interval" =~ ^[0-9]+$ || "$interval" -lt 1 ]]; then
  printf 'invalid interval: %s\n' "$interval" >&2
  exit 1
fi

# Configuring the job is where the spend authority is answered for. A schedule
# with no seed would be a controller with no mandate, no prohibitions and no
# idea what it may spend, so this fails closed rather than rendering a seed
# with a default nobody chose.
if [[ ! -f "$seed_path" ]]; then
  if [[ ${#seed_argv[@]} -eq 0 ]]; then
    cat >&2 <<SEEDLESS
No context seed at ${seed_path}, and no spend authority was supplied, so
nothing was installed.

phat-controller is a seeded agent. The seed carries its persona, its
prohibitions, the repo facts it would otherwise rediscover, and what this job
may spend. The last of those has no committed default: the right level varies
by run, by hour and by day.

Supply it here:

  $(basename "$0") ${repo_path} \\
    --spend-authority 'Up to 40M tokens overnight on the Claude subscription.' \\
    --token-ceiling 40000000 --expires 2026-08-25T07:00:00Z

or render the seed first with scripts/render-controller-seed.sh and re-run.
SEEDLESS
    exit 2
  fi
  "$autometta_root/scripts/render-controller-seed.sh" "${seed_argv[@]}" --out "$seed_path"
elif [[ ${#seed_argv[@]} -gt 0 ]]; then
  "$autometta_root/scripts/render-controller-seed.sh" "${seed_argv[@]}" --out "$seed_path" --force
fi
printf 'PASS seed %s\n' "$seed_path"

label="com.autometta.phat-controller.fleet"

repo_template="$repo_path/.autometta/launchagent-phat-controller.plist.tpl"
canonical_template="$autometta_root/templates/launchagent-phat-controller.plist.tpl"
if [[ ! -f "$canonical_template" ]]; then
  printf 'MISSING canonical template %s\n' "$canonical_template" >&2
  exit 1
fi
if [[ ! -f "$repo_template" ]]; then
  mkdir -p "$(dirname "$repo_template")"
  cp "$canonical_template" "$repo_template"
  printf 'PASS template copied %s\n' "$repo_template"
fi

if [[ -n "${AUTOMETTA_LAUNCHAGENT_BIN:-}" ]]; then
  autometta_bin="$AUTOMETTA_LAUNCHAGENT_BIN"
elif command -v autometta >/dev/null 2>&1; then
  autometta_bin="$(command -v autometta)"
else
  autometta_bin="$autometta_root/bin/autometta"
fi
log_dir="$repo_path/state/logs"
mkdir -p "$HOME/Library/LaunchAgents" "$log_dir"

plist_file="$HOME/Library/LaunchAgents/${label}.plist"
path_value="${AUTOMETTA_LAUNCHAGENT_PATH:-$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

replace_placeholder AUTOMETTA_HOME "$controller_home" < "$repo_template" \
  | replace_placeholder REPO_PATH "$controller_home" \
  | replace_placeholder LABEL "$label" \
  | replace_placeholder INTERVAL_SECONDS "$interval" \
  | replace_placeholder AUTOMETTA_BIN "$autometta_bin" \
  | replace_placeholder LOG_DIR "$log_dir" \
  | replace_placeholder PATH "$path_value" \
  > "$plist_file"
chmod 0644 "$plist_file"

uid="$(id -u)"
launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
launchctl bootstrap "gui/${uid}" "$plist_file"

printf 'PASS launchagent label %s\n' "$label"
printf 'PASS launchagent plist %s\n' "$plist_file"
