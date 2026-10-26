#!/usr/bin/env bash
# session-start-escalations-smoke.sh: pending escalations reach a Claude Code
# session through a SessionStart hook, and the installer adds that hook
# without disturbing anything else in the settings file (card 160).
#
# Runs against temporary escalation folders, subscriber registries and
# settings files only; the real user settings are never read or written.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: 160-an-orchestration-chat-sees-escalations: %s\n' "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/160-an-orchestration-chat-sees-escalations.md
hook="$script_dir/hooks/session-start-escalations.sh"
installer="$script_dir/install-escalation-hook.sh"
[[ -x "$hook" ]] || fail "scripts/hooks/session-start-escalations.sh is missing or not executable"
[[ -x "$installer" ]] || fail "scripts/install-escalation-hook.sh is missing or not executable"

export AUTOMETTA_HOME="$tmp/home"
export AUTOMETTA_ESCALATIONS="$tmp/escalations"
unset CLAUDE_PROJECT_DIR
pending="$AUTOMETTA_ESCALATIONS/pending"
mkdir -p "$AUTOMETTA_HOME/subscribers" "$pending"

repo_a="$tmp/alpha-repo"
repo_b="$tmp/beta-repo"
outside="$tmp/elsewhere"
mkdir -p "$repo_a/src/deep" "$repo_b" "$outside"
printf 'repo_path: "%s"\nweight: 10\nenabled: true\n' "$repo_a" > "$AUTOMETTA_HOME/subscribers/alpha.yaml"
printf 'repo_path: "%s"\nweight: 20\nenabled: true\n' "$repo_b" > "$AUTOMETTA_HOME/subscribers/beta.yaml"

write_escalation() {
  local stamp="$1" repo="$2" stage="$3" kind="$4" summary="$5"
  local path
  path="$pending/${stamp}-$(basename "$repo")-${stage:-run}-${kind}.md"
  printf -- '---\nrepo: "%s"\nstage: "%s"\nkind: "%s"\ncreated: "2026-10-23T10:00:00Z"\n---\n\n%s\nsecond body line\n' \
    "$repo" "$stage" "$kind" "$summary" > "$path"
  printf '%s\n' "$path"
}

run_hook() {
  local dir="$1"
  (cd "$dir" && "$hook" </dev/null)
}

out="$(run_hook "$outside")" || fail "the hook exited non-zero with no escalations"
[[ -z "$out" ]] || fail "the hook printed output with no escalations"

one="$(write_escalation 20261023T100000Z "$repo_a" 07-thing failed 'SUMMARY-ONE frozen contract contradicts criterion 2')"
out="$(run_hook "$outside")" || fail "the hook exited non-zero with one escalation"
[[ -n "$out" ]] || fail "the hook printed nothing with one escalation"
printf '%s\n' "$out" | grep -q '1' || fail "the hook did not print the count"
line="$(printf '%s\n' "$out" | grep -F "$one" || true)"
[[ -n "$line" ]] || fail "no line names the escalation file path"
[[ "$line" == *alpha-repo* ]] || fail "the escalation line lacks the repo"
[[ "$line" == *07-thing* ]] || fail "the escalation line lacks the stage"
[[ "$line" == *failed* ]] || fail "the escalation line lacks the kind"
[[ "$line" == *SUMMARY-ONE* ]] || fail "the escalation line lacks the first summary line"
[[ "$line" == *20261023T100000Z* ]] || fail "the escalation line lacks the stamp"
[[ "$out" != *'second body line'* ]] || fail "the hook printed more than the first summary line"
printf '%s\n' "$out" | grep -q 'escalations.sh list' || fail "the hook does not name escalations.sh list"
printf '%s\n' "$out" | grep -q 'autometta-escalations' || fail "the hook does not name the autometta-escalations skill"

out_json="$(cd "$outside" && printf '{"session_id":"x","cwd":"%s","hook_event_name":"SessionStart"}\n' "$outside" | "$hook")" \
  || fail "the hook exited non-zero with session JSON on stdin"
