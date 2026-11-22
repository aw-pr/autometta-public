#!/usr/bin/env bash
# Offline proof for stage card 172: a codex role's agent-home grant stays
# inside the per-session directory, and the tick never runs a git hook that a
# worker could have edited in its run worktree. No auth, network or provider
# dispatch. The agent-home checks point HOME at a fixture; the git fixtures run
# with global and system git config ignored, so no operator setting leaks in.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
fixture="$(cd "$fixture" && pwd -P)"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT
export PHAT_CONTROLLER_HOME="$fixture/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/log"
# tick.sh resolves its controller paths while it is sourced; it also sources
# models.sh through cost-log.sh.
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"
set -euo pipefail
IFS=$'\n\t'

fail() {
  printf 'FAIL: 172-agent-sandboxes-stay-scoped: %s\n' "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/172-agent-sandboxes-stay-scoped.md
unset CLAUDE_CONFIG_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# home_grant <home> <requires-agent-home> <sandbox> [claude-config-dir]
# Prints the agent-home argv joined on spaces, computed with HOME pointed at
# a fixture so no real directory is read or created.
home_grant() {
  (
    export HOME="$1"
    if [[ -n "${4:-}" ]]; then export CLAUDE_CONFIG_DIR="$4"; else unset CLAUDE_CONFIG_DIR; fi
    codex_agent_home_argv_for_card "$2" "$3"
    IFS=' '
    printf '%s' "${AUTOMETTA_CODEX_AGENT_HOME_ARGV[*]-}"
  )
}

# M4. The grant is the per-session directory, never the whole Claude home.
home_a="$fixture/home-a"
mkdir -p "$home_a/.claude/session-env"
got="$(home_grant "$home_a" true workspace-write)"
[[ "$got" == "--add-dir $home_a/.claude/session-env" ]] \
  || fail "M4: agent-home grant is '$got', expected only --add-dir $home_a/.claude/session-env"

cfg="$fixture/alt-claude-config"
mkdir -p "$cfg"
got="$(home_grant "$home_a" true workspace-write "$cfg")"
[[ "$got" == "--add-dir $cfg/session-env" ]] \
  || fail "M4: with CLAUDE_CONFIG_DIR the grant is '$got', expected --add-dir $cfg/session-env"
[[ -d "$cfg/session-env" ]] \
  || fail "M4: the granted session-env directory was not created under an existing Claude home"

home_b="$fixture/home-b"
mkdir -p "$home_b/.claude"
got="$(home_grant "$home_b" true workspace-write)"
[[ "$got" == "--add-dir $home_b/.claude/session-env" && -d "$home_b/.claude/session-env" ]] \
  || fail "M4: a Claude home without session-env got '$got' and no created session-env"

home_c="$fixture/home-c"
mkdir -p "$home_c"
got="$(home_grant "$home_c" true workspace-write)"
[[ -z "$got" && ! -e "$home_c/.claude" ]] \
  || fail "M4: a machine with no Claude home got grant '$got' or a created Claude home"

# Unchanged: no grant, and nothing created, for a card that does not ask or
# outside workspace-write.
home_n="$fixture/home-n"
mkdir -p "$home_n/.claude"
[[ -z "$(home_grant "$home_n" false workspace-write)" ]] || fail "M4: a card that does not ask got an agent-home grant"
[[ -z "$(home_grant "$home_n" "" workspace-write)" ]] || fail "M4: a card with no Requires agent home line got a grant"
[[ -z "$(home_grant "$home_n" true danger-full-access)" ]] || fail "M4: danger-full-access got an agent-home grant"
[[ -z "$(home_grant "$home_n" true read-only)" ]] || fail "M4: read-only gained a writable agent home"
[[ ! -e "$home_n/.claude/session-env" ]] || fail "M4: a no-grant case created session-env"

template_line="$(grep -m1 '^- \*\*Requires agent home:\*\*' "$script_dir/../templates/stage-card.md" || true)"
[[ -n "$template_line" ]] || fail "M4: templates/stage-card.md has no Requires agent home line"
[[ "$template_line" == *'write access only, to the `session-env` directory inside it'* ]] \
  || fail "M4: the template's Requires agent home line does not name the session-env directory as the grant"
[[ "$template_line" != *'to that one directory'* ]] \
  || fail "M4: the template still says the grant is the whole Claude home directory"

# M8. Hooks a worker edits in its run worktree never run on the tick's side.
# make_hook_repo <name> <stage-id> <tracked|default|absolute> <marker>
# The operator's hooks append "<layout> pre-commit" and "<layout> commit-msg"
# to the marker file: tracked ones in .githooks (core.hooksPath=.githooks),
# default ones in .git/hooks, absolute ones in a directory outside the repo.
make_hook_repo() {
  local name="$1" stage_id="$2" layout="$3" marker="$4" repo hook_dir hook
  repo="$fixture/$name"
  mkdir -p "$repo/state/verifiers" "$repo/state/logs"
  (
    cd "$repo"
    git init -q -b dev
    git config user.name Smoke
    git config user.email smoke@local
    git config commit.gpgsign false
    printf 'state/**\n' > .gitignore
    printf 'seed\n' > README.md
    case "$layout" in
      tracked)  hook_dir="$repo/.githooks" ;;
      default)  hook_dir="$repo/.git/hooks" ;;
      absolute) hook_dir="$fixture/$name-operator-hooks" ;;
    esac
    mkdir -p "$hook_dir"
    for hook in pre-commit commit-msg; do
      printf '#!/bin/sh\nprintf "%s %s\\n" >> "%s"\nexit 0\n' "$layout" "$hook" "$marker" > "$hook_dir/$hook"
      chmod +x "$hook_dir/$hook"
    done
    [[ "$layout" == tracked ]] && git add .githooks
    git add .gitignore README.md
    git commit -q --no-verify -m seed
    case "$layout" in
      tracked)  git config core.hooksPath .githooks ;;
      absolute) git config core.hooksPath "$hook_dir" ;;
    esac
  )
  cat > "$repo/state/state.yaml" <<YAML
