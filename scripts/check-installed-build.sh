#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Installed build vs checkout drift check.
#
# `autometta` is two trees on this machine: the Homebrew install under
# Cellar/autometta/<sha>/libexec, and the git checkout it was packaged from.
# Which of the two actually executes is decided by scripts/resolve-root.sh at
# every invocation, so the two can drift silently and reasoning about "what is
# deployed" gives the wrong answer in both directions -- as it did on
# 2026-08-23, when a committed fix was live for the tick while the installed
# build still held the old file.
#
# This compares them file by file and then states, from the LaunchAgent's own
# environment rather than from assumption, which root the fleet tick will run.
#
# Roots, first hit wins:
#   checkout   $AUTOMETTA_CHECKOUT, controller config autometta_root, own tree
#   installed  $AUTOMETTA_INSTALLED_ROOT, `brew --prefix autometta`/libexec,
#              ${HOMEBREW_PREFIX:-/opt/homebrew}/opt/autometta/libexec
#
# Exit 0 when the two agree, 1 on drift naming each differing file, 2 when
# either side is missing or unreadable.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"

warn() { printf 'check-installed-build: %s\n' "$*" >&2; }
digest() { shasum -a 256 "$1" | awk '{print $1}'; }

self_root="$(autometta_self_root "$script_dir")"

# --- resolve the checkout side -------------------------------------------

checkout_root=""
for candidate in "${AUTOMETTA_CHECKOUT:-}" "$(autometta_config_root)" "$self_root"; do
  if autometta_root_is_usable "$candidate" && autometta_root_is_checkout "$candidate"; then
    checkout_root="$(cd "$candidate" && pwd)"
    break
  fi
done
if [[ -z "$checkout_root" ]]; then
  warn "no autometta git checkout found; set AUTOMETTA_CHECKOUT"
  exit 2
fi

# --- resolve the installed side ------------------------------------------

installed_root=""
installed_candidates=("${AUTOMETTA_INSTALLED_ROOT:-}")
if command -v brew >/dev/null 2>&1; then
  brew_opt="$(brew --prefix autometta 2>/dev/null || true)"
  [[ -n "$brew_opt" ]] && installed_candidates+=("$brew_opt/libexec")
fi
installed_candidates+=("${HOMEBREW_PREFIX:-/opt/homebrew}/opt/autometta/libexec")
for candidate in "${installed_candidates[@]}"; do
  if autometta_root_is_usable "$candidate"; then
    installed_root="$(cd "$candidate" && pwd)"
    break
  fi
done
if [[ -z "$installed_root" ]]; then
  warn "no installed autometta build found; run scripts/install-homebrew-local.sh"
  exit 2
fi

checkout_sha="$(autometta_root_sha "$checkout_root")"
installed_sha="$(autometta_root_sha "$installed_root")"
dirty_files="$(autometta_root_dirty_scripts "$checkout_root")"

printf 'Installed build: %s (%s)\n' "$installed_root" "$installed_sha"
printf 'Checkout:        %s (%s)\n' "$checkout_root" "$checkout_sha"
if [[ -n "$dirty_files" ]]; then
  printf 'Checkout state:  DIRTY, %s tracked file(s) modified under scripts/\n\n' \
    "$(printf '%s\n' "$dirty_files" | wc -l | tr -d '[:space:]')"
else
  printf 'Checkout state:  clean under scripts/\n\n'
fi

# --- compare the two trees -----------------------------------------------

# VERSION is the packaging stamp and differs by design; state/ and logs/ are
# runtime, and dashboard/vendor/ is a hash-pinned download the install fetches
# for itself. Dotfiles never reach the keg at all: the formula installs
# Dir["*"], and that glob does not match a leading dot. Reporting any of these
# as drift would put a permanent wall of false positives in front of the two
# or three files that genuinely differ.
skip_path() {
  case "$1" in
    VERSION|state/*|logs/*|runs/*|dashboard/vendor/*) return 0 ;;
    .*|*/.*) return 0 ;;
    *) return 1 ;;
  esac
}

# Homebrew lifts LICENSE and README.md out of libexec and up to the keg root
# as a matter of course. They are present, just one level higher.
keg_root="$(cd "$installed_root/.." && pwd)"
installed_path() {
  local rel="$1"
  case "$rel" in
    LICENSE|README.md)
      if [[ ! -f "$installed_root/$rel" && -f "$keg_root/$rel" ]]; then
        printf '%s' "$keg_root/$rel"
        return 0
      fi ;;
  esac
  printf '%s' "$installed_root/$rel"
}

drift=0 gone=0 orphan=0 same=0

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  skip_path "$rel" && continue
  [[ -f "$checkout_root/$rel" ]] || continue
  installed_file="$(installed_path "$rel")"
  if [[ ! -f "$installed_file" ]]; then
    printf '  GONE   %s (in checkout, absent from installed build)\n' "$rel"
    gone=$((gone + 1))
  elif [[ "$(digest "$checkout_root/$rel")" == "$(digest "$installed_file")" ]]; then
    same=$((same + 1))
  else
    printf '  DRIFT  %s\n' "$rel"
    drift=$((drift + 1))
  fi
done < <(git -C "$checkout_root" ls-files)

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  skip_path "$rel" && continue
  if [[ ! -f "$checkout_root/$rel" ]]; then
    printf '  ORPHAN %s (in installed build, no longer in checkout)\n' "$rel"
    orphan=$((orphan + 1))
  fi
done < <(cd "$installed_root" && find . -type f \
  -not -path './.git/*' -not -path './state/*' -not -path './logs/*' \
  | sed 's|^\./||' | sort)

