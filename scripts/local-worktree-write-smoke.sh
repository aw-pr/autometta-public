#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
spawn_worker="${AUTOMETTA_SPAWN_WORKER_UNDER_TEST:-$script_dir/spawn-worker.sh}"
fixture_parent="$(mktemp -d "$repo_root/.autometta-local-worktree-write.XXXXXX")"
work_scratch="$(mktemp -d "${TMPDIR:-/tmp}/autometta-local-worktree-write.XXXXXX")"
fixture_repo="$fixture_parent/subscriber"
work_dir="$work_scratch/subscriber-run-01-probe"
probe="$work_dir/local-worker.probe"
log="$fixture_repo/state/logs/01-probe-worker.log"
system_tmp_root="$(cd /tmp && pwd -P)"
task_tmp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
pid=""

cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  if [[ -d "$fixture_repo/.git" && -d "$work_dir" ]]; then
    git -C "$fixture_repo" worktree remove --force "$work_dir" >/dev/null 2>&1 || true
  fi
  case "$fixture_parent" in
    "$repo_root"/.autometta-local-worktree-write.*) rm -rf "$fixture_parent" ;;
  esac
  case "$work_scratch" in
    "${TMPDIR:-/tmp}"/autometta-local-worktree-write.*) rm -rf "$work_scratch" ;;
  esac
}
trap cleanup EXIT

for command in codex ollama op-fetch yq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'FAIL: %s is required for the real local-route smoke\n' "$command" >&2
    exit 1
  fi
done

case "$fixture_repo/" in
  "$system_tmp_root"/*|"$task_tmp_root"/*)
    printf 'FAIL: subscriber fixture must be outside codex temporary-directory roots: %s\n' \
      "$fixture_repo" >&2
    exit 1
    ;;
esac

mkdir -p "$fixture_repo/state/handoffs" "$fixture_repo/state/logs"
printf 'fixture\n' >"$fixture_repo/README.md"

git -C "$fixture_repo" init -q -b dev
git -C "$fixture_repo" add README.md
git -C "$fixture_repo" -c user.name=fixture -c user.email=fixture@local \
  commit -qm 'fixture'
git -C "$fixture_repo" worktree add -q -b autometta/01-probe "$work_dir" HEAD
ln -s "$fixture_repo/state" "$work_dir/state"

# Keep the card in the subscriber checkout, matching the incident. The card
# below asks for a target rather than forcing one, so the pre-fix arm still
# depends on the model obeying it; the real sandbox remains responsible for
# accepting or refusing the write.
mkdir -p "$fixture_repo/stage-cards"
cat >"$fixture_repo/stage-cards/01-probe.md" <<'CARD'
# Stage card 01-probe

## Metadata

- **Worker:** Codex GPT-OSS 20B <codex-gpt-oss-20b@local>
- **Worker effort:** low
- **Requires GUI:** false

## Objective

Use one shell command to write the exact line `local worker wrote here` to the
repo-relative file `local-worker.probe`.

Choose the command's working directory from the dispatch metadata. If
Family-specific notes contains `Repository worktree: <path>`, use that exact
path. Otherwise use the checkout containing this stage card. Do not use the
shell's inherited directory as a substitute for this rule.

## Inputs (read these in your own context)

None.

## Deliverables

1. `local-worker.probe` containing the exact line `local worker wrote here`.

## Constraints

- Use a shell redirection for the write.
- Attempt the write once, then stop whether it succeeds or fails.
- Do not use `apply_patch` and do not create any other file.

## Acceptance criteria

1. `local-worker.probe` exists in the selected repository worktree with the
   required content.

## Out of scope

- Any other repository file.

## Budget

- **Worker wall-clock:** 120s
CARD
cat >"$fixture_repo/state/state.yaml" <<'STATE'
current_stage: null
stages:
  - id: 01-probe
    status: pending
STATE

pid="$({
  AUTOMETTA_CODEX_MODE=local \
    AUTOMETTA_MODEL_CODEX_LOCAL_WORKER=gpt-oss:20b \
    "$spawn_worker" "$fixture_repo/stage-cards/01-probe.md" \
      "$fixture_repo" "$work_dir"
} 2>"$work_scratch/spawn.err")" || {
  cat "$work_scratch/spawn.err" >&2
  printf 'FAIL: local worker did not start\n' >&2
  exit 1
}

if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  cat "$work_scratch/spawn.err" >&2
  printf 'FAIL: spawn-worker returned an invalid pid: %s\n' "$pid" >&2
  exit 1
fi

finished=false
for _ in $(seq 1 240); do
  if [[ -f "$log" ]] && grep -q '^tokens used$' "$log"; then
    finished=true
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    finished=true
    break
  fi
  sleep 0.5
done

if [[ "$finished" != true ]]; then
  [[ -f "$log" ]] && cat "$log" >&2
  printf 'FAIL: real local worker exceeded the smoke timeout\n' >&2
  exit 1
fi
if [[ ! -f "$probe" ]]; then
  [[ -f "$log" ]] && cat "$log" >&2
  printf 'FAIL: real local worker did not write inside its linked worktree\n' >&2
  exit 1
fi
if [[ "$(cat "$probe")" != "local worker wrote here" ]]; then
  printf 'FAIL: local worker wrote unexpected probe content\n' >&2
  exit 1
fi
if [[ -e "$fixture_repo/local-worker.probe" ]]; then
  printf 'FAIL: local worker wrote to the subscriber checkout\n' >&2
  exit 1
fi

printf 'PASS: real local worker wrote inside the linked run worktree\n'
