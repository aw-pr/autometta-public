#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# refresh-smoke.sh: exercise the fleet refresh against a disposable fleet.
#
# A refresh writes into other people's repositories, which is the most
# destructive thing autometta does, so its refusals are the part worth testing
# and none of it should be tested by pointing it at a real subscriber. This
# builds a throwaway controller home and four throwaway repos under a temp
# directory, drives every case, and removes them again.
#
# Nothing outside $TMPDIR is written. Exit 0 all cases pass, 1 otherwise.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"

pass=0
fail=0

check() {
  local label="$1" condition="$2"
  if [[ "$condition" == "true" ]]; then
    printf 'PASS %s\n' "$label"; pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$label"; fail=$((fail + 1))
  fi
}

contains() {
  case "$1" in
    *"$2"*) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# pwd -P, because on macOS $TMPDIR is a symlink into /private and the refresh
# reports the physical path it resolved. Comparing the two spellings is a test
# failure that says nothing about the code.
tmp_root="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/autometta-refresh-smoke.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

export PHAT_CONTROLLER_HOME="$tmp_root/controller"
export AUTOMETTA_ROOT="$autometta_root"
export GIT_AUTHOR_NAME="smoke" GIT_AUTHOR_EMAIL="smoke@local"
export GIT_COMMITTER_NAME="smoke" GIT_COMMITTER_EMAIL="smoke@local"
mkdir -p "$PHAT_CONTROLLER_HOME/subscribers"

src_sha="$(cd "$autometta_root" && git rev-parse --short HEAD)"

# A subscriber as it looks a few releases behind: the vendored files copied
# from an older autometta, and a stamp naming that older sha.
make_subscriber() {
  local slug="$1" enabled="$2"
  local repo="$tmp_root/$slug"
  mkdir -p "$repo/templates" "$repo/scripts"
  git -C "$repo" init -q 2>/dev/null || git init -q "$repo"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p "$repo/$(dirname "$f")"
    cp "$autometta_root/$f" "$repo/$f"
  done < <(bash -c ". '$autometta_root/scripts/vendor-set.sh'; autometta_vendored_files")
  # Stale by content as well as by stamp, so vendor-check has something to say.
  printf '\nan edit made upstream after this copy was taken\n' >> "$repo/templates/orchestrator-checklist.md"
  {
    printf '# Autometta vendor stamp. Refresh with: autometta refresh-repo .\n'
    printf 'source_repo: autometta\n'
    printf 'vendored_from: deadbee\n'
    printf 'vendored_at: 2026-08-14\n'
    while IFS= read -r f; do printf 'file: %s\n' "$f"; done \
      < <(bash -c ". '$autometta_root/scripts/vendor-set.sh'; autometta_vendored_files")
  } > "$repo/.autometta-vendor"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit -qm "vendor autometta contract" >/dev/null
  cat > "$PHAT_CONTROLLER_HOME/subscribers/${slug}.yaml" <<YAML
repo_path: "$repo"
weight: 100
enabled: $enabled
YAML
  printf '%s' "$repo"
}

printf '=== fixtures ===\n'
behind="$(make_subscriber behind true)"
dirty="$(make_subscriber dirty true)"
busy="$(make_subscriber busy true)"
off="$(make_subscriber off false)"

# A subscriber that never vendored: registered, but no stamp.
never="$tmp_root/never"
mkdir -p "$never"; git init -q "$never"
cat > "$PHAT_CONTROLLER_HOME/subscribers/never.yaml" <<YAML
repo_path: "$never"
weight: 100
enabled: true
YAML

# A registry entry for a repo that has been removed from disk.
cat > "$PHAT_CONTROLLER_HOME/subscribers/gone.yaml" <<YAML
repo_path: "$tmp_root/gone"
weight: 100
enabled: true
YAML

# A retired registry entry.
cat > "$PHAT_CONTROLLER_HOME/subscribers/retired.yaml.disabled" <<YAML
repo_path: "$tmp_root/retired"
weight: 100
enabled: true
YAML

# Criterion 2 fixture: a placeholder legitimately filled downstream.
filled_line='- Project: sixty-four-tesserae'
python3 - "$behind/templates/worker-prompt.md" "$filled_line" <<'PY'
import re
import sys
path, replacement = sys.argv[1], sys.argv[2]
text = open(path).read()
new, n = re.subn(r'^- Project: <<[^\n]*>>$', replacement, text, count=1, flags=re.M)
if n != 1:
    sys.exit("no '- Project: <<...>>' placeholder line found in " + path)
open(path, 'w').write(new)
PY
git -C "$behind" commit -qam "fill the project placeholder" >/dev/null
filled_digest_before="$(shasum -a 256 "$behind/templates/worker-prompt.md" | awk '{print $1}')"

printf '\n=== criterion 1: vendor-check before the refresh ===\n'
before_out="$(cd "$behind" && "$behind/scripts/autometta-vendor-check.sh" 2>&1 || true)"
printf '%s\n' "$before_out"
check "before: vendor-check reports drift" "$(contains "$before_out" "DRIFT  templates/orchestrator-checklist.md")"
check "before: vendor-check reports the filled file as FILLED" "$(contains "$before_out" "FILLED templates/worker-prompt.md")"