printf '\n%d identical, %d drifted, %d missing from the install, %d left over in the install.\n' \
  "$same" "$drift" "$gone" "$orphan"

# --- which root does the fleet tick actually run? ------------------------

# Read it out of launchd rather than assuming. The tick's plist may carry an
# AUTOMETTA_ROOT of its own, and that beats every other rule; with no such
# entry the same precedence as any other caller applies, so the answer still
# is not "the installed build" by default.
launchd_dirs=()
if [[ -n "${AUTOMETTA_LAUNCHD_DIRS:-}" ]]; then
  while IFS= read -r dir; do
    [[ -n "$dir" ]] && launchd_dirs+=("$dir")
  done < <(printf '%s\n' "$AUTOMETTA_LAUNCHD_DIRS" | tr ':' '\n')
else
  launchd_dirs=("$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons)
fi

# The tree an autometta launcher on disk belongs to, following the Homebrew
# bin shim through to the libexec it execs.
program_install_root() {
  local program="$1" resolved dir
  resolved="$(cd "$(dirname "$program")" && pwd)/$(basename "$program")"
  while [[ -L "$resolved" ]]; do
    local target
    target="$(readlink "$resolved")"
    case "$target" in
      /*) resolved="$target" ;;
      *)  resolved="$(cd "$(dirname "$resolved")" && cd "$(dirname "$target")" && pwd)/$(basename "$target")" ;;
    esac
  done
  dir="$(cd "$(dirname "$resolved")/.." && pwd)"
  if [[ -d "$dir/libexec/scripts" ]]; then
    printf '%s' "$dir/libexec"
  else
    printf '%s' "$dir"
  fi
}

# Same loaded-job test health-check.sh uses: a plist sitting in LaunchAgents
# that launchd has not booted is inert, and reporting it as the tick's root
# would name a job that never fires.
label_is_loaded() {
  local label="$1"
  if [[ -n "${AUTOMETTA_LAUNCHD_LOADED_LABELS:-}" ]]; then
    case " $AUTOMETTA_LAUNCHD_LOADED_LABELS " in
      *" $label "*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  command -v launchctl >/dev/null 2>&1 || return 1
  launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1 \
    || launchctl print "system/${label}" >/dev/null 2>&1
}

printf '\nFleet tick root (read from launchd, not assumed):\n'

tick_jobs_found=0
if ! command -v plutil >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  printf '  UNKNOWN no plutil/jq on this host; cannot read the tick plist.\n'
else
  for dir in ${launchd_dirs[@]+"${launchd_dirs[@]}"}; do
    [[ -d "$dir" ]] || continue
    for plist in "$dir"/*.plist; do
      [[ -e "$plist" ]] || continue
      json="$(plutil -convert json -o - "$plist" 2>/dev/null || true)"
      [[ -n "$json" ]] || continue
      printf '%s' "$json" | jq -e '
        (.ProgramArguments // []) as $a
        | ($a | length) > 1
          and (($a[0] // "") | test("(^|/)autometta$"))
          and (($a[1:] | index("tick")) != null)' >/dev/null 2>&1 || continue

      tick_jobs_found=$((tick_jobs_found + 1))
      label="$(printf '%s' "$json" | jq -r '.Label // "(unlabelled)"')"
      program="$(printf '%s' "$json" | jq -r '.ProgramArguments[0]')"
      plist_root="$(printf '%s' "$json" | jq -r '.EnvironmentVariables.AUTOMETTA_ROOT // ""')"

      if label_is_loaded "$label"; then loaded="loaded"; else loaded="NOT loaded"; fi

      if [[ -n "$plist_root" ]] && autometta_root_is_usable "$plist_root"; then
        tick_root="$(cd "$plist_root" && pwd)"
        tick_origin="AUTOMETTA_ROOT in the plist"
      else
        config_root="$(autometta_config_root)"
        if autometta_root_is_usable "$config_root"; then
          tick_root="$(cd "$config_root" && pwd)"
          tick_origin="controller config (plist sets no AUTOMETTA_ROOT)"
        else
          tick_root="$(program_install_root "$program")"
          tick_origin="the install the plist program belongs to"
        fi
      fi

      if [[ "$tick_root" == "$installed_root" ]]; then
        which_side="the INSTALLED build"
      elif [[ "$tick_root" == "$checkout_root" ]]; then
        which_side="the CHECKOUT"
      else
        which_side="a third tree, neither the installed build nor this checkout"
      fi

      printf '  %s (%s)\n' "$label" "$loaded"
      printf '    program: %s\n' "$program"
      printf '    runs:    %s\n' "$tick_root"
      printf '    via:     %s\n' "$tick_origin"
      printf '    that is: %s (%s)\n' "$which_side" "$(autometta_root_sha "$tick_root")"
      if [[ "$tick_root" == "$checkout_root" && -n "$dirty_files" ]]; then
        printf '    EXPOSURE: this root is dirty, so uncommitted edits run on the next tick:\n'
        while IFS= read -r dirty_file; do
          [[ -n "$dirty_file" ]] && printf '              %s\n' "$dirty_file"
        done <<< "$dirty_files"
      fi
    done
  done
  if [[ "$tick_jobs_found" -eq 0 ]]; then
    printf '  none: no launchd job on this host runs `autometta tick`.\n'
  fi
fi

if [[ "$drift" -gt 0 || "$gone" -gt 0 || "$orphan" -gt 0 ]]; then
  printf '\nInstalled build and checkout have drifted. Re-run scripts/install-homebrew-local.sh\n'
  printf 'when no dispatch is in flight; reinstalling replaces files a running tick executes.\n'
  exit 1
fi
printf '\nInstalled build matches the checkout.\n'
