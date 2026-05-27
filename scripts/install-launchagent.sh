#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"
default_interval=300

usage() {
  printf 'Usage: %s <repo_path> [--interval N]\n' "$(basename "$0")" >&2
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

remove_managed_cron_line() {
  local tmp current
  if ! current="$(crontab -l 2>/dev/null)"; then
    return 0
  fi
  if ! printf '%s\n' "$current" | grep -Eq 'autometta tick.*\.phat-controller/log/cron\.log'; then
    return 0
  fi
  tmp="$(mktemp)"
  printf '%s\n' "$current" \
    | grep -Ev '^[[:space:]]*\*/5[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+autometta tick[[:space:]]*>>[[:space:]]*"?\$HOME/\.phat-controller/log/cron\.log"?[[:space:]]+2>&1[[:space:]]*$' \
    > "$tmp" || true
  crontab "$tmp"
  rm -f "$tmp"
  printf 'PASS removed autometta-managed cron heartbeat if present\n'
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'not macOS, skipping LaunchAgent install (cron fallback)\n'
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage
fi

repo_path="$(resolve_path "$1")"
shift
interval="$default_interval"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      shift
      [[ $# -gt 0 ]] || usage
      interval="$1"
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

repo_slug="$(basename "$repo_path")"
label="com.autometta.tick.${repo_slug}"
if [[ ! "$label" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf 'invalid LaunchAgent label from repo name: %s\n' "$label" >&2
  exit 1
fi

repo_template="$repo_path/.autometta/launchagent.plist.tpl"
canonical_template="$autometta_root/templates/launchagent.plist.tpl"
if [[ ! -f "$canonical_template" ]]; then
  printf 'MISSING canonical template %s\n' "$canonical_template" >&2
  exit 1
fi
if [[ ! -f "$repo_template" ]]; then
  mkdir -p "$(dirname "$repo_template")"
  cp "$canonical_template" "$repo_template"
  printf 'PASS template copied %s\n' "$repo_template"
fi

# Prefer the brew symlink (/opt/homebrew/bin/autometta or similar) over a
# versioned Cellar path. The symlink follows brew upgrades; baking the
# Cellar path into the plist makes every brew upgrade silently break the
# LaunchAgent (the cleanup step removes the old keg and launchd loses
# the binary, exiting 78 every tick until the operator notices).
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

replace_placeholder REPO_PATH "$repo_path" < "$repo_template" \
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
remove_managed_cron_line

printf 'PASS launchagent label %s\n' "$label"
printf 'PASS launchagent plist %s\n' "$plist_file"
