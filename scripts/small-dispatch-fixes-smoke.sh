#!/usr/bin/env bash
# small-dispatch-fixes-smoke.sh: card 173's six small dispatch fixes, one
# assertion group each, from the 2026-11-15 dispatch-path review
# (docs/reviews/2026-11-15-dispatch-path.md):
#
#   M6        a stage resolves only its own card, and a requeue kills only
#             its own agent (no substring matching on stage ids)
#   M7        the cost-log records the per-role billing route
#   L1        card identities and paths reach the rendered prompts verbatim
#             and never run as sed flags
#   L4        auth.sh reads the sibling CODEX_HOME's auth_mode without
#             interpolating the path into Python source
#   L6        the tick's awaiting-integration push asks git-push-check first
#   identity  the tick's own state snapshot commits are authored as the loop
#
# Offline: every external command (op-fetch, git-push-check, agent-whoami)
# is a stub on PATH, every repo is a fixture under mktemp, and nothing reads
# or writes the operator's ~/.autometta. Each group prints at most one
# `FAIL: 173-small-dispatch-fixes: <reason>` line; any failure exits 1.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  local p
  if [[ -f "$tmp/sleepers" ]]; then
    while IFS= read -r p; do kill "$p" 2>/dev/null || true; done <"$tmp/sleepers"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

export AUTOMETTA_HOME="$tmp/autometta-home"
export PHAT_CONTROLLER_HOME="$AUTOMETTA_HOME"
export AUTOMETTA_ESCALATIONS="$tmp/escalations"
export AUTOMETTA_NOTIFY=0
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log" "$AUTOMETTA_HOME/dashboard"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL \
  AUTOMETTA_CLAUDE_MODE AUTOMETTA_CODEX_MODE AUTOMETTA_CLAUDE_MODE_WORKER \
  AUTOMETTA_CLAUDE_MODE_VERIFIER AUTOMETTA_CODEX_MODE_WORKER AUTOMETTA_CODEX_MODE_VERIFIER

fail() {
  printf 'FAIL: 173-small-dispatch-fixes: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/173-small-dispatch-fixes.md
failed_groups=0

# A PATH with no real git-push-check or agent-whoami on it, so a stub is the
# only one a group can reach and the missing-helper case is really missing.
c173_clean_path() {
  local out="" dir
  local IFS=':'
  for dir in $PATH; do
    [[ -n "$dir" ]] || continue
    [[ -x "$dir/git-push-check" || -x "$dir/agent-whoami" ]] && continue
    out="${out:+$out:}$dir"
  done
  printf '%s\n' "$out"
}
clean_path="$(c173_clean_path)"

c173_git_fixture() {
  # c173_git_fixture <dir>: a repo on dev with one seed commit.
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b dev .
    git config user.name smoke
    git config user.email smoke@local
    git config commit.gpgsign false
    printf 'state/**\n' >.gitignore
    printf 'seed\n' >README.md
    git add -A
    git commit -qm seed
  )
}

c173_sleeper() {
  # A process that is not this shell's child, so a kill reaps it at once
  # and kill -0 afterwards answers truthfully.
  local pid
  pid="$( (sleep 300 >/dev/null 2>&1 & printf '%s' "$!") )"
  printf '%s\n' "$pid" >>"$tmp/sleepers"
  printf '%s\n' "$pid"
}

