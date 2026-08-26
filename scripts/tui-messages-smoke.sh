#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
empty_repo="$fixture/empty-repo"
polls="$fixture/polls.json"
mkdir -p "$repo/state/phat-controller-inbox/pending" \
  "$repo/state/phat-controller-inbox/processed" "$repo/state/phat-controller-outbox" \
  "$empty_repo"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3"
}

cat > "$polls" <<'EOF'
{"polls":[{"_now":1787731200,"name":"fixture-messages","stages":[],"agents":[],"spend":{}}]}
EOF

cat > "$repo/state/phat-controller-journal.jsonl" <<'EOF'
{"ts":"2026-08-26T06:50:00Z","seq":1,"phase":"decision","verb":"preserve","rationale":"preserved failed work before retry"}
{"ts":"2026-08-26T06:51:00Z","seq":2,"phase":"outcome","result":"acted","note":"preserved commit abc1234"}
{"ts":"2026-08-26T06:55:00Z","seq":3,"phase":"decision","verb":"inbox-read","rationale":"read operator message"}
{"ts":"2026-08-26T07:02:00Z","seq":4,"phase":"decision","verb":"inbox-refuse","message_id":"msg-processed","rationale":"outside mandate","evidence":"inbox message msg-processed"}
{"ts":"2026-08-26T07:03:00Z","seq":5,"phase":"outcome","result":"refused","message_id":"msg-processed","note":"reply written to outbox"}
{"ts":"2026-08-26T07:41:00Z","seq":6,"phase":"decision","verb":"requeue","rationale":"dispatched worker for card 68"}
EOF
printf '%s\n' 'why did card 36 escalate three times?' > \
  "$repo/state/phat-controller-inbox/pending/msg-pending.md"
printf '%s\n' 'raise the cap for this run' > \
  "$repo/state/phat-controller-inbox/processed/msg-processed.md"
printf '%s\n' 'outside mandate; the cap stays as declared' > \
  "$repo/state/phat-controller-outbox/msg-processed.md"
touch -t 202608260655 "$repo/state/phat-controller-inbox/pending/msg-pending.md"
touch -t 202608260658 "$repo/state/phat-controller-inbox/processed/msg-processed.md"
touch -t 202608260702 "$repo/state/phat-controller-outbox/msg-processed.md"

capture() {
  local target="$1" width="$2" height="$3" keys="${4:-],]}"
  LC_ALL=C.UTF-8 TERM=xterm-256color AUTOMETTA_TUI_CAPTURE=true \
    AUTOMETTA_TUI_COLUMNS="$width" AUTOMETTA_TUI_ROWS="$height" \
    AUTOMETTA_TUI_INTERVAL=5 AUTOMETTA_TUI_FIXTURE_POLLS="$polls" \
    AUTOMETTA_TUI_KEYS="$keys" "$script_dir/tui.sh" "$target"
}

frame80="$(capture "$repo" 80 40)"
frame119="$(capture "$repo" 119 40)"
frame160="$(capture "$repo" 160 40)"

for spec in "80:$frame80" "119:$frame119" "160:$frame160"; do
  width="${spec%%:*}"
  frame="${spec#*:}"
  assert_contains "$frame" '[0]─Controller' "$width-column controller panel missing"
  assert_contains "$frame" '06:50  decision  preserved failed work before retry' "$width-column journal decision missing"
  assert_contains "$frame" '07:03  refusal' "$width-column refusal journal row missing"
  assert_contains "$frame" 'you   06:55 [pending]  why did card 36 escalate three times?' "$width-column pending message missing"
  assert_contains "$frame" 'you   06:58  raise the cap for this run' "$width-column processed message missing"
  assert_contains "$frame" 'ctrl  07:02 [refusal]  outside mandate; the cap stays as declared' "$width-column refusal reply missing"
  AUTOMETTA_TEST_FRAME="$frame" AUTOMETTA_TEST_WIDTH="$width" python3 - <<'PY' || fail "$width-column frame overflowed"
import os
width = int(os.environ["AUTOMETTA_TEST_WIDTH"])
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
assert len(lines) == 40
assert all(len(line) <= width for line in lines)
PY
done

