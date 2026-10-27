#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
card="stage-cards/165-one-tick-agent-for-the-fleet.md"

fail() {
  printf 'FAIL: %s: %s\n' "$card" "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/165-one-tick-agent-for-the-fleet.md
home="$fixture/home"
controller="$fixture/controller"
bin_dir="$fixture/bin"
agents="$home/Library/LaunchAgents"
calls="$fixture/launchctl.calls"
fleet_label="com.autometta.tick.fleet"
fleet_plist="$agents/$fleet_label.plist"
mkdir -p "$agents" "$controller/subscribers" "$controller/log" "$bin_dir" \
  "$fixture/repos/alpha" "$fixture/repos/beta/.autometta" "$fixture/repos/fleet"
sed -e 's|<key>RunAtLoad</key>|<key>FixtureMarker</key><string>beta-template</string><key>RunAtLoad</key>|' \
  "$repo_root/templates/launchagent.plist.tpl" > "$fixture/repos/beta/.autometta/launchagent.plist.tpl"
: > "$calls"

cat > "$bin_dir/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls"
exit 0
EOF
cat > "$bin_dir/crontab" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$bin_dir/launchctl" "$bin_dir/crontab"

write_legacy_plist() {
  local label="$1"
  cat > "$agents/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$label</string></dict></plist>
EOF
}

run_in_fixture() {
  env HOME="$home" AUTOMETTA_HOME="$controller" AUTOMETTA_ROOT="$repo_root" \
    AUTOMETTA_LAUNCHAGENT_BIN=/usr/local/bin/autometta PATH="$bin_dir:$PATH" "$@"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

tick_plists() {
  find "$agents" -maxdepth 1 -name 'com.autometta.tick*.plist' -print | sort
}

write_legacy_plist com.autometta.tick.oldrepo
write_legacy_plist com.autometta.tick.alpha
write_legacy_plist com.example.unrelated
write_legacy_plist com.autometta.emergence-lab-stage-114-overnight

out="$(run_in_fixture "$repo_root/scripts/install-launchagent.sh" "$fixture/repos/alpha" 2>&1)" \
  || fail "install with a repo argument exited non-zero: $out"
[[ -f "$fleet_plist" ]] || fail "install did not write $fleet_label.plist"
[[ "$(plist_value "$fleet_plist" Label)" == "$fleet_label" ]] \
  || fail "fleet plist Label is not $fleet_label"
[[ "$(plist_value "$fleet_plist" StartInterval)" == "300" ]] \
  || fail "default StartInterval is not 300"
[[ "$(plist_value "$fleet_plist" StandardOutPath)" == "$controller/log/launchagent.out.log" ]] \
  || fail "fleet stdout log is not \$AUTOMETTA_HOME/log/launchagent.out.log"
[[ "$(plist_value "$fleet_plist" StandardErrorPath)" == "$controller/log/launchagent.err.log" ]] \
  || fail "fleet stderr log is not \$AUTOMETTA_HOME/log/launchagent.err.log"
[[ ! -e "$agents/com.autometta.tick.oldrepo.plist" ]] || fail "legacy oldrepo agent plist was left standing"
[[ ! -e "$agents/com.autometta.tick.alpha.plist" ]] || fail "legacy alpha agent plist was left standing"
[[ "$(tick_plists)" == "$fleet_plist" ]] || fail "expected exactly one tick plist, found: $(tick_plists)"
grep -Fq "bootout gui/$(id -u)/com.autometta.tick.oldrepo" "$calls" || fail "legacy oldrepo agent was not booted out"
grep -Fq "bootout gui/$(id -u)/com.autometta.tick.alpha" "$calls" || fail "legacy alpha agent was not booted out"
grep -Fq "bootstrap gui/$(id -u) $fleet_plist" "$calls" || fail "fleet agent was not bootstrapped"
if grep '^bootstrap ' "$calls" | grep -vFq "$fleet_plist"; then
  fail "something other than the fleet agent was bootstrapped"
fi
[[ "$out" == *"PASS removed legacy launchagent com.autometta.tick.oldrepo"* ]] \
  || fail "install output does not name the removed oldrepo agent"
[[ "$out" == *"PASS removed legacy launchagent com.autometta.tick.alpha"* ]] \
  || fail "install output does not name the removed alpha agent"
[[ -f "$agents/com.example.unrelated.plist" ]] || fail "unrelated LaunchAgent was removed"
[[ -f "$agents/com.autometta.emergence-lab-stage-114-overnight.plist" ]] \
  || fail "non-tick autometta LaunchAgent was removed"
if grep -Eq 'com\.example\.unrelated|stage-114-overnight' "$calls"; then
  fail "a non-tick LaunchAgent was passed to launchctl"
fi
if plist_value "$fleet_plist" FixtureMarker >/dev/null; then
  fail "install for alpha rendered from another repo's template"
fi

run_in_fixture "$repo_root/scripts/install-launchagent.sh" "$fixture/repos/beta" --interval 120 >/dev/null 2>&1 \
  || fail "second install exited non-zero"
[[ "$(tick_plists)" == "$fleet_plist" ]] || fail "second repo install added a tick plist: $(tick_plists)"
[[ "$(plist_value "$fleet_plist" StartInterval)" == "120" ]] || fail "--interval was not honoured"
[[ "$(plist_value "$fleet_plist" FixtureMarker)" == "beta-template" ]] \
  || fail "install for beta did not render from beta's own template"

if run_in_fixture "$repo_root/scripts/install-launchagent.sh" "$fixture/repos/missing" >/dev/null 2>&1; then
  fail "install for a missing repo path exited zero"
fi

rm -f "$fleet_plist"
run_in_fixture "$repo_root/bin/autometta" install-launchagent >/dev/null 2>&1 \
  || fail "autometta install-launchagent with no repo argument exited non-zero"
[[ -f "$fleet_plist" ]] || fail "install with no repo argument did not write the fleet plist"
if plist_value "$fleet_plist" FixtureMarker >/dev/null; then
  fail "install with no repo argument did not render from the canonical template"
fi

write_legacy_plist com.autometta.tick.gamma
: > "$calls"
out="$(run_in_fixture "$repo_root/bin/autometta" uninstall-launchagent "$fixture/repos/gamma" 2>&1)" \
  || fail "uninstall-launchagent <repo> exited non-zero: $out"
[[ ! -e "$agents/com.autometta.tick.gamma.plist" ]] || fail "uninstall <repo> left the legacy agent"
grep -Fq "bootout gui/$(id -u)/com.autometta.tick.gamma" "$calls" || fail "uninstall <repo> did not boot out the legacy agent"
[[ "$out" == *"$fleet_label"*"unaffected"* ]] || fail "uninstall <repo> does not say the fleet agent is unaffected"
[[ -f "$fleet_plist" ]] || fail "uninstall <repo> removed the fleet agent"
if grep -Fq "bootout gui/$(id -u)/$fleet_label" "$calls"; then fail "uninstall <repo> booted out the fleet agent"; fi

if run_in_fixture "$repo_root/bin/autometta" uninstall-launchagent "$fixture/repos/fleet" >/dev/null 2>&1; then
  fail "uninstall-launchagent for a repo named fleet exited zero"
fi
[[ -f "$fleet_plist" ]] || fail "uninstall for a repo named fleet removed the fleet agent"
if grep -Fq "bootout gui/$(id -u)/$fleet_label" "$calls"; then fail "uninstall for a repo named fleet booted out the fleet agent"; fi

: > "$calls"
run_in_fixture "$repo_root/bin/autometta" uninstall-launchagent >/dev/null 2>&1 \
  || fail "uninstall-launchagent with no argument exited non-zero"
[[ ! -e "$fleet_plist" ]] || fail "bare uninstall left the fleet plist"
grep -Fq "bootout gui/$(id -u)/$fleet_label" "$calls" || fail "bare uninstall did not boot out the fleet agent"
[[ -f "$agents/com.example.unrelated.plist" ]] || fail "bare uninstall removed an unrelated LaunchAgent"

grep -Fq 'install-launchagent.sh' "$repo_root/scripts/subscribe-repo.sh" \
  || fail "subscribe-repo.sh no longer installs the LaunchAgent"
grep -Fq "$fleet_label" "$repo_root/scripts/status.sh" || fail "status.sh no longer checks $fleet_label"
for doc in MANUAL.md docs/setup.md; do
  grep -Fq "$fleet_label" "$repo_root/$doc" || fail "$doc does not name $fleet_label"
  if grep -Eiq 'per-repo (launchd )?LaunchAgent|once for each subscribed repo|com\.autometta\.tick\.<repo' "$repo_root/$doc"; then
    fail "$doc still describes a per-repo LaunchAgent"
  fi
done
# AUTOMETTA-CONTRACT-END

printf 'PASS launchagent-fleet-smoke\n'