# --- M6: a stage resolves only its own card ---------------------------------
c173_m6() {
  local base="$tmp/m6" layout repo got
  for layout in stage-cards docs/stages examples/self-host; do
    repo="$base/${layout//\//-}"
    mkdir -p "$repo/$layout" "$repo/state"
    printf '# Stage card 112\n' >"$repo/$layout/112-fix-auth.md"
    printf '# Stage card 12 v2\n' >"$repo/$layout/12-fix-auth-v2.md"
    got="$(stage_card_for_id "$repo" 12-fix-auth "")"
    [[ -z "$got" ]] \
      || fail "M6: stage 12-fix-auth resolved to another stage's card under ${layout}: ${got}"
    printf '# Stage card 12\n' >"$repo/$layout/12-fix-auth.md"
    got="$(stage_card_for_id "$repo" 12-fix-auth "")"
    [[ "$got" == "$repo/$layout/12-fix-auth.md" ]] \
      || fail "M6: stage 12-fix-auth did not resolve its own card under ${layout} (got '${got}')"
    got="$(stage_card_for_id "$repo" 112-fix-auth "")"
    [[ "$got" == "$repo/$layout/112-fix-auth.md" ]] \
      || fail "M6: stage 112-fix-auth did not resolve its own card under ${layout} (got '${got}')"
  done


  # requeue-stage.sh kills the live agent registered for the stage it
  # re-queues, and only that one.
  repo="$base/requeue"
  c173_git_fixture "$repo"
  mkdir -p "$repo/state/active-agents" "$repo/stage-cards"
  printf '# Stage card 12\n' >"$repo/stage-cards/12-fix-auth.md"
  printf '# Stage card 112\n' >"$repo/stage-cards/112-fix-auth.md"
  cat >"$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: 112-fix-auth
stages:
  - id: 12-fix-auth
    status: failed
    started_at: null
  - id: 112-fix-auth
    status: in_progress
    started_at: null
YAML
  local p12 p112
  p12="$(c173_sleeper)"
  p112="$(c173_sleeper)"
  jq -n --argjson pid "$p12" --arg card "$repo/stage-cards/12-fix-auth.md" \
    '{pid:$pid, role:"worker", card_path:$card}' >"$repo/state/active-agents/$p12.json"
  jq -n --argjson pid "$p112" --arg card "$repo/stage-cards/112-fix-auth.md" \
    '{pid:$pid, role:"worker", card_path:$card}' >"$repo/state/active-agents/$p112.json"
  "$script_dir/requeue-stage.sh" --keep-budget "$repo" 12-fix-auth >"$base/requeue.out" 2>&1 \
    || fail "M6: requeue-stage.sh failed on the fixture: $(tail -n1 "$base/requeue.out")"
  kill -0 "$p112" 2>/dev/null \
    || fail "M6: re-queueing 12-fix-auth killed the live agent of 112-fix-auth"
  [[ -f "$repo/state/active-agents/$p112.json" ]] \
    || fail "M6: re-queueing 12-fix-auth removed 112-fix-auth's agent registration"
  ! kill -0 "$p12" 2>/dev/null \
    || fail "M6: re-queueing 12-fix-auth left its own live agent running"
  [[ ! -f "$repo/state/active-agents/$p12.json" ]] \
    || fail "M6: re-queueing 12-fix-auth kept its own agent registration"
}

# --- M7: the cost-log records the per-role route -----------------------------
c173_m7() {
  local repo="$tmp/m7/repo" log_file="$tmp/m7/role.log" row
  mkdir -p "$repo/state"
  printf 'Total tokens: 1200\n' >"$log_file"
  c173_route_of() {
    # c173_route_of <role> <identity>: the auth_route of the row appended.
    costlog_append "$repo" 07-route "$1" "$2" "$log_file" 10 pass 2>/dev/null
    tail -n1 "$repo/state/cost-log.jsonl" | jq -r '.auth_route'
  }
  local claude='Claude Opus 5.5 <claude-opus-5-5@local>'
  local codex='GPT-6.1 Sol <gpt-6-1-sol@local>'

  [[ "$(c173_route_of verifier "$claude")" == subscription ]] \
    || fail "M7: with no manifest a Claude verifier row is not 'subscription'"

  cat >"$repo/.autometta.local.yaml" <<'YAML'
auth:
  claude:
    mode: subscription
    verifier:
      mode: api
  codex:
    mode: api
    worker:
      mode: local
YAML
  row="$(c173_route_of verifier "$claude")"
  [[ "$row" == api ]] \
    || fail "M7: auth.claude.verifier.mode api recorded as '${row}' on the verifier row"
  row="$(c173_route_of worker "$codex")"
  [[ "$row" == local ]] \
    || fail "M7: auth.codex.worker.mode local recorded as '${row}' on the worker row"
  row="$(c173_route_of worker "$claude")"
  [[ "$row" == subscription ]] \
    || fail "M7: a Claude worker with no per-role key did not fall back to the family mode (got '${row}')"
  row="$(c173_route_of verifier "$codex")"
  [[ "$row" == api ]] \
    || fail "M7: a codex verifier with no per-role key did not fall back to the family mode (got '${row}')"
  row="$(AUTOMETTA_CLAUDE_MODE_WORKER=api AUTOMETTA_CLAUDE_MODE=subscription c173_route_of worker "$claude")"
  [[ "$row" == api ]] \
    || fail "M7: AUTOMETTA_CLAUDE_MODE_WORKER=api did not beat the family env override (got '${row}')"
  row="$(AUTOMETTA_CLAUDE_MODE=subscription c173_route_of verifier "$claude")"
  [[ "$row" == subscription ]] \
    || fail "M7: the family env override did not beat the per-role manifest key (got '${row}')"
}

