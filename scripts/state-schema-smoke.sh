#!/usr/bin/env bash
# state-schema-smoke.sh — proves schemas/state.yaml.json both accepts and
# rejects.
#
# The defect this guards (card 102): state/state.yaml failed
# schemas/state.yaml.json with 69 errors, every one "additional properties
# not allowed" for fields tick.sh has always written (tokens, worker_tokens,
# verifier_tokens, verifier_started_at, notes, integrated_at, note). A
# validator that always fails on the healthy file cannot be run in anger, so
# nothing ran it, so a genuine corruption would have looked identical to the
# 69 pre-existing errors. This script is the thing that would have caught
# that: it asserts both directions, not just that the real files pass.
#
#   1. This repo's live state/state.yaml validates with zero errors.
#   2. emergence-lab's state/state.yaml validates with zero errors, if that
#      checkout is present on this machine (subscriber shape must fit too).
#   3. A misspelled field (verifer_tokens) is rejected.
#   4. A wrong-typed field (tokens: "many") is rejected.
#   5. A stage missing its id is rejected.
#   6. additionalProperties: false still holds at the top level, the stage
#      level, and inside integration.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
schema_path="${1:-$repo_root/schemas/state.yaml.json}"

fail=0

check() {
  local desc="$1"
  local cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2
    fail=1
  fi
}

