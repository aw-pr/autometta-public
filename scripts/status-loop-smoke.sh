#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
controller="$fixture/controller"
bin_dir="$fixture/bin"
label="com.autometta.tick.fleet"
mkdir -p "$controller/subscribers" "$controller/log" "$bin_dir" "$fixture/home/Library/LaunchAgents"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3"
}

write_launchctl() {
  local state="$1"
  cat > "$bin_dir/launchctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "list" && "$state" == "present" ]]; then
  printf '%s\\n' '123 0 $label'
fi
EOF
  chmod +x "$bin_dir/launchctl"
}

cat > "$fixture/home/Library/LaunchAgents/${label}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$label</string><key>StartInterval</key><integer>1</integer></dict></plist>
EOF
printf 'enabled: false\nrepo_path: %s\n' "$fixture/repo" > "$controller/subscribers/repo.yaml"

run_status() {
  env HOME="$fixture/home" AUTOMETTA_HOME="$controller" PATH="$bin_dir:$PATH" \
    "$script_dir/status.sh"
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/107-status-says-when-the-loop-is-not-loaded.md
write_launchctl absent
absent="$(run_status)"
assert_contains "$absent" 'loop: NOT LOADED -- run: autometta install-launchagent' 'absent loop was not surfaced'
assert_contains "$absent" 'repo' 'absent loop suppressed the repo table'

write_launchctl present
touch "$controller/log/tick-current.log"
loaded="$(run_status)"
assert_contains "$loaded" "loop: loaded ($label, last fire" 'loaded loop was not surfaced'

rm -f "$controller/log/tick-current.log"
touch -t 202001010000 "$controller/log/tick-stale.log"
stale="$(run_status)"
assert_contains "$stale" 'WARNING last fire' 'stale loaded loop was not warned about'
# AUTOMETTA-CONTRACT-END

printf 'PASS status loop smoke\n'