# --- L1: identities and paths render verbatim --------------------------------
c173_l1() {
  local base="$tmp/l1" stubs="$tmp/l1/bin" repo="$tmp/l1/repo" cwd="$tmp/l1/cwd"
  mkdir -p "$stubs" "$cwd"
  cat >"$stubs/op-fetch" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${C173_CAPTURE_DIR:-}" ]]; then
  model="" out="" previous=""
  for a in "$@"; do
    [[ "$previous" == "--model" ]] && model="$a"
    [[ "$previous" == "--out" ]] && out="$a"
    previous="$a"
  done
  case "$model" in *opus*) label=opus ;; *sonnet*) label=sonnet ;; *) label=codex ;; esac
  : >"$C173_CAPTURE_DIR/$label.argv"
  for a in "$@"; do printf '%s\n' "$a" >>"$C173_CAPTURE_DIR/$label.argv"; done
  if [[ -z "$out" ]]; then
    for a in "$@"; do
      case "$a" in *'Verifier artefact path:'*)
        out="$(printf '%s\n' "$a" | sed -n 's/.*Verifier artefact path: `\([^`]*\)`.*/\1/p')" ;;
      esac
    done
  fi
  if [[ -n "$out" ]]; then
    mkdir -p "$(dirname "$out")"
    printf '{"overall":"PASS","criteria":[],"additional_findings":""}\n' >"$out"
  fi
  exit 0
