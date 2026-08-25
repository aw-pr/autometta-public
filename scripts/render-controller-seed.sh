#!/usr/bin/env bash
# scripts/render-controller-seed.sh -- render phat-controller's context seed
# when a job is configured.
#
# The seed is the persona, the mandate, the negative list, the spend authority
# and the repo facts an orchestrator would otherwise rediscover, in that
# order. It is rendered at configure time rather than on first run for one
# reason: it carries an answer only the operator can give.
#
# **This script never chooses a spend authority.** The right level varies by
# run, by hour and by day, so a committed default would be wrong most of the
# time it was used, and wrong in the expensive direction. With no
# --spend-authority supplied it prints what it needs and exits 2 without
# writing anything.
#
# Usage:
#   render-controller-seed.sh --spend-authority '<prose>' \
#     --window-reserve-percent N --window-reserve-action hold|observe [options]
#
# Options:
#   --spend-authority TEXT   what this job may spend, in the operator's own
#                            words. Required.
#   --spend-authority-file F read the same text from a file, or - for stdin.
#   --token-ceiling N        machine-readable hard stop, mirrored into the
#                            mandate manifest so a pass can halt without
#                            parsing prose.
#   --expires ISO8601        machine-readable expiry, mirrored the same way.
#   --window-reserve-percent N
#                            percentage of each provider window to leave
#                            unspent. Required; zero explicitly turns it off.
#   --window-reserve-action A
#                            hold or observe. Required.
#   --repo PATH              describe only this repo. Repeatable. Default is
#                            every enabled subscriber.
#   --out PATH               where to write. Default
#                            $AUTOMETTA_HOME/phat-controller-seed.md.
#   --force                  overwrite an existing seed. Without it an
#                            existing seed is left alone, because the
#                            operator may have edited it.
#   --print                  write to stdout instead of to a file.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# shellcheck source=subscribers.sh
. "$script_dir/subscribers.sh"

autometta_root="$(autometta_self_root "$script_dir")"
controller_home="$(autometta_controller_home)"
seed_template="$autometta_root/templates/phat-controller-seed.md.tpl"
proposal="$autometta_root/docs/proposals/orchestrator-role-review.md"
mandate_template="$autometta_root/templates/phat-controller-mandate.yaml.tpl"
mandate_path="${AUTOMETTA_CONTROLLER_MANDATE:-$controller_home/phat-controller-mandate.yaml}"
out_path="${AUTOMETTA_CONTROLLER_SEED:-$controller_home/phat-controller-seed.md}"

spend_authority=""
token_ceiling=""
expires_at=""
window_reserve_percent=""
window_reserve_action=""
force=false
to_stdout=false
repos=()

die() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spend-authority) shift; [[ $# -gt 0 ]] || die "--spend-authority needs a value"; spend_authority="$1" ;;
    --spend-authority-file)
      shift; [[ $# -gt 0 ]] || die "--spend-authority-file needs a path"
      if [[ "$1" == "-" ]]; then spend_authority="$(cat)"; else spend_authority="$(cat "$1")"; fi ;;
    --token-ceiling) shift; [[ $# -gt 0 ]] || die "--token-ceiling needs a value"; token_ceiling="$1" ;;
    --expires) shift; [[ $# -gt 0 ]] || die "--expires needs a value"; expires_at="$1" ;;
    --window-reserve-percent) shift; [[ $# -gt 0 ]] || die "--window-reserve-percent needs a value"; window_reserve_percent="$1" ;;
    --window-reserve-action) shift; [[ $# -gt 0 ]] || die "--window-reserve-action needs a value"; window_reserve_action="$1" ;;
    --repo) shift; [[ $# -gt 0 ]] || die "--repo needs a path"; repos+=( "$(cd "$1" && pwd)" ) ;;
    --out) shift; [[ $# -gt 0 ]] || die "--out needs a path"; out_path="$1" ;;
    --force) force=true ;;
    --print) to_stdout=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ -f "$seed_template" ]] || die "MISSING seed template $seed_template"

# The refusal. Exit 2, nothing written, and say plainly why there is no
# default rather than inventing one that would be wrong most nights.
if [[ -z "${spend_authority// }" ]]; then
  cat >&2 <<'REFUSED'
phat-controller: no spend authority supplied, so no seed was rendered.

The seed carries what this job may spend, and there is no committed default
for it: the right level varies by run, by hour and by day, and a default
would be wrong most of the time it was used. Nothing has been written.

Answer it and re-run, for example:

  render-controller-seed.sh \
    --spend-authority 'Up to 40M tokens overnight on the Claude subscription. Codex api route is off tonight.' \
    --token-ceiling 40000000 \
    --expires 2026-08-25T07:00:00Z

--spend-authority-file <path> and --spend-authority-file - read the same
answer from a file or from stdin, for a setup flow that has already asked.
REFUSED
  exit 2
fi

if [[ -z "$window_reserve_percent" || -z "$window_reserve_action" ]]; then
  cat >&2 <<'REFUSED'
phat-controller: no provider-window reserve answer was supplied, so no seed
was rendered. Nothing has been written.

Answer how much of a provider window to leave unspent and what to do at that
point. Use --window-reserve-percent N (zero means off) together with
--window-reserve-action hold|observe. There is no committed default.
REFUSED
  exit 2
fi

if [[ -n "$token_ceiling" && ! "$token_ceiling" =~ ^[0-9]+$ ]]; then
  die "--token-ceiling must be a whole number of tokens, got: $token_ceiling"
fi
if [[ -n "$expires_at" && ! "$expires_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  die "--expires must be UTC ISO8601 like 2026-08-25T07:00:00Z, got: $expires_at"
fi
if ! [[ "$window_reserve_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] \
   || ! awk -v value="$window_reserve_percent" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
  die "--window-reserve-percent must be between 0 and 100, got: $window_reserve_percent"
fi
case "$window_reserve_action" in
  hold|observe) ;;
  *) die "--window-reserve-action must be hold or observe, got: $window_reserve_action" ;;
esac

if [[ "$to_stdout" == false && -f "$out_path" && "$force" == false ]]; then
  die "a seed already exists at $out_path and may have been edited; pass --force to replace it"
fi

# --- The negative list must not drift ---------------------------------------
#
# docs/proposals/orchestrator-role-review.md owns the five prohibitions. The
# seed template carries them verbatim so a rendered seed is self-contained on
# a machine without the docs. Two copies is one copy too many unless something
# checks them, so this does.
extract_block() {
  awk -v start="$2" -v stop="$3" '
    $0 ~ start { inblock = 1; next }
    inblock && $0 ~ stop { inblock = 0 }
    inblock { print }
  ' "$1" | sed -E 's/[[:space:]]+$//' | grep -v '^$' || true
}

if [[ -f "$proposal" ]]; then
  proposal_list="$(extract_block "$proposal" '^Forbidden, without exception:' '^Everything else the role can reach')"
  template_list="$(extract_block "$seed_template" '^Forbidden, without exception:' '^That list is exhaustive')"
  if [[ "$proposal_list" != "$template_list" ]]; then
    printf 'phat-controller: the negative list in %s has drifted from %s.\n' \
      "$seed_template" "$proposal" >&2
    diff <(printf '%s\n' "$proposal_list") <(printf '%s\n' "$template_list") >&2 || true
    die "refusing to render a seed whose prohibitions do not match the proposal that owns them"
  fi
fi

# --- Repo facts --------------------------------------------------------------

if [[ ${#repos[@]} -eq 0 ]]; then
  while IFS= read -r subscriber_file; do
    [[ -n "$subscriber_file" ]] || continue
    [[ "$(read_subscriber_field "$subscriber_file" enabled)" == "true" ]] || continue
    repo_path="$(read_subscriber_field "$subscriber_file" repo_path)"
    [[ -n "$repo_path" && -d "$repo_path" ]] || continue
    repos+=( "$repo_path" )
  done < <(sort_subscribers)
fi

branch_policy_for() {
  local repo="$1" style
  style="$(git -C "$repo" config --get workflow.style 2>/dev/null || true)"
  [[ -n "$style" ]] || style="dev-main (unset, so the safe default: do not commit on the trunk)"
  printf '%s' "$style"
}

facts="Autometta itself is at \`$autometta_root\`. The controller home, which
holds the subscriber registry (\`$controller_home/subscribers/\`), the mandate,
this seed and the pass logs, is at \`$controller_home\`. Read the registry at
the start of every pass rather than assuming the list below is still current.

Every subscribed repo keeps its own runtime state under \`<repo>/state/\`:

- \`state/state.yaml\`: the queue.
- \`state/budget.json\`: the hard stops, and the \`halted\` flag every
  renderer reads.
- \`state/phat-controller-journal.jsonl\`: your decision journal.
- \`state/phat-controller-state.json\`: how many times you have already tried
  something against a given stage.
- \`state/phat-controller-transcripts/\`: one recorded transcript per pass,
  indexed so a decision resolves back to the pass that made it
  (\`phat-controller.sh transcript-for-decision\`). Pruned every pass.
- \`state/phat-controller-inbox/pending/\`: messages waiting for you, read at
  the start of every pass before anything is decided. Answer every one with
  \`inbox-reply\` or \`inbox-refuse\`; \`state/phat-controller-outbox/\` is
  where the reply goes, readable without attaching to any session.
- \`state/verifiers/\` and \`state/handoffs/\`: the artefacts.
- \`state/logs/\`: dispatch logs.

All of it is gitignored. A run worktree's \`state/\` is a symlink back at the
repo's own, made by \`ensure_run_worktree\` in \`scripts/tick.sh\`; it is not
the worker's doing and it is not yours to correct.
"
if [[ ${#repos[@]} -eq 0 ]]; then
  facts="$facts
No subscriber repos are registered on this machine yet."
else
  for repo_path in "${repos[@]}"; do
    codex_mode="$(REPO_ROOT="$repo_path" "$script_dir/auth-route.sh" codex --print-mode 2>/dev/null || printf 'unresolved')"
    claude_mode="$(REPO_ROOT="$repo_path" "$script_dir/auth-route.sh" claude --print-mode 2>/dev/null || printf 'unresolved')"
    default_branch="$(git -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'unknown')"
    card_globs="$(yq -r '.stage_card_globs[]?' "$repo_path/.autometta.local.yaml" 2>/dev/null | paste -sd ', ' - || true)"
    [[ -n "$card_globs" ]] || card_globs="docs/stages/*.md (the default)"
    facts="$facts
### \`$repo_path\`

- Branch policy: \`$(branch_policy_for "$repo_path")\`. Checked out on \`$default_branch\` at render time.
- Auth routes: codex \`$codex_mode\`, claude \`$claude_mode\`. Never silently substitute one family for the other, and never move a dispatch onto a metered route to get past a spent subscription.
- Stage cards: $card_globs
"
  done
fi

# --- Gotchas -----------------------------------------------------------------
#
# The repo's own hard-won invariants, lifted from its agent brief rather than
# restated here, so this seed cannot be the copy that goes stale.

gotchas=""
for brief in "$autometta_root/CLAUDE.md" "$autometta_root/AGENTS.md"; do
  [[ -f "$brief" ]] || continue
  gotchas="$(awk '
    /^## Headless gotchas/ { inblock = 1; next }
    inblock && /^## / { inblock = 0 }
    inblock { print }
  ' "$brief")"
  [[ -n "${gotchas// }" ]] && break
done
if [[ -z "${gotchas// }" ]]; then
  gotchas="None recorded in this checkout's agent brief. Read
\`$autometta_root/docs/lessons.md\` before assuming a headless dispatch will
behave the way an interactive one does."
else
  gotchas="Lifted from \`$autometta_root/CLAUDE.md\` at render time. That file
owns them; if this copy and that one disagree, that one is right.
$gotchas"
fi

# --- Spend bounds ------------------------------------------------------------

spend_bounds=""
if [[ -n "$token_ceiling" || -n "$expires_at" ]]; then
  spend_bounds="
Mechanically, and recorded in the mandate manifest so a pass can stop without
reading this paragraph:"
  [[ -n "$token_ceiling" ]] && spend_bounds="$spend_bounds
- a ceiling of $token_ceiling tokens"
  [[ -n "$expires_at" ]] && spend_bounds="$spend_bounds
- authority expires at $expires_at"
else
  spend_bounds="
No machine-readable ceiling or expiry was set for this job, so the only hard
stops are each repo's own \`state/budget.json\` caps. Treat the paragraph
above as binding anyway."
fi

# --- Render ------------------------------------------------------------------
#
# Bash parameter substitution, not sed or awk. Every value here is multi-line
# operator prose, and in both of those an unescaped `&` in a replacement means
# "the text that matched" rather than an ampersand. That is a silently
# corrupted seed rather than an error, which is the worst way for this to
# fail. `${var//"pat"/$rep}` treats the replacement as literal text.
#
# The template's leading HTML comment is a note to whoever maintains the
# template. It is not addressed to the agent, so it is dropped rather than
# rendered: everything in the seed should be something the reader is meant to
# act on.
rendered="$(awk 'NR == 1 && $0 == "<!--" { skipping = 1 }
                 skipping { if ($0 == "-->") { skipping = 0; getline }; next }
                 { print }' "$seed_template")"
rendered="${rendered//"<<rendered-at>>"/$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
rendered="${rendered//"<<spend-authority>>"/$spend_authority}"
rendered="${rendered//"<<spend-bounds>>"/$spend_bounds}"
window_reserve="Leave ${window_reserve_percent}% of each reported provider window unspent. At that point, action: \`${window_reserve_action}\`."
rendered="${rendered//"<<window-reserve>>"/$window_reserve}"
rendered="${rendered//"<<repo-facts>>"/$facts}"
rendered="${rendered//"<<gotchas>>"/$gotchas}"
rendered="${rendered//"<<verbs-path>>"/$autometta_root/scripts/phat-controller.sh}"

if [[ "$rendered" == *"<<"*">>"* ]]; then
  die "internal: an unfilled placeholder survived rendering"
fi

if [[ "$to_stdout" == true ]]; then
  printf '%s\n' "$rendered"
  exit 0
fi

mkdir -p "$(dirname "$out_path")"
printf '%s\n' "$rendered" > "$out_path"
chmod 0600 "$out_path"
printf 'PASS seed rendered %s\n' "$out_path"

# Mirror the machine-readable answers into the mandate, which is where a
# script is allowed to read a threshold from.
if [[ -n "$token_ceiling" || -n "$expires_at" || -n "$window_reserve_percent" ]]; then
  if ! command -v yq >/dev/null 2>&1; then
    printf 'yq is not on PATH, so the spend and provider-window bounds could not be written to %s; the seed prose still carries them\n' "$mandate_path" >&2
    exit 0
  fi
  if [[ ! -f "$mandate_path" ]]; then
    [[ -f "$mandate_template" ]] || die "MISSING mandate template $mandate_template"
    mkdir -p "$(dirname "$mandate_path")"
    cp "$mandate_template" "$mandate_path"
  fi
  if [[ -n "$token_ceiling" ]]; then
    TOKEN_CEILING="$token_ceiling" yq -i '.spend_authority.token_ceiling = (strenv(TOKEN_CEILING) | tonumber)' "$mandate_path"
  fi
  if [[ -n "$expires_at" ]]; then
    EXPIRES_AT="$expires_at" yq -i '.spend_authority.expires_at = strenv(EXPIRES_AT)' "$mandate_path"
  fi
  WINDOW_RESERVE_PERCENT="$window_reserve_percent" yq -i \
    '.window_reserve.percent = (strenv(WINDOW_RESERVE_PERCENT) | tonumber)' "$mandate_path"
  WINDOW_RESERVE_ACTION="$window_reserve_action" yq -i \
    '.window_reserve.action = strenv(WINDOW_RESERVE_ACTION)' "$mandate_path"
  printf 'PASS spend and window bounds written %s\n' "$mandate_path"
fi
