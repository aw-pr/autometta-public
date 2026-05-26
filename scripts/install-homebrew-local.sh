#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"
template_file="$autometta_root/packaging/homebrew/autometta.rb.template"
tap_name="${AUTOMETTA_HOMEBREW_TAP:-local/autometta}"
dry_run=false

usage() {
  printf 'Usage: %s [--dry-run] [--tap owner/name]\n' "$(basename "$0")" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --tap)
      shift
      [[ $# -gt 0 ]] || usage
      tap_name="$1"
      ;;
    *)
      usage
      ;;
  esac
  shift
done

if [[ "$tap_name" != */* ]]; then
  printf 'tap must be owner/name, got %s\n' "$tap_name" >&2
  exit 1
fi

if [[ ! -f "$template_file" ]]; then
  printf 'MISSING template %s\n' "$template_file" >&2
  exit 1
fi

# Vendor Chart.js for the cost dashboard (stage 11). The dashboard renders
# offline; we must not depend on a CDN at runtime. The hash is pinned and
# mismatches abort the install.
chartjs_version="4.4.0"
chartjs_url="https://cdn.jsdelivr.net/npm/chart.js@${chartjs_version}/dist/chart.umd.js"
chartjs_sha256="321e3a3fa98da4aaa957d10be57cbb514de0989eed8f9d726b5d05902cd01904"
chartjs_dest="$autometta_root/dashboard/vendor/chart.min.js"
mkdir -p "$autometta_root/dashboard/vendor"
if [[ ! -f "$chartjs_dest" ]] \
   || [[ "$(shasum -a 256 "$chartjs_dest" | awk '{print $1}')" != "$chartjs_sha256" ]]; then
  printf 'Fetching Chart.js %s from %s\n' "$chartjs_version" "$chartjs_url"
  tmp_chart="$(mktemp)"
  if ! curl --fail-with-body -sSL --max-time 60 "$chartjs_url" -o "$tmp_chart"; then
    printf 'ERROR: failed to download Chart.js from %s\n' "$chartjs_url" >&2
    rm -f "$tmp_chart"
    exit 1
  fi
  observed_sha="$(shasum -a 256 "$tmp_chart" | awk '{print $1}')"
  if [[ "$observed_sha" != "$chartjs_sha256" ]]; then
    printf 'ERROR: Chart.js SHA256 mismatch.\n  expected %s\n  got      %s\n' \
      "$chartjs_sha256" "$observed_sha" >&2
    rm -f "$tmp_chart"
    exit 1
  fi
  mv "$tmp_chart" "$chartjs_dest"
  printf 'Chart.js vendored at %s (sha256 %s)\n' "$chartjs_dest" "$chartjs_sha256"
else
  printf 'Chart.js already vendored at %s (sha256 verified)\n' "$chartjs_dest"
fi

if command -v git >/dev/null 2>&1 && git -C "$autometta_root" rev-parse --short HEAD >/dev/null 2>&1; then
  version="$(git -C "$autometta_root" rev-parse --short HEAD)"
else
  version="local"
fi

if command -v brew >/dev/null 2>&1; then
  brew_repo="$(brew --repository)"
else
  brew_repo="/opt/homebrew"
fi

tap_owner="${tap_name%%/*}"
tap_repo="${tap_name##*/}"
tap_dir="$brew_repo/Library/Taps/$tap_owner/homebrew-$tap_repo"
formula_dir="$tap_dir/Formula"
formula_file="$formula_dir/autometta.rb"
archive_file="$tap_dir/autometta-$version.tar.gz"

printf 'Autometta root: %s\n' "$autometta_root"
printf 'Homebrew tap: %s\n' "$tap_name"
printf 'Formula path: %s\n' "$formula_file"
printf 'Archive path: %s\n' "$archive_file"

if "$dry_run"; then
  printf 'Dry run only; no files written and no brew command executed.\n'
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  printf 'MISSING brew\n' >&2
  exit 1
fi

mkdir -p "$formula_dir"

chmod +x "$autometta_root"/scripts/*.sh

printf '%s\n' "$version" > "$autometta_root/VERSION"

tar \
  --exclude './.git' \
  --exclude './state' \
  --exclude './logs' \
  --exclude './.publish-guard.local' \
  -czf "$archive_file" \
  -C "$autometta_root" .
sha256="$(shasum -a 256 "$archive_file" | awk '{print $1}')"

tmp_file="$(mktemp)"
python3 - "$template_file" "$tmp_file" "$archive_file" "$sha256" "$version" <<'PY'
import pathlib
import sys

template_path, output_path, archive_path, sha256, version = sys.argv[1:]
text = pathlib.Path(template_path).read_text()
text = text.replace("__AUTOMETTA_ARCHIVE__", archive_path)
text = text.replace("__AUTOMETTA_SHA256__", sha256)
text = text.replace("__AUTOMETTA_VERSION__", version)
pathlib.Path(output_path).write_text(text)
PY
mv "$tmp_file" "$formula_file"

if brew list --formula autometta >/dev/null 2>&1; then
  brew reinstall "$formula_file"
else
  brew install "$formula_file"
fi

printf 'PASS installed autometta\n'
