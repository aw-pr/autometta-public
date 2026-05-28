#!/usr/bin/env bash
set -euo pipefail

# Smoke-tests the homebrew install pipeline.
# Runs install-homebrew-local.sh, verifies `autometta --version` matches
# the repo's HEAD short SHA, and removes the archive artifact created during install.
#
# Exit 0: version matches and install artefact cleaned up.
# Exit 1: version mismatch, missing prerequisite, or install failure.
#
# Usage: ./check-brew-install.sh [--repo-root <path>]

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) shift; repo_root="$1" ;;
    *) echo "Usage: $0 [--repo-root <path>]" >&2; exit 1 ;;
  esac
  shift
done

install_script="$repo_root/scripts/install-homebrew-local.sh"

if [[ ! -x "$install_script" ]]; then
  echo "ERROR: install script not found or not executable: $install_script"
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: brew not on PATH — cannot smoke-test install"
  exit 1
fi

expected_version=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "")
if [[ -z "$expected_version" ]]; then
  echo "ERROR: cannot determine HEAD short SHA from $repo_root"
  exit 1
fi

echo "Running install-homebrew-local.sh (expected version: $expected_version)..."
"$install_script"

actual_version=$(autometta --version 2>/dev/null | awk '{print $NF}' || echo "")
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "ERROR: version mismatch — got '${actual_version}', expected '${expected_version}'"
  exit 1
fi

echo "OK: autometta --version reports ${actual_version}"

# Clean up the versioned archive created during install (accumulates over runs).
tap_dir="$(brew --repository)/Library/Taps/local/homebrew-autometta"
archive="$tap_dir/autometta-${expected_version}.tar.gz"
if [[ -f "$archive" ]]; then
  rm -f "$archive"
  echo "Cleaned up archive: $archive"
fi

echo "PASS: brew install smoke test complete"
