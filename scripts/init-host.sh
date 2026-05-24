#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
subscribers_dir="$controller_home/subscribers"
log_dir="$controller_home/log"
config_file="$controller_home/config.yaml"
template_file="$subscribers_dir/template.yaml"

if ! "$script_dir/check-deps.sh"; then
  printf 'Required dependencies are missing. Fix them, then re-run scripts/init-host.sh.\n' >&2
  exit 1
fi

if [[ -d "$controller_home" ]]; then
  printf 'PASS home exists %s\n' "$controller_home"
else
  mkdir -p "$controller_home"
  chmod 700 "$controller_home"
  printf 'PASS home created %s\n' "$controller_home"
fi

case "$(uname -s)" in
  Darwin|FreeBSD|*BSD)
    current_mode="$(stat -f '%Lp' "$controller_home")"
    ;;
  *)
    current_mode="$(stat -c '%a' "$controller_home")"
    ;;
esac
if [[ "$current_mode" != "700" ]]; then
  chmod 700 "$controller_home"
  printf 'PASS home mode corrected %s -> 700\n' "$current_mode"
else
  printf 'PASS home mode 700\n'
fi

mkdir -p "$subscribers_dir"
printf 'PASS subscribers dir %s\n' "$subscribers_dir"

mkdir -p "$log_dir"
printf 'PASS log dir %s\n' "$log_dir"

if [[ -f "$config_file" ]]; then
  printf 'PASS config exists %s\n' "$config_file"
else
  cat > "$config_file" <<'YAML'
version: 1
max_per_fire: 20
default_weight: 100
log_level: info
YAML
  printf 'PASS config created %s\n' "$config_file"
fi

if [[ -f "$template_file" ]]; then
  printf 'PASS template exists %s\n' "$template_file"
else
  cat > "$template_file" <<'YAML'
repo_path: /absolute/path/to/repo
weight: 100
enabled: true
YAML
  printf 'PASS template created %s\n' "$template_file"
fi

printf 'PASS init complete %s\n' "$controller_home"