[[ "$out_json" == *SUMMARY-ONE* ]] || fail "the hook output differs when Claude Code passes JSON on stdin"

for i in 01 02 03 04 05 06 07 08 09 10 11; do
  write_escalation "20261023T1100${i}Z" "$repo_b" "2${i}-more" stalled "SUMMARY-B${i}" >/dev/null
done
out="$(run_hook "$outside")" || fail "the hook exited non-zero with twelve escalations"
[[ "$(printf '%s\n' "$out" | grep -c "$pending/")" == "10" ]] || fail "twelve escalations did not show exactly 10 lines"
printf '%s\n' "$out" | grep -q '+2 more' || fail "twelve escalations did not print +2 more"
[[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -lt 15 ]] || fail "hook output is 15 lines or more"
first_line="$(printf '%s\n' "$out" | grep "$pending/" | head -1)"
[[ "$first_line" == *SUMMARY-ONE* ]] || fail "escalations are not listed oldest first"
printf '%s\n' "$out" | grep -q '12' || fail "the count does not say 12"

out="$(run_hook "$repo_a/src/deep")" || fail "the hook exited non-zero inside a subscriber"
[[ "$out" == *SUMMARY-ONE* ]] || fail "inside alpha-repo the hook hid alpha's escalation"
[[ "$out" != *SUMMARY-B* ]] || fail "inside alpha-repo the hook showed beta's escalations"
out="$(cd "$outside" && CLAUDE_PROJECT_DIR="$repo_b" "$hook" </dev/null)" || fail "the hook exited non-zero with CLAUDE_PROJECT_DIR"
[[ "$out" == *SUMMARY-B01* && "$out" != *SUMMARY-ONE* ]] || fail "CLAUDE_PROJECT_DIR does not select the subscriber filter"

printf 'garbage with no frontmatter\n' > "$pending/20261023T120000Z-junk.md"
err="$( (cd "$outside" && "$hook" </dev/null >/dev/null) 2>&1)" || fail "an unparseable escalation made the hook exit non-zero"
[[ -z "$err" ]] || fail "an unparseable escalation made the hook write to stderr"

printf 'not a folder\n' > "$tmp/blocked"
out="$(cd "$outside" && AUTOMETTA_ESCALATIONS="$tmp/blocked" "$hook" </dev/null 2>&1)" \
  || fail "a broken escalations folder made the hook exit non-zero"
[[ -z "$out" ]] || fail "a broken escalations folder printed output"
out="$(cd "$outside" && AUTOMETTA_ESCALATIONS="$tmp/absent" "$hook" </dev/null 2>&1)" \
  || fail "a missing escalations folder made the hook exit non-zero"
[[ -z "$out" ]] || fail "a missing escalations folder printed output"