fi
: >"$C173_CAPTURE"
for a in "$@"; do printf '%s\n' "$a" >>"$C173_CAPTURE"; done
STUB
  chmod +x "$stubs/op-fetch"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "GPT-6.1 Sol R&D|x <gpt-6-1-sol@local>"\n' >"$stubs/agent-whoami"
  chmod +x "$stubs/agent-whoami"

  c173_card() {
    # c173_card <path> <worker> <verifier>
    mkdir -p "$(dirname "$1")"
    {
      printf '# Stage card\n\n## Metadata\n\n'
      printf -- '- **Worker:** %s\n' "$2"
      printf -- '- **Verifier:** %s\n' "$3"
      printf -- '- **Verifier panel:** false\n\n'
      printf '## Deliverables\n\n1. `scripts/example.sh`\n\n'
      printf '## Budget\n\n- **Worker wall-clock:** 1 minutes\n'
      printf -- '- **Verifier wall-clock:** 1 minutes\n'
    } >"$1"
  }
  c173_dispatch() {
    # c173_dispatch <spawn-script> <card>: prints the captured argv.
    local capture="$base/capture.txt" stage
    stage="$(basename "$2" .md)"
    rm -f "$capture"
    mkdir -p "$repo/state/logs" "$repo/state/verifiers"
    printf 'stages:\n  - id: %s\n    status: in_progress\n' "$stage" >"$repo/state/state.yaml"
    (
      cd "$cwd"
      export PATH="$stubs:$clean_path"
      export C173_CAPTURE="$capture"
      export AUTOMETTA_CLAUDE_MODE=subscription AUTOMETTA_CODEX_MODE=subscription
      export AUTOMETTA_CLAUDE_TRANSPORT=cli AUTOMETTA_CODEX_TRANSPORT=cli
      export AUTOMETTA_RESERVE_GATED=1 AUTOMETTA_IGNORE_RESERVE=1
      "$script_dir/$1" "$2" "$repo" >/dev/null 2>>"$base/spawn.log"
    ) || true
    local waited=0
    while [[ ! -s "$capture" && $waited -lt 100 ]]; do sleep 0.1; waited=$((waited + 1)); done
    cat "$capture" 2>/dev/null || true
  }

  local worker_id='Claude Opus 5.5 R&D\lab|w sedwrite <claude-opus-5-5@local>'
  local verifier_id='Claude Opus 5.5 Q&A\lab|w sedwrite <claude-opus-5-5@local>'
  local plain='Claude Opus 5.5 <claude-opus-5-5@local>'
  local card argv

  card="$repo/cards/50-hostile-identity.md"
  c173_card "$card" "$worker_id" "$verifier_id"
  argv="$(c173_dispatch spawn-worker.sh "$card")"
  grep -Fxq -- "- Worker: ${worker_id}" <<<"$argv" \
    || fail "L1: the worker prompt does not carry the card's Worker identity verbatim"
  argv="$(c173_dispatch spawn-verifier.sh "$card")"
  grep -Fxq -- "- Verifier: ${verifier_id}" <<<"$argv" \
    || fail "L1: the verifier prompt does not carry the card's Verifier identity verbatim"
  [[ -z "$(ls -A "$cwd")" ]] \
    || fail "L1: rendering a prompt wrote a file into the caller's directory: $(ls -A "$cwd" | head -n1)"

  repo="$tmp/l1/repo R&D|x\\y"
  card="$repo/cards/51-hostile-path.md"
  c173_card "$card" "$plain" "$plain"
  argv="$(c173_dispatch spawn-worker.sh "$card")"
  grep -Fxq -- "- Stage card: \`${card}\`" <<<"$argv" \
    || fail "L1: the worker prompt does not carry the card path verbatim"
  grep -Fxq -- "- Project: repo R&D|x\\y" <<<"$argv" \
    || fail "L1: the worker prompt does not carry the project name verbatim"
  grep -Fq -- "- Family-specific notes: Repository worktree: ${repo}. " <<<"$argv" \
    || fail "L1: the worker prompt's family notes do not carry the worktree path verbatim"
  argv="$(c173_dispatch spawn-verifier.sh "$card")"
  grep -Fxq -- "- Stage card: \`${card}\`" <<<"$argv" \
    || fail "L1: the verifier prompt does not carry the card path verbatim"

  local panel_dir="$base/panel"
  rm -rf "$panel_dir"
  mkdir -p "$panel_dir"
  (
    cd "$cwd"
    export PATH="$stubs:$clean_path"
    export C173_CAPTURE_DIR="$panel_dir"
    export AUTOMETTA_CODEX_MODE=subscription AUTOMETTA_CLAUDE_MODE=api
    export OP_REF_ANTHROPIC_API_KEY='op://smoke/item/key'
    "$script_dir/spawn-verifier-panel.sh" "$card" "$repo" --read-only >/dev/null 2>>"$base/spawn.log"
  ) || true
  grep -Fxq -- "- Stage card: \`${card}\`" "$panel_dir/codex.argv" 2>/dev/null \
    || fail "L1: the panel's codex prompt does not carry the card path verbatim"
  grep -Fxq -- "- Verifier: GPT-6.1 Sol R&D|x <gpt-6-1-sol@local>" "$panel_dir/codex.argv" 2>/dev/null \
    || fail "L1: the panel's codex prompt does not carry its codex identity verbatim"
  [[ -z "$(ls -A "$cwd")" ]] \
    || fail "L1: a dispatch wrote a file into the caller's directory: $(ls -A "$cwd" | head -n1)"
}

