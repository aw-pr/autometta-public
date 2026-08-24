#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Self root, not the resolved root: this acts on the tree it is part of.
autometta_root="$(autometta_self_root "$script_dir")"
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

# The daily token cap is a host decision. Before card 47 it was written per
# repo by subscribe-repo.sh and never revisited, and the fleet ended up
# carrying four different numbers with nothing recording why any of them
# held. Ask once, here, and let every repo inherit it unless it says
# otherwise. See scripts/budget.sh for the resolution order and
# scripts/drain.sh for the deliberate overnight case.
default_token_cap="${AUTOMETTA_HOST_TOKEN_CAP:-100000000}"
host_token_cap="$default_token_cap"
if [[ -t 0 && -z "${AUTOMETTA_HOST_TOKEN_CAP:-}" ]]; then
  printf 'Daily token cap per repo [%s]: ' "$default_token_cap" >&2
  read -r answer || answer=""
  if [[ -n "$answer" ]]; then
    if [[ "$answer" =~ ^[0-9]+$ && "$answer" -gt 0 ]]; then
      host_token_cap="$answer"
    else
      printf 'Not a positive integer, keeping %s\n' "$default_token_cap" >&2
    fi
  fi
fi

if [[ -f "$config_file" ]]; then
  printf 'PASS config exists %s\n' "$config_file"
  if grep -Eq '^autometta_root:' "$config_file"; then
    current_root="$(sed -n 's/^autometta_root:[[:space:]]*//p' "$config_file" | head -n1)"
    current_root="${current_root%\"}"
    current_root="${current_root#\"}"
    current_root="${current_root%\'}"
    current_root="${current_root#\'}"
    if [[ "$current_root" == "$autometta_root" ]]; then
      printf 'PASS config autometta_root exists\n'
    else
      tmp_file="$(mktemp)"
      sed "s|^autometta_root:.*|autometta_root: \"$autometta_root\"|" "$config_file" > "$tmp_file"
      mv "$tmp_file" "$config_file"
      printf 'PASS config autometta_root refreshed %s\n' "$autometta_root"
    fi
  else
    printf 'autometta_root: "%s"\n' "$autometta_root" >> "$config_file"
    printf 'PASS config autometta_root added %s\n' "$autometta_root"
  fi
  if grep -Eq '^token_cap_total:' "$config_file"; then
    printf 'PASS config token_cap_total %s\n' \
      "$(sed -n 's/^token_cap_total:[[:space:]]*//p' "$config_file" | head -n1)"
  else
    printf 'token_cap_total: %s\n' "$host_token_cap" >> "$config_file"
    printf 'PASS config token_cap_total added %s\n' "$host_token_cap"
  fi
else
  cat > "$config_file" <<YAML
version: 1
autometta_root: __AUTOMETTA_ROOT__
max_per_fire: 20
default_weight: 100
log_level: info
# Daily token cap inherited by every subscribed repo that does not set its
# own token_cap_total. A runaway catcher, not a spending target; raise it for
# one night with \`autometta drain start\` rather than editing it here.
token_cap_total: $host_token_cap
YAML
  tmp_file="$(mktemp)"
  sed "s|__AUTOMETTA_ROOT__|\"$autometta_root\"|" "$config_file" > "$tmp_file"
  mv "$tmp_file" "$config_file"
  printf 'PASS config created %s\n' "$config_file"
  printf 'PASS config token_cap_total %s (daily, per repo; drain raises it for one run)\n' "$host_token_cap"
fi

if [[ -f "$template_file" ]]; then
  printf 'PASS template exists %s\n' "$template_file"
else
  cat > "$template_file" <<'YAML'
repo_path: /absolute/path/to/repo
manifest_path: /absolute/path/to/repo/.autometta.local.yaml
weight: 100
enabled: true
YAML
  printf 'PASS template created %s\n' "$template_file"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  printf 'PASS macOS host uses per-repo LaunchAgents; run autometta subscribe <repo> to install one\n'
else
  printf 'PASS non-macOS host keeps cron heartbeat fallback\n'
fi

printf 'PASS init complete %s\n' "$controller_home"