AUTOMETTA_TEST_FRAME="$frame119" python3 - <<'PY' || fail "conversation was not interleaved by time"
import os
frame = os.environ["AUTOMETTA_TEST_FRAME"]
assert frame.index("you   06:55") < frame.index("you   06:58") < frame.index("ctrl  07:02")
PY

before="$(find "$repo/state/phat-controller-inbox/pending" -type f | wc -l | tr -d ' ')"
composed="$(capture "$repo" 119 40 'm,please explain card 71,ENTER')"
after="$(find "$repo/state/phat-controller-inbox/pending" -type f | wc -l | tr -d ' ')"
[[ "$after" -eq "$((before + 1))" ]] || fail "compose did not create exactly one pending file"
assert_contains "$composed" 'you' "composed message was not rendered"
assert_contains "$composed" '[pending]  please explain card 71' "composed message was not observed as pending"
assert_contains "$composed" "queued for the controller's next pass" "freshness note missing"
new_file="$(find "$repo/state/phat-controller-inbox/pending" -type f -newer "$repo/state/phat-controller-inbox/pending/msg-pending.md" | head -n1)"
[[ -n "$new_file" && -f "$new_file" ]] || fail "composed pending file absent"
new_id="$(basename "$new_file" .md)"

parsed="$(
  source "$script_dir/phat-controller.sh"
  pc_inbox_scan "$repo"
)" || fail "real pc_inbox_scan rejected the composed message"
assert_contains "$parsed" "### $new_id" "real pc_inbox_scan did not parse the composed id"
assert_contains "$parsed" 'please explain card 71' "real pc_inbox_scan did not parse the composed body"

cancel_before="$(find "$repo/state/phat-controller-inbox/pending" -type f | wc -l | tr -d ' ')"
cancelled="$(capture "$repo" 119 40 'm,this must not land,ESC')"
cancel_after="$(find "$repo/state/phat-controller-inbox/pending" -type f | wc -l | tr -d ' ')"
[[ "$cancel_after" -eq "$cancel_before" ]] || fail "escape wrote a pending message"
assert_contains "$cancelled" 'message cancelled' "escape cancellation was not rendered"

empty="$(capture "$empty_repo" 119 40)"
assert_contains "$empty" 'no controller record yet' "fresh repo journal state is dishonest"
assert_contains "$empty" "the controller's first decision will populate this strip" "fresh repo journal population note missing"
assert_contains "$empty" 'no operator messages or controller replies yet' "fresh repo conversation state is dishonest"
assert_contains "$empty" "replies arrive after the controller's next pass" "fresh repo reply timing note missing"

bounded_repo="$fixture/bounded-repo"
mkdir -p "$bounded_repo/state"
for n in $(seq 1 14); do
  printf '{"ts":"2026-08-26T07:%02d:00Z","seq":%d,"phase":"decision","summary":"bounded row %02d"}\n' \
    "$n" "$n" "$n" >> "$bounded_repo/state/phat-controller-journal.jsonl"
done
bounded="$(capture "$bounded_repo" 119 24)"
assert_contains "$bounded" 'and 7 earlier' "bounded journal did not report withheld rows"
assert_contains "$bounded" 'bounded row 14' "bounded journal did not keep newest row last"
scrolled="$(capture "$bounded_repo" 119 24 '],],k')"
assert_contains "$scrolled" 'bounded row 13' "k did not scroll the journal towards older rows"

python3 - "$script_dir/lib/tui/messages.py" "$script_dir/lib/tui/app.py" \
  "$script_dir/lib/tui/render.py" <<'PY' || fail "message-bus seam is scattered"
import ast
import sys
messages, app, render = (open(path, encoding="utf-8").read() for path in sys.argv[1:])
for source in (app, render):
    assert "phat-controller-journal" not in source
    assert "phat-controller-inbox" not in source
    assert "phat-controller-outbox" not in source
tree = ast.parse(messages)
writers = [node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and node.name == "write_pending"]
assert len(writers) == 1
assert '"phat-controller-inbox", "pending"' in messages
assert '"phat-controller-inbox", "processed"' in messages
assert '"phat-controller-outbox"' in messages
PY

[[ -z "$(git -C "$script_dir/.." diff -- scripts/phat-controller.sh)" ]] || \
  fail "phat-controller.sh was modified"

printf 'PASS tui messages: 80/119/160 captures, interleaving, pending/refusal, compose parse, cancel, empty state, bounded journal, one reader seam\n'
