#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gate="$repo_root/scripts/check-contract-test-gate.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/contract-gate-smoke.XXXXXX")"
marker_prefix='AUTOMETTA-CONTRACT'
marker_begin="$marker_prefix-BEGIN"
marker_end="$marker_prefix-END"
trap 'rm -rf "$tmp_root"' EXIT

passed=0

fail() {
  printf 'not ok: %s\n' "$*" >&2
  exit 1
}

assert_case() {
  local name="$1"
  shift
  "$@" || fail "$name"
  passed=$((passed + 1))
  printf 'ok: %s\n' "$name"
}

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Contract Gate Smoke'
  git -C "$repo" config user.email 'contract-gate-smoke@local'
  mkdir -p "$repo/scripts" "$repo/stage-cards" "$repo/fixtures"
  cp "$gate" "$repo/scripts/check-contract-test-gate.sh"
  chmod +x "$repo/scripts/check-contract-test-gate.sh"
}

write_test() {
  local repo="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# %s card=stage-cards/fixture.md\n' "$marker_begin"
    printf '%s\n' "$body"
    printf '# %s\n' "$marker_end"
  } > "$repo/fixtures/contract-test.sh"
  chmod +x "$repo/fixtures/contract-test.sh"
}

digest() {
  "$1/scripts/check-contract-test-gate.sh" print "$1/fixtures/contract-test.sh"
}

write_card() {
  local repo="$1" declared="${2:-}"
  {
    printf '# Fixture card\n\n'
    printf -- '- **Test file:** `fixtures/contract-test.sh`\n'
    if [ -n "$declared" ]; then
      printf -- '- **Assertions digest:** `%s`\n' "$declared"
    fi
  } > "$repo/stage-cards/fixture.md"
}

old_bare_gate() {
  local staged
  staged="$(git diff --cached --name-only --diff-filter=ACM)"
  [ -n "$staged" ] || return 0
  return 1
}

case_nothing_staged() {
  local repo="$tmp_root/nothing-staged" output rc
  new_repo "$repo"
  set +e
  output="$(cd "$repo" && ./scripts/check-contract-test-gate.sh 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'no staged files to inspect'
}

case_staged_matching_digest() {
  local repo="$tmp_root/staged-matching" declared
  new_repo "$repo"
  write_test "$repo" 'printf "matching\\n"'
  declared="$(digest "$repo")"
  write_card "$repo" "$declared"
  git -C "$repo" add fixtures/contract-test.sh stage-cards/fixture.md
  (cd "$repo" && ./scripts/check-contract-test-gate.sh)
}

case_staged_drifted_block() {
  local repo="$tmp_root/staged-drifted" declared
  new_repo "$repo"
  write_test "$repo" 'printf "original\\n"'
  declared="$(digest "$repo")"
  write_card "$repo" "$declared"
  write_test "$repo" 'printf "drifted\\n"'
  git -C "$repo" add fixtures/contract-test.sh stage-cards/fixture.md
  ! (cd "$repo" && ./scripts/check-contract-test-gate.sh >/dev/null 2>&1)
}

case_staged_card_absent() {
  local repo="$tmp_root/card-absent" declared
  new_repo "$repo"
  write_test "$repo" 'printf "original\\n"'
  declared="$(digest "$repo")"
  write_card "$repo" "$declared"
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
  write_test "$repo" 'printf "drifted\\n"'
  git -C "$repo" add fixtures/contract-test.sh
  ! (cd "$repo" && ./scripts/check-contract-test-gate.sh >/dev/null 2>&1)
}

case_card_without_digest() {
  local repo="$tmp_root/no-digest"
  new_repo "$repo"
  write_test "$repo" 'printf "matching\\n"'
  write_card "$repo"
  git -C "$repo" add fixtures/contract-test.sh stage-cards/fixture.md
  ! (cd "$repo" && ./scripts/check-contract-test-gate.sh >/dev/null 2>&1)
}

case_dirty_worktree_drift() {
  local repo="$tmp_root/worktree-drift" declared old_rc new_rc
  new_repo "$repo"
  write_test "$repo" 'printf "original\\n"'
  declared="$(digest "$repo")"
  write_card "$repo" "$declared"
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
  write_test "$repo" 'printf "drifted\\n"'
  set +e
  (cd "$repo" && old_bare_gate)
  old_rc=$?
  (cd "$repo" && ./scripts/check-contract-test-gate.sh --worktree >/dev/null 2>&1)
  new_rc=$?
  set -e
  [ "$old_rc" -eq 0 ] || return 1
  [ "$new_rc" -ne 0 ] || return 1
}

case_untracked_contract_test_drift() {
  local repo="$tmp_root/untracked-drift" declared old_rc new_rc
  new_repo "$repo"
  write_test "$repo" 'printf "original\\n"'
  declared="$(digest "$repo")"
  write_card "$repo" "$declared"
  git -C "$repo" add stage-cards/fixture.md
  git -C "$repo" commit -qm baseline
  write_test "$repo" 'printf "new untracked drift\\n"'
  set +e
  (cd "$repo" && old_bare_gate)
  old_rc=$?
  (cd "$repo" && ./scripts/check-contract-test-gate.sh --worktree >/dev/null 2>&1)
  new_rc=$?
  set -e
  [ "$old_rc" -eq 0 ] || return 1
  [ "$new_rc" -ne 0 ] || return 1
}

case_ordinary_commit_through_hook() {
  local repo="$tmp_root/ordinary-commit"
  new_repo "$repo"
  mkdir -p "$repo/.hooks"
  cat > "$repo/.hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
exec ./scripts/check-contract-test-gate.sh
EOF
  chmod +x "$repo/.hooks/pre-commit"
  git -C "$repo" config core.hooksPath .hooks
  printf 'ordinary change\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm ordinary
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/129-a-bare-gate-invocation-inspects-nothing.md
assert_case 'nothing staged is a distinct non-pass' case_nothing_staged
assert_case 'staged marker with matching declared digest passes' case_staged_matching_digest
assert_case 'staged frozen block drift fails' case_staged_drifted_block
assert_case 'staged marked file without its card fails' case_staged_card_absent
assert_case 'card without Assertions digest fails' case_card_without_digest
assert_case 'dirty unstaged frozen-block drift is caught by --worktree' case_dirty_worktree_drift
assert_case 'untracked contract-test drift is caught by --worktree' case_untracked_contract_test_drift
assert_case 'ordinary commit passes through the pre-commit hook' case_ordinary_commit_through_hook
# AUTOMETTA-CONTRACT-END

printf 'contract-gate smoke passed: %d assertions\n' "$passed"
