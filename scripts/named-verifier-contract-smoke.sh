#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/177-named-verifier-contract.md
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/subscriber with spaces"
git init -q "$repo"
cd "$repo"
mkdir -p stage-cards tests
card=stage-cards/01-check.md
testfile=tests/contract.sh
checker="$root/scripts/check-contract-test-gate.sh"
# Split the fixture marker names so only this smoke's own block is digested.
printf '# AUTOMETTA-CONTRACT-%s card=%s\ntrue\n# AUTOMETTA-CONTRACT-%s\n' BEGIN "$card" END > "$testfile"
digest="$("$checker" print "$testfile")"
printf '# Card\n\n## Contract test\n\n- **Test file:** `%s`\n- **Assertions digest:** `%s`\n' "$testfile" "$digest" > "$card"
git add .
git -c user.name=fixture -c user.email=fixture@local -c core.hooksPath=/dev/null commit -qm fixture
verify() { "$checker" --verify-card "$card"; }
verify || { echo 'FAIL: valid unchanged subscriber oracle needs a working named checker' >&2; exit 1; }
# Inspect the actual argv reaching both Codex CLI seats and the context the
# shared SDK builder provides to shell-less verifiers. All providers are stubs.
export AUTOMETTA_HOME="$tmp/controller" AUTOMETTA_LOCAL_REFS="$tmp/no-local-refs"
mkdir -p "$tmp/bin" "$AUTOMETTA_HOME/log" templates
touch "$AUTOMETTA_LOCAL_REFS"
export AUTOMETTA_CODEX_MODE_VERIFIER=subscription AUTOMETTA_CLAUDE_MODE_VERIFIER=api
export AUTOMETTA_CODEX_TRANSPORT=cli OP_REF_ANTHROPIC_API_KEY=op://fixture/unused/key
export AUTOMETTA_PANEL_POLL_INTERVAL=1 AUTOMETTA_NOTIFY=0
printf 'Preserve subscriber rubric XYZ.\nLegacy method: run scripts/check-contract-test-gate.sh --worktree\n' > templates/verifier-prompt.md
printf '\n- **Verifier:** GPT-6.2 Astra <gpt-6-2-astra@local>\n\n## Deliverables\n\n1. `tests/contract.sh`\n' >> "$card"
printf 'version: 1\ncurrent_stage: 01-check\nstages: [{id: 01-check, status: in_progress}]\n' > "$tmp/fixture-state"
mkdir -p state
cp "$tmp/fixture-state" state/state.yaml
echo 'state/' > .gitignore
cat > "$tmp/bin/op-fetch" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  if [[ "$arg" == *"Preserve subscriber rubric XYZ"* ]]; then
    printf '%s\n' "$arg" > "$CAPTURE.pending"
    mv "$CAPTURE.pending" "$CAPTURE"
  fi
done
exit 0
STUB
chmod +x "$tmp/bin/op-fetch"
export PATH="$tmp/bin:$PATH"
for mode in cli panel; do
  export CAPTURE="$tmp/$mode.prompt"
  panel=0
  [[ "$mode" != panel ]] || panel=1
  AUTOMETTA_VERIFIER_PANEL="$panel" "$root/scripts/spawn-verifier.sh" "$repo/$card" "$repo" "$repo" > "$tmp/$mode.pid"
  for spin in $(seq 1 100); do [[ ! -s "$CAPTURE" ]] || break; sleep 0.1; done
  [[ -s "$CAPTURE" ]] || { echo "FAIL: $mode did not render the subscriber rubric" >&2; exit 1; }
  if [[ "$mode" == panel ]]; then
    for spin in $(seq 1 100); do [[ ! -s state/verifiers/01-check.json ]] || break; sleep 0.1; done
    [[ -s state/verifiers/01-check.json ]] || { echo 'FAIL: offline panel failed to terminate' >&2; exit 1; }
  fi
  grep -F -- "$checker" "$CAPTURE" >/dev/null && grep -F -- '--verify-card' "$CAPTURE" >/dev/null || {
    echo "FAIL: $mode prompt omitted installed named checker" >&2; exit 1; }
done
sdk_context() {
  python3 - "$root" "$repo/$card" <<'PY'
from pathlib import Path
import importlib.util, sys
root, card = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("verifier", root / "scripts/verify-sdk.py")
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)
print(sdk.build_variable_block("01-check", card, [], Path("state/verifiers/01-check.json")))
PY
}
sdk_context > "$tmp/sdk-good"
grep -Ei 'contract.*PASS|PASS.*contract' "$tmp/sdk-good" >/dev/null

git add "$card" templates .gitignore
git -c user.name=fixture -c user.email=fixture@local -c core.hooksPath=/dev/null commit -qm subscriber
# Both snapshots are clean here. The worktree-only gate cannot catch this mismatch.
sed -i.bak 's/^true$/false/' "$testfile"
rm "$testfile.bak"
git -c user.name=fixture -c user.email=fixture@local -c core.hooksPath=/dev/null commit -qam mismatch
sdk_context > "$tmp/sdk-bad" || true
grep -Ei 'contract.*FAIL|FAIL.*contract' "$tmp/sdk-bad" >/dev/null
if verify; then echo 'FAIL: unchanged mismatched digest admitted' >&2; exit 1; fi
rm "$testfile"
if verify; then echo 'FAIL: missing named oracle admitted' >&2; exit 1; fi
git checkout -q HEAD~1 -- "$testfile"
sed -i.bak 's@card=stage-cards/01-check.md@card=stage-cards/02-other.md@' "$testfile"
rm "$testfile.bak"
if verify; then echo 'FAIL: marker owned by a different card admitted' >&2; exit 1; fi
git checkout -q HEAD~1 -- "$testfile"
cp "$card" "$tmp/card"
sed -i.bak 's/sha256:/bad:/' "$card"
rm "$card.bak"
if verify; then echo 'FAIL: malformed declaration admitted' >&2; exit 1; fi
mv "$tmp/card" "$card"
git reset -q -- "$testfile"
# A valid named oracle does not excuse a separate changed malformed smoke.
mkdir -p scripts
echo 'echo invalid' > scripts/other-smoke.sh
if verify; then echo 'FAIL: skipped unrelated changed candidate' >&2; exit 1; fi
# AUTOMETTA-CONTRACT-END
