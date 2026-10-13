#!/usr/bin/env bash
# Offline proof for stage card 153: a reader never sees half a payload.
#
# attach-card-text.py runs after the aggregator's atomic rename, every five
# seconds under `dashboard.sh --serve`, and on 2026-10-11 it rewrote the
# 1.2MB data.json in place: two direct reads that afternoon caught it half
# written. The fixture payload is large enough that an in-place write takes
# many syscalls. No auth, no network, no token spend.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
attach="$script_dir/attach-card-text.py"
tmp="$(mktemp -d)"
reader_pid=""
cleanup() {
  [[ -z "$reader_pid" ]] || kill "$reader_pid" 2>/dev/null || true
  case "$tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$tmp" ;; esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

repo="$tmp/repo"
dash="$tmp/dash"
mkdir -p "$repo/stage-cards" "$dash"
printf '# Stage card 01: fixture\n\nBody line.\n' > "$repo/stage-cards/01-fixture.md"
python3 - "$dash/data.json" "$repo" <<'PY'
import json, sys
stages = [{"id": "%03d-stage" % i, "card": "stage-cards/01-fixture.md", "pad": "x" * 2000}
          for i in range(600)]
json.dump({"generated_at": "2026-10-11T13:00:00Z",
           "repos": [{"name": "fixture", "repo_path": sys.argv[2], "stages": stages}]},
          open(sys.argv[1], "w"))
PY
cp "$dash/data.json" "$dash/pristine.json"
printf 'window.AUTOMETTA_DATA = {};\n' > "$dash/data.js"

inode() { stat -f %i "$1" 2>/dev/null || stat -c %i "$1"; }

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/153-a-reader-never-sees-half-a-payload.md
# 1. Both files are replaced by rename, not rewritten in place: the inode
#    changes, the content is whole and carries the card text.
before_json="$(inode "$dash/data.json")"
before_js="$(inode "$dash/data.js")"
python3 "$attach" "$dash/data.json" "$dash/data.js" || fail "153: attach-card-text.py exited non-zero"
[[ "$(inode "$dash/data.json")" != "$before_json" ]] || fail "153: data.json was rewritten in place, not replaced"
[[ "$(inode "$dash/data.js")" != "$before_js" ]] || fail "153: data.js was rewritten in place, not replaced"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["repos"][0]["stages"][0]["card_text"].startswith("# Stage card 01")' \
  "$dash/data.json" || fail "153: data.json lost the attached card text"
head -c 24 "$dash/data.js" | grep -q '^window.AUTOMETTA_DATA = ' || fail "153: data.js lost its prefix"
tail -c 3 "$dash/data.js" | grep -q '};' || fail "153: data.js is not whole"
# 2. No temporary file is left beside the payload.
leftovers="$(find "$dash" -maxdepth 1 -type f ! -name data.json ! -name data.js ! -name pristine.json)"
[[ -z "$leftovers" ]] || fail "153: temporary files left behind: $leftovers"
# 3. A reader polling throughout a burst of rewrites never parses a partial
#    data.json.
cp "$dash/pristine.json" "$dash/data.json"
python3 - "$dash/data.json" "$tmp/reader.out" <<'PY' &
import json, sys, time
bad = 0
reads = 0
stop = time.time() + 6
while time.time() < stop:
    try:
        with open(sys.argv[1]) as fh:
            json.load(fh)
    except (ValueError, OSError):
        bad += 1
    reads += 1
open(sys.argv[2], "w").write("%d\t%d\n" % (bad, reads))
PY
reader_pid=$!
for _ in $(seq 1 20); do
  cp "$dash/pristine.json" "$dash/data.json.seed"
  mv "$dash/data.json.seed" "$dash/data.json"
  python3 "$attach" "$dash/data.json" "$dash/data.js" || fail "153: a rewrite in the burst failed"
done
wait "$reader_pid" || true
reader_pid=""
read -r bad reads < "$tmp/reader.out"
(( reads > 20 )) || fail "153: the reader barely ran ($reads reads); the test proves nothing"
(( bad == 0 )) || fail "153: a reader parsed a partial data.json $bad times in $reads reads"
# 4. A payload that cannot be read is left exactly as it was.
printf '{"repos": [' > "$dash/data.json"
cp "$dash/data.json" "$tmp/broken.copy"
if python3 "$attach" "$dash/data.json" "$dash/data.js" 2>/dev/null; then
  fail "153: a malformed data.json should make the script exit non-zero"
fi
cmp -s "$dash/data.json" "$tmp/broken.copy" || fail "153: a malformed data.json was overwritten"
# AUTOMETTA-CONTRACT-END

printf 'card-text-atomic-smoke: PASS\n'