version: 1
current_stage: $stage_id
stages:
  - id: $stage_id
    status: in_progress
    worker: "GPT-6.1 Sol <gpt-6-1-sol@local>"
    verifier: "Claude Opus 5.5 <claude-opus-5-5@local>"
    base_branch: dev
    verifier_artefact: state/verifiers/$stage_id.json
YAML
  cat > "$repo/state/verifiers/$stage_id.json" <<'JSON'
{"overall":"FAIL","criteria":[{"id":1,"name":"fixture","verdict":"FAIL","evidence":"fixture fail"}],"additional_findings":""}
JSON
  printf '%s' "$repo"
}

# worker_edits_hooks <worktree> <marker>: what a sandboxed worker can do to a
# tracked hooks directory: rewrite the operator's hooks and add hooks git runs
# on commit, on any ref update and on any index write.
worker_edits_hooks() {
  local wt="$1" marker="$2" hook
  mkdir -p "$wt/.githooks"
  for hook in pre-commit post-commit reference-transaction post-index-change prepare-commit-msg commit-msg; do
    printf '#!/bin/sh\nprintf "worker %s\\n" >> "%s"\nexit 0\n' "$hook" "$marker" > "$wt/.githooks/$hook"
    chmod +x "$wt/.githooks/$hook"
  done
  printf 'near passing work\n' > "$wt/result.txt"
}

preserve() {
  preserve_failed_work "$1" "$1/state/state.yaml" "$2" "$1/state/verifiers/$2.json" >/dev/null 2>&1 || true
}

no_worker_hooks() {
  if grep -q '^worker' "$1"; then
    fail "M8: $2: the tick ran worker-edited hooks: $(grep '^worker' "$1" | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
  fi
}

# Tracked relative hooks path: the worker's edits never run; the operator's do.
stage_t=72-hooks-tracked
marker_t="$fixture/marker-tracked"
repo_t="$(make_hook_repo tracked "$stage_t" tracked "$marker_t")"
wt_t="$(ensure_run_worktree "$repo_t" "$stage_t" dev)"
[[ -d "$wt_t" && -x "$wt_t/.githooks/pre-commit" ]] || fail "M8: fixture run worktree did not materialise the tracked hook"
worker_edits_hooks "$wt_t" "$marker_t"
: > "$marker_t"
preserve "$repo_t" "$stage_t"
wip_t="$(git -C "$repo_t" rev-parse --verify --quiet "refs/heads/wip/$stage_t-attempt-1" || true)"
[[ -n "$wip_t" ]] || fail "M8: the failed attempt was not preserved on wip/$stage_t-attempt-1"
git -C "$repo_t" cat-file -e "$wip_t:result.txt" 2>/dev/null \
  || fail "M8: the preserved commit does not contain the worker's result.txt"
no_worker_hooks "$marker_t" "preserve"
grep -qx 'tracked pre-commit' "$marker_t" \
  || fail "M8: the operator's own pre-commit hook did not run on the preserve commit (hooks must not be skipped)"
grep -qx 'tracked commit-msg' "$marker_t" \
  || fail "M8: the operator's own commit-msg hook did not run on the preserve commit (hooks must not be skipped)"

# Rollback: the pin cannot be written, so preserve resets the worktree back.
stage_r=74-hooks-rollback
marker_r="$fixture/marker-rollback"
repo_r="$(make_hook_repo rollback "$stage_r" tracked "$marker_r")"
wt_r="$(ensure_run_worktree "$repo_r" "$stage_r" dev)"
worker_edits_hooks "$wt_r" "$marker_r"
mkdir -p "$repo_r/.git/refs/heads/wip"
chmod a-w "$repo_r/.git/refs/heads/wip"
: > "$marker_r"
preserve "$repo_r" "$stage_r"
chmod u+w "$repo_r/.git/refs/heads/wip"
if git -C "$repo_r" rev-parse --verify --quiet "refs/heads/wip/$stage_r-attempt-1" >/dev/null; then
  fail "M8: rollback fixture: the wip pin was written although its directory was read-only"
fi
[[ -f "$wt_r/result.txt" ]] || fail "M8: rollback fixture: the worker's result.txt was lost"
no_worker_hooks "$marker_r" "preserve rollback"

# Unchanged: the default .git/hooks layout and an absolute hooks path.
for layout in default absolute; do
  stage_l="75-hooks-$layout"
  marker_l="$fixture/marker-$layout"
  repo_l="$(make_hook_repo "$layout" "$stage_l" "$layout" "$marker_l")"
  wt_l="$(ensure_run_worktree "$repo_l" "$stage_l" dev)"
  printf '%s layout work\n' "$layout" > "$wt_l/result.txt"
  : > "$marker_l"
  preserve "$repo_l" "$stage_l"
  git -C "$repo_l" rev-parse --verify --quiet "refs/heads/wip/$stage_l-attempt-1" >/dev/null \
    || fail "M8: $layout hooks layout: the failed attempt was not preserved"
  grep -qx "$layout pre-commit" "$marker_l" \
    || fail "M8: $layout hooks layout: the operator's pre-commit no longer runs on the preserve commit"
  grep -qx "$layout commit-msg" "$marker_l" \
    || fail "M8: $layout hooks layout: the operator's commit-msg no longer runs on the preserve commit"
done
# AUTOMETTA-CONTRACT-END

printf 'PASS sandbox-scope-smoke: agent-home grant is session-env only; preserve runs only operator hooks\n'