# --- L4: auth.sh reads auth_mode without building Python from the path -------
c173_l4() {
  local base="$tmp/l4" stubs="$tmp/l4/bin" cwd="$tmp/l4/cwd" out
  mkdir -p "$stubs" "$cwd" "$base/home"
  cat >"$stubs/op-fetch" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--print" ]] && { printf 'sk-smoke-0123456789\n'; exit 0; }
exit 0
STUB
  chmod +x "$stubs/op-fetch"
  printf 'OP_REF_OPENAI_API_KEY=op://smoke/openai/credential\n' >"$base/refs.local.sh"

  c173_auth() {
    # c173_auth <codex-home> <auth.sh args...>
    local codex_home="$1"; shift
    ( cd "$cwd"
      export PATH="$stubs:$clean_path" HOME="$base/home" XDG_CONFIG_HOME="$base/home/.config"
      export AUTOMETTA_LOCAL_REFS="$base/refs.local.sh" AUTOMETTA_CODEX_HOME="$codex_home"
      export AUTOMETTA_CODEX_MODE=api
      rc=0
      "$script_dir/auth.sh" "$@" 2>&1 || rc=$?
      printf 'rc=%s\n' "$rc" )
  }

  local quoted="$base/it's a home"
  mkdir -p "$quoted"
  printf '{"auth_mode":"apikey"}\n' >"$quoted/auth.json"
  out="$(c173_auth "$quoted" status)"
  grep -Fq "(auth_mode: apikey)" <<<"$out" \
    || fail "L4: auth status cannot read auth_mode from a CODEX_HOME whose path holds a quote"
  out="$(c173_auth "$quoted" check codex)"
  grep -q '^PASS .*codex' <<<"$out" && grep -qx 'rc=0' <<<"$out" \
    || fail "L4: auth check codex fails on a valid apikey sibling whose path holds a quote"

  local hostile="$base/x'*0+str(open('INJECTED','w').write('1'))+'"
  mkdir -p "$hostile"
  printf '{"auth_mode":"apikey"}\n' >"$hostile/auth.json"
  c173_auth "$hostile" status >/dev/null
  c173_auth "$hostile" check codex >/dev/null
  [[ ! -e "$cwd/INJECTED" && ! -e "$cwd/1" ]] \
    || fail "L4: AUTOMETTA_CODEX_HOME was executed as Python source"

  local chatgpt="$base/chatgpt home"
  mkdir -p "$chatgpt"
  printf '{"auth_mode":"chatgpt"}\n' >"$chatgpt/auth.json"
  out="$(c173_auth "$chatgpt" check codex)"
  grep -Fq 'auth_mode=chatgpt' <<<"$out" && ! grep -qx 'rc=0' <<<"$out" \
    || fail "L4: a chatgpt-mode sibling is no longer refused by name with a non-zero exit"
}

# --- L6: the awaiting push asks git-push-check first --------------------------
c173_l6() {
  local base="$tmp/l6" stubs="$tmp/l6/bin" repo="$tmp/l6/repo" origin="$tmp/l6/origin.git"
  local branch=autometta/07-awaiting out rc tip
  declare -F push_awaiting_run_branch >/dev/null \
    || fail "L6: tick.sh defines no push_awaiting_run_branch"

  # Every push the tick makes is this function's.
  local fn_start fn_end hits
  fn_start="$(grep -nE '^(function[[:space:]]+)?push_awaiting_run_branch[[:space:]]*(\(\))?[[:space:]]*\{' "$script_dir/tick.sh" | head -n1 | cut -d: -f1)"
  fn_end="$(awk -v s="$fn_start" 'NR > s && /^}/ { print NR; exit }' "$script_dir/tick.sh")"
  hits="$(grep -nE '^[^#]*(^|[;&|(]|\$\(|then|do|else)[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)' "$script_dir/tick.sh" \
    | cut -d: -f1 | awk -v s="$fn_start" -v e="$fn_end" '$1 < s || $1 > e')"
  [[ -n "$fn_start" && -n "$fn_end" && -z "$hits" ]] \
    || fail "L6: tick.sh pushes outside push_awaiting_run_branch (line ${hits%%$'\n'*})"
  [[ "$(grep -v '^[[:space:]]*#' "$script_dir/tick.sh" | grep -cE 'push_awaiting_run_branch([[:space:]]|$)')" -ge 1 ]] \
    || fail "L6: nothing in tick.sh calls push_awaiting_run_branch"

  mkdir -p "$stubs"
  cat >"$stubs/git-push-check" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"$C173_GPC_LOG"
printf '%b\n' "$C173_GPC_VERDICT"
STUB
  chmod +x "$stubs/git-push-check"
  git init -q --bare "$origin"
  c173_git_fixture "$repo"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" branch "$branch" dev
  tip="$(git -C "$repo" rev-parse "$branch")"

  c173_push() {
    # c173_push <verdict-or-MISSING>: prints rc then the function's output.
    local verdict="$1" path_for="$stubs:$clean_path" o r=0
    [[ "$verdict" == MISSING ]] && path_for="$clean_path"
    o="$(PATH="$path_for" C173_GPC_LOG="$base/gpc.log" C173_GPC_VERDICT="$verdict" \
      push_awaiting_run_branch "$repo" "$branch" 2>/dev/null)" || r=$?
    printf '%s\n%s\n' "$r" "$o"
  }
  c173_on_origin() { git -C "$origin" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true; }

  local verdict
  for verdict in 'ASK\tpublic GitHub remote' 'HOLD\tpublish branch' 'NOOP\tnothing to send' \
                 '' 'MAYBE\tunrecognised' 'PUSH\torigin x\nASK\tlast line wins' MISSING; do
    : >"$base/gpc.log"
    out="$(c173_push "$verdict")"
    rc="$(head -n1 <<<"$out")"
    [[ "$rc" != 0 && "$(sed -n 2p <<<"$out")" == held:* ]] \
      || fail "L6: verdict '${verdict%%\\t*}' did not hold the push (rc=${rc}, output '$(sed -n 2p <<<"$out")')"
    [[ -z "$(c173_on_origin)" ]] \
      || fail "L6: verdict '${verdict%%\\t*}' still pushed ${branch} to origin"
  done
  [[ "$(sed -n 2p <<<"$out")" == *git-push-check* ]] \
    || fail "L6: a missing git-push-check is not named in the held reason"

  git -C "$repo" remote set-url origin "$base/no-such-origin.git"
  out="$(c173_push 'PUSH\torigin autometta/07-awaiting')"
  [[ "$(head -n1 <<<"$out")" != 0 && "$(sed -n 2p <<<"$out")" == held:* ]] \
    || fail "L6: a failed push after verdict PUSH did not report held (output '$(tr '\n' ' ' <<<"$out")')"
  git -C "$repo" remote set-url origin "$origin"

  : >"$base/gpc.log"
  out="$(c173_push 'note: checking\nPUSH\torigin autometta/07-awaiting')"
  [[ "$(head -n1 <<<"$out")" == 0 && "$(sed -n 2p <<<"$out")" == pushed ]] \
    || fail "L6: verdict PUSH did not push (output '$(tr '\n' ' ' <<<"$out")')"
  [[ "$(c173_on_origin)" == "$tip" ]] \
    || fail "L6: verdict PUSH left origin without ${branch} at ${tip}"
  [[ "$(cat "$base/gpc.log")" == "${repo}|origin ${branch}" ]] \
    || fail "L6: git-push-check was not asked about 'origin ${branch}' from the repo root (got '$(cat "$base/gpc.log")')"
}