printf '\n=== criterion 3: dry run writes nothing ===\n'
mtimes_before="$(find "$behind" -path "$behind/.git" -prune -o -type f -print0 | xargs -0 stat -f '%N %m' | sort)"
status_before="$(git -C "$behind" status --porcelain)"
dry_out="$("$script_dir/refresh-all-repos.sh" --dry-run 2>&1 || true)"
printf '%s\n' "$dry_out"
mtimes_after="$(find "$behind" -path "$behind/.git" -prune -o -type f -print0 | xargs -0 stat -f '%N %m' | sort)"
status_after="$(git -C "$behind" status --porcelain)"
check "dry run leaves every mtime unchanged" "$([[ "$mtimes_before" == "$mtimes_after" ]] && printf true || printf false)"
check "dry run leaves git status unchanged" "$([[ "$status_before" == "$status_after" ]] && printf true || printf false)"
check "dry run says nothing was written" "$(contains "$dry_out" "Nothing was written")"

printf '\n=== criterion 5: a dirty vendored path is refused ===\n'
printf '\nlocal uncommitted edit\n' >> "$dirty/templates/stage-card.md"
dirty_out="$("$script_dir/refresh-repo.sh" "$dirty" 2>&1 || true)"
printf '%s\n' "$dirty_out"
check "dirty tree refusal names the path" "$(contains "$dirty_out" "REFUSE $dirty: uncommitted changes on vendored path templates/stage-card.md")"

printf '\n=== criterion 8: a repo with a stage in flight is skipped ===\n'
mkdir -p "$busy/state"
cat > "$busy/state/state.yaml" <<'YAML'
version: 1
current_stage: stage-77
stages:
  - id: stage-77
    status: in_progress
YAML
busy_out="$("$script_dir/refresh-repo.sh" "$busy" 2>&1 || true)"
printf '%s\n' "$busy_out"
check "in-flight skip names the stage" "$(contains "$busy_out" "stage in flight: stage-77")"

printf '\n=== criteria 1, 2, 4: the real refresh ===\n'
real_out="$("$script_dir/refresh-all-repos.sh" 2>&1 || true)"
printf '%s\n' "$real_out"
check "refresh updated the drifted file" "$(contains "$real_out" "UPDATE templates/orchestrator-checklist.md")"
check "refresh preserved the filled file" "$(contains "$real_out" "FILLED templates/worker-prompt.md")"
check "skip list names the never-vendored repo" "$(contains "$real_out" "SKIP $never: no .autometta-vendor stamp")"
check "skip list names the missing repo" "$(contains "$real_out" "SKIP $tmp_root/gone: repo_path is not on disk")"
check "skip list names the disabled subscriber" "$(contains "$real_out" "SKIP $off: subscriber is disabled")"
check "skip list names the retired registry entry" "$(contains "$real_out" "retired.yaml.disabled")"
check "skip list still names the dirty repo" "$(contains "$real_out" "REFUSE $dirty")"
check "skip list still names the busy repo" "$(contains "$real_out" "stage in flight")"

filled_digest_after="$(shasum -a 256 "$behind/templates/worker-prompt.md" | awk '{print $1}')"
check "the filled file is byte-identical after the refresh" \
  "$([[ "$filled_digest_before" == "$filled_digest_after" ]] && printf true || printf false)"
check "the filled line survived" \
  "$(contains "$(cat "$behind/templates/worker-prompt.md")" "$filled_line")"
check "the refresh left its changes unstaged in the subscriber" \
  "$([[ -n "$(git -C "$behind" status --porcelain)" ]] && printf true || printf false)"
check "the refresh made no commit in the subscriber" \
  "$([[ "$(git -C "$behind" rev-list --count HEAD)" == "2" ]] && printf true || printf false)"

printf '\n=== criterion 1: vendor-check after the refresh ===\n'
after_out="$(cd "$behind" && "$behind/scripts/autometta-vendor-check.sh" 2>&1 || true)"
printf '%s\n' "$after_out"
check "after: vendor-check reports no drift" "$(contains "$after_out" "0 drifted, 0 missing locally")"
check "after: vendor-check reports the contract current" "$(contains "$after_out" "Vendored Autometta contract is current")"
check "after: the stamp names the current sha" \
  "$(contains "$(cat "$behind/.autometta-vendor")" "vendored_from: $src_sha")"

printf '\n=== criteria 6, 7: the tick staleness warning ===\n'
# Sourcing tick.sh loads its functions without firing the loop, so the warning
# can be driven directly. Running a real tick here would dispatch agents.
warn_log="$tmp_root/warn.log"
bash -c '
  set -euo pipefail
  source "'"$autometta_root"'/scripts/tick.sh"
  warn_if_vendor_stale "'"$busy"'"
  warn_if_vendor_stale "'"$busy"'"
  warn_if_vendor_stale "'"$behind"'"
' >"$warn_log" 2>&1 || true
warn_out="$(cat "$warn_log")"
printf '%s\n' "$warn_out"
stale_count="$(printf '%s\n' "$warn_out" | grep -c "stale vendor: $busy " || true)"
current_count="$(printf '%s\n' "$warn_out" | grep -c "stale vendor: $behind " || true)"
check "a stale subscriber warns exactly once per pass" "$([[ "$stale_count" == "1" ]] && printf true || printf false)"
check "the warning names both shas" "$(contains "$warn_out" "holds the contract from deadbee, autometta is at $src_sha")"
check "a current subscriber produces no warning" "$([[ "$current_count" == "0" ]] && printf true || printf false)"

printf '\n%d passed, %d failed.\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