# validate_file: exit 0 if $2 (a state.yaml) validates clean against $1 (a
# schema), else prints the error count/messages and exits 1.
validate_file() {
  local schema="$1"
  local state_file="$2"
  python3 - "$schema" "$state_file" <<'PY'
import sys, json
import yaml
import jsonschema

schema_path, state_path = sys.argv[1], sys.argv[2]
schema = json.load(open(schema_path))
data = yaml.safe_load(open(state_path))
validator = jsonschema.Draft202012Validator(schema)
errors = list(validator.iter_errors(data))
if errors:
    print(f"{len(errors)} errors", file=sys.stderr)
    for e in errors[:10]:
        print(f"  {list(e.path)}: {e.message}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}

# validate_doc: like validate_file, but the fixture is a YAML document
# passed on stdin rather than a path. Spools stdin to a temp file first --
# the python script itself must come from a heredoc on the same stdin, so
# the two cannot share it directly. Exits 0 valid, 1 invalid.
validate_doc() {
  local schema="$1"
  local tmp_fixture
  tmp_fixture="$(mktemp)"
  cat > "$tmp_fixture"
  local rc=0
  validate_file "$schema" "$tmp_fixture" >/dev/null 2>&1 || rc=1
  rm -f "$tmp_fixture"
  return "$rc"
}

base_doc() {
  cat <<'YAML'
version: 1
current_stage: null
stages:
YAML
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/102-the-state-schema-describes-the-state.md
# 1. This repo's own state file.
if validate_file "$schema_path" "$repo_root/state/state.yaml" 2>/tmp/state-schema-smoke.$$; then
  check "repo state/state.yaml validates clean" ok
else
  check "repo state/state.yaml validates clean" "$(cat /tmp/state-schema-smoke.$$)"
fi
rm -f /tmp/state-schema-smoke.$$

# 2. emergence-lab's state file, if this machine has that checkout.
el_state="$HOME/repos/emergence-lab/state/state.yaml"
if [[ -f "$el_state" ]]; then
  if validate_file "$schema_path" "$el_state" 2>/tmp/state-schema-smoke.$$; then
    check "emergence-lab state/state.yaml validates clean" ok
  else
    check "emergence-lab state/state.yaml validates clean" "$(cat /tmp/state-schema-smoke.$$)"
  fi
  rm -f /tmp/state-schema-smoke.$$
else
  printf '  SKIP: emergence-lab checkout not found at %s\n' "$el_state" >&2
fi

# 3. A healthy minimal fixture passes.
healthy_fixture() {
  base_doc
  cat <<'YAML'
  - id: 01-a-healthy-stage
    status: completed
    worker: Claude Sonnet 5 <claude-sonnet-5@local>
    verifier: Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
    started_at: "2026-09-01T09:00:00Z"
    completed_at: "2026-09-01T09:30:00Z"
    worker_tokens: 1234
    verifier_tokens: 567
    tokens: 1801
    verifier_started_at: "2026-09-01T09:15:00Z"
    notes: orchestrator-adjudicated PASS
    commit: 0123abc
    integration:
      state: merged
      base_branch: dev
      run_branch: autometta/01-a-healthy-stage
      head: 0123abc
      pushed: null
      recorded_at: "2026-09-01T09:30:00Z"
      integrated_at: "2026-09-01T09:31:00Z"
      note: rebased onto dev by the orchestrator
last_tick_at: "2026-09-01T09:30:00Z"
tick_count: 1
clock_tick_budget_remaining: 100
YAML
}
if healthy_fixture | validate_doc "$schema_path"; then
  check "healthy fixture (with the new fields) validates clean" ok
else
  check "healthy fixture (with the new fields) validates clean" "unexpectedly rejected"
fi

# 4. A misspelled field is rejected.
misspelled_fixture() {
  base_doc
  cat <<'YAML'
  - id: 02-a-misspelled-field
    status: completed
    worker: Claude Sonnet 5 <claude-sonnet-5@local>
    verifier: Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
    verifer_tokens: 999
last_tick_at: "2026-09-01T09:30:00Z"
tick_count: 1
clock_tick_budget_remaining: 100
YAML
}
if misspelled_fixture | validate_doc "$schema_path"; then
  check "misspelled field (verifer_tokens) is rejected" "was accepted"
else
  check "misspelled field (verifer_tokens) is rejected" ok
fi

# 5. A wrong-typed field is rejected.
wrong_type_fixture() {
  base_doc
  cat <<'YAML'
  - id: 03-a-wrong-typed-field
    status: completed
    worker: Claude Sonnet 5 <claude-sonnet-5@local>
    verifier: Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
    tokens: "many"
last_tick_at: "2026-09-01T09:30:00Z"
tick_count: 1
clock_tick_budget_remaining: 100
YAML
}
if wrong_type_fixture | validate_doc "$schema_path"; then
  check "wrong-typed field (tokens: \"many\") is rejected" "was accepted"
else
  check "wrong-typed field (tokens: \"many\") is rejected" ok
fi

# 6. A stage missing its id is rejected.
missing_id_fixture() {
  base_doc
  cat <<'YAML'
  - status: completed
    worker: Claude Sonnet 5 <claude-sonnet-5@local>
    verifier: Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
last_tick_at: "2026-09-01T09:30:00Z"
tick_count: 1
clock_tick_budget_remaining: 100
YAML
}
if missing_id_fixture | validate_doc "$schema_path"; then
  check "stage missing its id is rejected" "was accepted"
else
  check "stage missing its id is rejected" ok
fi

# 7. additionalProperties: false still holds at every level: top-level, the
# stage level, and inside integration.
top_level_extra_fixture() {
  base_doc
  cat <<'YAML'
last_tick_at: "2026-09-01T09:30:00Z"
tick_count: 1
clock_tick_budget_remaining: 100
made_up_top_level_field: true
YAML
}
if top_level_extra_fixture | validate_doc "$schema_path"; then
  check "additionalProperties: false holds at the top level" "was accepted"
else
  check "additionalProperties: false holds at the top level" ok
fi

stage_extra_fixture() {
  base_doc
  cat <<'YAML'
  - id: 04-a-stage-level-extra
    status: completed
    worker: Claude Sonnet 5 <claude-sonnet-5@local>
    verifier: Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
    made_up_stage_field: true
last_tick_at: "2026-09-01T09:30:00Z"
tick_count: 1
clock_tick_budget_remaining: 100
YAML
}
if stage_extra_fixture | validate_doc "$schema_path"; then
  check "additionalProperties: false holds at the stage level" "was accepted"
else
  check "additionalProperties: false holds at the stage level" ok
fi

integration_extra_fixture() {
  base_doc
  cat <<'YAML'
  - id: 05-an-integration-level-extra
    status: completed
    worker: Claude Sonnet 5 <claude-sonnet-5@local>
    verifier: Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
    integration:
      state: merged
      made_up_integration_field: true
last_tick_at: "2026-09-01T09:30:00Z"
tick_count: 1
clock_tick_budget_remaining: 100
YAML
}
if integration_extra_fixture | validate_doc "$schema_path"; then
  check "additionalProperties: false holds inside integration" "was accepted"
else
  check "additionalProperties: false holds inside integration" ok
fi
# AUTOMETTA-CONTRACT-END

if (( fail )); then
  printf 'state-schema-smoke: FAIL\n' >&2
  exit 1
fi
printf 'state-schema-smoke: PASS\n' >&2
exit 0