rm -f "$pending"/*.md
for i in $(seq -w 1 100); do
  write_escalation "20261023T13${i: -2}00Z" "$repo_a" "x${i}" failed "BULK-${i}" >/dev/null
done
best=99
for _ in 1 2 3; do
  elapsed="$(python3 -c 'import subprocess,sys,time; t=time.time(); subprocess.run([sys.argv[1]], cwd=sys.argv[2], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL); print(time.time()-t)' "$hook" "$outside")"
  best="$(python3 -c 'import sys; print(min(float(sys.argv[1]), float(sys.argv[2])))' "$best" "$elapsed")"
done
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)' "$best" \
  || fail "the hook took ${best}s on 100 escalations, limit 1s"

hook_count() {
  jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("hooks/session-start-escalations.sh"))] | length' "$1"
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

fresh="$tmp/fresh/settings.json"
mkdir -p "$(dirname "$fresh")"
if "$installer" --check --settings "$fresh" >/dev/null 2>&1; then
  fail "--check on an absent settings file exited 0"
fi
[[ ! -e "$fresh" ]] || fail "--check created the settings file"
"$installer" --settings "$fresh" >/dev/null || fail "installing into a fresh settings file failed"
jq -e . "$fresh" >/dev/null || fail "the fresh settings file is not JSON"
[[ "$(hook_count "$fresh")" == "1" ]] || fail "the fresh settings file does not carry the hook exactly once"
check_out="$("$installer" --check --settings "$fresh")" || fail "--check on an installed hook exited non-zero"
printf '%s\n' "$check_out" | grep -qi 'installed' || fail "--check on an installed hook does not say installed"

existing="$tmp/existing/settings.json"
mkdir -p "$(dirname "$existing")"
cat > "$existing" <<'JSON'
{
  "model": "keep-this-model",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "other-start-hook --keep"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "other-stop-hook"}]}]
  }
}
JSON
original_sha="$(sha "$existing")"
check_out="$("$installer" --check --settings "$existing" 2>&1)" && fail "--check on a settings file without the hook exited 0"
printf '%s\n' "$check_out" | grep -qi 'missing' || fail "--check without the hook does not say missing"
[[ "$(sha "$existing")" == "$original_sha" ]] || fail "--check changed the settings file"
"$installer" --settings "$existing" >/dev/null || fail "installing into an existing settings file failed"
[[ "$(hook_count "$existing")" == "1" ]] || fail "the existing settings file does not carry the hook exactly once"
[[ "$(jq -r .model "$existing")" == "keep-this-model" ]] || fail "the installer lost the model key"
[[ "$(jq -r '.permissions.allow[0]' "$existing")" == "Bash(ls:*)" ]] || fail "the installer lost the permissions"
jq -e '[.hooks.SessionStart[].hooks[].command] | index("other-start-hook --keep")' "$existing" >/dev/null \
  || fail "the installer lost an existing SessionStart hook"
[[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$existing")" == "other-stop-hook" ]] || fail "the installer lost the Stop hook"
backups="$(find "$(dirname "$existing")" -name 'settings.json.bak-*' | wc -l | tr -d ' ')"
[[ "$backups" == "1" ]] || fail "installing did not leave exactly one settings.json.bak-<stamp> backup (found $backups)"
backup="$(find "$(dirname "$existing")" -name 'settings.json.bak-*')"
[[ "$(sha "$backup")" == "$original_sha" ]] || fail "the backup is not the original settings file"
installed_sha="$(sha "$existing")"
sleep 1
"$installer" --settings "$existing" >/dev/null || fail "a second install failed"
[[ "$(hook_count "$existing")" == "1" ]] || fail "a second install duplicated the hook"
[[ "$(sha "$existing")" == "$installed_sha" ]] || fail "a second install changed the settings file"
[[ "$(find "$(dirname "$existing")" -name 'settings.json.bak-*' | wc -l | tr -d ' ')" == "1" ]] \
  || fail "a second install with nothing to change wrote another backup"

grep -Eq 'install-escalation-hook\.sh.*--check|--check.*install-escalation-hook\.sh' "$script_dir/init-host.sh" \
  || fail "init-host.sh does not call install-escalation-hook.sh --check"

skill="$repo_dir/skills/autometta-escalations/SKILL.md"
[[ -s "$skill" ]] || fail "skills/autometta-escalations/SKILL.md is missing"
awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$skill" \
  | grep -Eq '^name: "?autometta-escalations"?$' || fail "the skill frontmatter does not name autometta-escalations"
for needle in autometta-oracle autometta-requeue autometta-card-review 'escalations.sh list' ack preserve; do
  grep -q -- "$needle" "$skill" || fail "the skill does not mention $needle"
done
pc_skill="$repo_dir/skills/phat-controller/SKILL.md"
grep -q 'autometta-escalations' "$pc_skill" || fail "the phat-controller skill does not point at autometta-escalations"
[[ "$(wc -l < "$pc_skill" | tr -d ' ')" -lt 40 ]] || fail "the phat-controller skill is not reduced to a pointer (40 lines or more)"
grep -q 'session-start-escalations' "$repo_dir/docs/tick-loop.md" || fail "docs/tick-loop.md does not describe the hook"
grep -q 'autometta-escalations' "$repo_dir/docs/tick-loop.md" || fail "docs/tick-loop.md does not name the skill"
# AUTOMETTA-CONTRACT-END

printf 'session-start-escalations-smoke: PASS\n'
