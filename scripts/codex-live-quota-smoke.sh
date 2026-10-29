#!/usr/bin/env bash
# Offline proof that a stale Codex reading is refreshed from `codex app-server`
# without a model turn, published for the next reader, and left alone when fresh.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"; }

export AI_QUOTA_DIR="$fixture/quota"
export AUTOMETTA_CODEX_SESSIONS="$fixture/sessions"
export AUTOMETTA_CODEX_BIN="$fixture/codex"
unset AI_QUOTA_NOW_EPOCH AUTOMETTA_CODEX_LIVE_READ
mkdir -p "$AI_QUOTA_DIR" "$AUTOMETTA_CODEX_SESSIONS"

week_reset=$(( $(date +%s) + 86400 ))
cat > "$AUTOMETTA_CODEX_BIN" <<STUB
#!/usr/bin/env bash
[[ "\$1" == app-server ]] || exit 2
printf 'call\n' >> "$fixture/calls"
while IFS= read -r line; do
  case "\$line" in
    *'"id": 2'*|*'"id":2'*)
      printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":37,"windowDurationMins":10080,"resetsAt":%s},"secondary":null}}}\n' "$week_reset" ;;
  esac
done
STUB
chmod +x "$AUTOMETTA_CODEX_BIN"

printf '{"timestamp":"2020-01-01T00:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":5,"window_minutes":10080,"resets_at":%s}}}}\n' \
  "$week_reset" > "$AUTOMETTA_CODEX_SESSIONS/rollout-old.jsonl"

reading="$(python3 "$script_dir/quota-window.py" codex)"
assert_eq codex-app-server "$(jq -r '.source' <<<"$reading")" "stale rollout refreshed live"
assert_eq 37.0 "$(jq -r '.windows[0].utilization' <<<"$reading")" "live utilisation"
assert_eq Weekly "$(jq -r '.windows[0].label' <<<"$reading")" "live label"
assert_eq true "$(jq -r '.allowed' <<<"$(python3 "$script_dir/quota-window.py" codex-admission <<<"$reading")")" "live reading admits"
assert_eq codex-app-server "$(jq -r '.source' "$AI_QUOTA_DIR/codex.json")" "live reading published"
printf 'PASS stale rollout: app-server read, admitted, published to codex.json\n'

python3 "$script_dir/quota-window.py" codex >/dev/null
assert_eq 1 "$(wc -l < "$fixture/calls" | tr -d ' ')" "fresh snapshot reused"
printf 'PASS fresh published snapshot is reused without another server\n'

rm "$AI_QUOTA_DIR/codex.json"
assert_eq codex-rollout-log "$(AUTOMETTA_CODEX_LIVE_READ=0 python3 "$script_dir/quota-window.py" codex | jq -r '.source')" "live read off"
assert_eq codex-rollout-log "$(AI_QUOTA_NOW_EPOCH=2000000000 python3 "$script_dir/quota-window.py" codex | jq -r '.source')" "fixture clock skips live read"
assert_eq codex-rollout-log "$(AUTOMETTA_CODEX_BIN="$fixture/absent" python3 "$script_dir/quota-window.py" codex | jq -r '.source')" "absent binary falls back"
assert_eq 1 "$(wc -l < "$fixture/calls" | tr -d ' ')" "no server started when disabled"
printf 'PASS live read off, fixture clock and absent binary fall back to the rollout reading\n'
