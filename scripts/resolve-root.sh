#!/usr/bin/env bash
# Autometta root resolution: one rule, one place.
#
# Source this file; do not execute it. Every entry point that has to answer
# "which autometta tree do I run code from?" calls the functions here rather
# than restating the rule inline. Two different questions get two different
# functions, and conflating them is what card 42 was written to end:
#
#   autometta_self_root <script-dir>
#     The tree the calling script is physically part of. Packaging and host
#     bootstrap act on themselves -- install-homebrew-local.sh must tar the
#     checkout it lives in, not whichever tree an env var names -- so those
#     use this and never the precedence rule.
#
#   autometta_resolve_root <self-root>
#     The EFFECTIVE root: the tree whose scripts/ a dispatch will execute.
#     Precedence, first hit wins:
#       1. $AUTOMETTA_ROOT          explicit operator or LaunchAgent override
#       2. controller config        autometta_root: in $AUTOMETTA_HOME/config.yaml
#       3. the install's own tree   the libexec (or checkout) the caller sits in
#
# Rule 3 is the floor, so resolution always terminates and never needs a
# hardcoded home-directory path. Rules 1 and 2 are only honoured when they
# name a directory that actually holds scripts/; a stale config entry falls
# through to the floor instead of producing a root with no code in it.
#
# autometta_resolve_root SETS two globals rather than printing, because a
# caller needs both the root and the rule that chose it, and a function called
# in a command substitution cannot hand a second value back:
#   AUTOMETTA_ROOT_RESOLVED  the absolute path
#   AUTOMETTA_ROOT_ORIGIN    a human-readable phrase naming the winning rule
# Callers print the origin; nothing branches on it.

autometta_controller_home() {
  if [[ -n "${AUTOMETTA_HOME:-}" ]]; then
    printf '%s' "$AUTOMETTA_HOME"
  elif [[ -n "${PHAT_CONTROLLER_HOME:-}" ]]; then
    # Deprecated for one release: use AUTOMETTA_HOME.
    printf '%s' "$PHAT_CONTROLLER_HOME"
  elif [[ -e "$HOME/.autometta" || ! -e "$HOME/.phat-controller" ]]; then
    printf '%s' "$HOME/.autometta"
  else
    # Accept an unmigrated host until init-host.sh moves it.
    printf '%s' "$HOME/.phat-controller"
  fi
}

# A candidate is a usable root only if it holds the scripts/ directory every
# entry point dispatches through.
autometta_root_is_usable() {
  local candidate="${1:-}"
  [[ -n "$candidate" && -d "$candidate/scripts" ]]
}

autometta_self_root() {
  local script_dir="$1"
  (cd "$script_dir/.." && pwd)
}

# autometta_root: in the controller config, quotes stripped, empty if absent.
autometta_config_root() {
  local config_file value
  config_file="$(autometta_controller_home)/config.yaml"
  [[ -f "$config_file" ]] || return 0
  value="$(sed -n 's/^autometta_root:[[:space:]]*//p' "$config_file" | head -n 1)"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "$value"
}

autometta_resolve_root() {
  local self_root="$1"
  local candidate

  if autometta_root_is_usable "${AUTOMETTA_ROOT:-}"; then
    AUTOMETTA_ROOT_RESOLVED="$(cd "$AUTOMETTA_ROOT" && pwd)"
    AUTOMETTA_ROOT_ORIGIN="AUTOMETTA_ROOT environment override"
    return 0
  fi

  candidate="$(autometta_config_root)"
  if autometta_root_is_usable "$candidate"; then
    AUTOMETTA_ROOT_RESOLVED="$(cd "$candidate" && pwd)"
    AUTOMETTA_ROOT_ORIGIN="controller config $(autometta_controller_home)/config.yaml"
    return 0
  fi

  AUTOMETTA_ROOT_RESOLVED="$self_root"
  AUTOMETTA_ROOT_ORIGIN="install tree the command was launched from"
}

# True only when the root is itself the top level of a working tree, never
# when it merely sits inside one. `git -C <dir>` searches upward, and the
# Homebrew prefix is a git repository, so a plain rev-parse on
# /opt/homebrew/opt/autometta/libexec cheerfully reports Homebrew's own HEAD
# and calls the installed build a clean checkout. That is the same
# wrong-but-plausible answer this whole card exists to stop.
autometta_root_is_checkout() {
  local root="${1:-}" top
  [[ -n "$root" && -d "$root" ]] || return 1
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$top" ]] || return 1
  # pwd -P on both sides. git reports a physical path, and a root reached
  # through a symlinked parent (/tmp on macOS is /private/tmp) would otherwise
  # compare unequal to its own toplevel: the root would be called "not a
  # checkout" and its uncommitted edits would go unreported, which is the exact
  # class of silent wrong answer this file exists to prevent.
  [[ "$(cd "$top" && pwd -P)" == "$(cd "$root" && pwd -P)" ]]
}

# The sha a root reports for itself. A Homebrew install is not a git checkout,
# so the VERSION file written at package time is the only truth there; a
# checkout's HEAD is the truth for a checkout and outranks a VERSION file left
# behind by the last install. Prints "unknown" when neither exists.
autometta_root_sha() {
  local root="$1" sha
  if autometta_root_is_checkout "$root" \
     && sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)" && [[ -n "$sha" ]]; then
    printf '%s' "$sha"
    return 0
  fi
  if [[ -s "$root/VERSION" ]]; then
    head -n 1 "$root/VERSION" | tr -d '[:space:]'
    return 0
  fi
  printf 'unknown'
}

# Tracked files under scripts/ that differ from HEAD, staged or not. Untracked
# files are deliberately excluded: a scratch file in scripts/ is not code the
# tick will run, whereas an edited tracked script is. Prints one path per line;
# empty output means clean. Callers must check autometta_root_is_checkout
# first -- a non-checkout root has no answer, not a clean one.
autometta_root_dirty_scripts() {
  autometta_root_is_checkout "$1" || return 0
  git -C "$1" diff --name-only HEAD -- scripts/ 2>/dev/null || true
}