# --- identity: the tick's snapshot commits are authored as the loop ----------
c173_identity() {
  local base="$tmp/identity" stubs="$tmp/identity/bin" repo="$tmp/identity/repo" got
  mkdir -p "$stubs"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >>"%s"\nprintf "GPT-6.1 Sol <gpt-6-1-sol@local>\\n"\n' "$base/whoami.log" >"$stubs/agent-whoami"
  chmod +x "$stubs/agent-whoami"
  c173_git_fixture "$repo"
  mkdir -p "$repo/state"
  printf 'version: 1\ncurrent_stage: null\nstages: []\n' >"$repo/state/state.yaml"
  PATH="$stubs:$clean_path" AGENT_WHOAMI='GPT-6.1 Sol <gpt-6-1-sol@local>' \
    commit_state_branch "$repo" 2>/dev/null
  got="$(git -C "$repo" log -1 --format='%an <%ae>' refs/heads/autometta/state 2>/dev/null || true)"
  [[ "$got" == 'Phat Controller <phat-controller@local>' ]] \
    || fail "identity: the tick state update was authored as '${got}', not the loop's identity"
  got="$(git -C "$repo" log -1 --format='%cn <%ce>|%s' refs/heads/autometta/state 2>/dev/null || true)"
  [[ "$got" == 'smoke <smoke@local>|autometta: tick state update' ]] \
    || fail "identity: committer or subject of the snapshot changed (got '${got}')"
  [[ ! -s "$base/whoami.log" ]] \
    || fail "identity: commit_state_branch still asks agent-whoami for an author"
}

for group in c173_m6 c173_m7 c173_l1 c173_l4 c173_l6 c173_identity; do
  ( "$group" ) || failed_groups=$((failed_groups + 1))
done
[[ "$failed_groups" -eq 0 ]] || exit 1
# AUTOMETTA-CONTRACT-END

printf 'small-dispatch-fixes-smoke: PASS\n' >&2
