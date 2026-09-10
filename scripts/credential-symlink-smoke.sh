#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/autometta-credential-symlink.XXXXXX")"
link_path="$repo_root/.credential-symlink-smoke-$$"
ordinary_link="$repo_root/.credential-symlink-ordinary-smoke-$$"
secret_value='not-a-real-token-smoke-fixture'

cleanup() {
  rm -f "$link_path" "$ordinary_link"
  rm -rf "$fixture_dir"
}
trap cleanup EXIT

printf '%s\n' "$secret_value" >"$fixture_dir/auth.json"
printf 'ordinary fixture\n' >"$fixture_dir/ordinary.txt"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/123-no-symlink-in-the-tree-points-at-a-credential.md
ln -s "$fixture_dir/auth.json" "$link_path"
failure_output="$("$script_dir/check-deps.sh" 2>&1 || true)"
if "$script_dir/check-deps.sh" >/dev/null 2>&1; then
  printf 'expected credential symlink check to fail\n' >&2
  exit 1
fi
if [[ "$failure_output" != *"${link_path#"$repo_root"/}"* || "$failure_output" != *"auth.json"* ]]; then
  printf 'credential symlink failure did not name the link and category\n' >&2
  exit 1
fi
if [[ "$failure_output" == *"$secret_value"* ]]; then
  printf 'credential symlink failure printed fixture contents\n' >&2
  exit 1
fi
rm -f "$link_path"
ln -s "$fixture_dir/ordinary.txt" "$ordinary_link"
if ! "$script_dir/check-deps.sh" >/dev/null 2>&1; then
  printf 'ordinary symlink unexpectedly failed dependency check\n' >&2
  exit 1
fi
# AUTOMETTA-CONTRACT-END

printf 'PASS credential symlink smoke\n'
