#!/usr/bin/env bash
# facts-lint.sh - validate a fact ledger JSONL file against schemas/fact-ledger.json.
#
# The ledger (memory/facts.jsonl, see docs/fact-ledger.md) is append-only and
# committed, so a malformed line is a permanent malformed line. This is the gate
# that keeps one out. It reads one JSON object per line and checks it against
# the schema's required fields, types, enums, patterns and additionalProperties
# rule, stopping at the first bad line.
#
# Usage:
#   scripts/facts-lint.sh [--allow-missing] [--schema PATH] [FILE]
#
#   FILE            ledger to check; defaults to memory/facts.jsonl in this repo.
#   --allow-missing treat an absent file as an empty ledger and exit 0.
#   --schema PATH   validate against a schema other than schemas/fact-ledger.json.
#
# Exit 0 when every line validates (an empty ledger counts), 1 naming the first
# bad line and why, 2 on a usage or environment error.
#
# python3 standard library only: the jsonschema package is not a dependency of
# this repo, and the schema uses a small enough subset to check by hand.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

schema_path="$repo_root/schemas/fact-ledger.json"
ledger_path=""
allow_missing=0

usage() {
  sed -n '10,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-missing) allow_missing=1; shift ;;
    --schema)
      [[ $# -ge 2 ]] || { printf 'facts-lint: --schema needs a path\n' >&2; exit 2; }
      schema_path="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) printf 'facts-lint: unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)
      [[ -z "$ledger_path" ]] || { printf 'facts-lint: only one ledger file may be given\n' >&2; exit 2; }
      ledger_path="$1"; shift ;;
  esac
done

[[ -n "$ledger_path" ]] || ledger_path="$repo_root/memory/facts.jsonl"

if [[ ! -f "$schema_path" ]]; then
  printf 'facts-lint: schema not found: %s\n' "$schema_path" >&2
  exit 2
fi

if [[ ! -e "$ledger_path" ]]; then
  if [[ "$allow_missing" == "1" ]]; then
    printf 'PASS %s: no ledger yet (0 facts)\n' "$ledger_path"
    exit 0
  fi
  printf 'FAIL %s: file not found (pass --allow-missing to accept an absent ledger)\n' "$ledger_path" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  printf 'facts-lint: python3 not found on PATH\n' >&2
  exit 2
}

python3 - "$schema_path" "$ledger_path" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

schema_path, ledger_path = Path(sys.argv[1]), Path(sys.argv[2])

try:
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    print(f"facts-lint: unreadable schema {schema_path}: {exc}", file=sys.stderr)
    raise SystemExit(2)

properties = schema.get("properties", {})
required = schema.get("required", [])
extra_allowed = schema.get("additionalProperties", True)

JSON_TYPES = {
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "object": dict,
    "array": list,
}


def field_error(name, value, rule):
    """Return a reason string when value breaks rule, else None."""
    expected = rule.get("type")
    if expected is not None:
        python_type = JSON_TYPES.get(expected)
        # bool is a subclass of int; a JSON integer field must not accept true.
        if python_type is None or not isinstance(value, python_type) or (
            expected in ("integer", "number") and isinstance(value, bool)
        ):
            return f"{name}: expected {expected}, got {type(value).__name__}"

    if "enum" in rule and value not in rule["enum"]:
        permitted = ", ".join(str(item) for item in rule["enum"])
        return f"{name}: {value!r} is not one of the permitted values ({permitted})"

    if isinstance(value, str):
        minimum = rule.get("minLength")
        if minimum is not None and len(value) < minimum:
            return f"{name}: shorter than the minimum {minimum} characters"
        pattern = rule.get("pattern")
        if pattern is not None and re.search(pattern, value) is None:
            return f"{name}: {value!r} does not match {pattern}"

    return None


def line_error(record):
    if not isinstance(record, dict):
        return f"expected a JSON object, got {type(record).__name__}"

    for name in required:
        if name not in record:
            return f"missing required field {name!r}"

    if extra_allowed is False:
        unknown = [key for key in record if key not in properties]
        if unknown:
            permitted = ", ".join(sorted(properties))
            return f"unknown field {unknown[0]!r} (permitted: {permitted})"

    for name, value in record.items():
        rule = properties.get(name)
        if rule is None:
            continue
        reason = field_error(name, value, rule)
        if reason is not None:
            return reason

    return None


count = 0
with ledger_path.open(encoding="utf-8") as handle:
    for lineno, raw in enumerate(handle, start=1):
        if not raw.strip():
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(f"FAIL {ledger_path}:{lineno}: invalid JSON: {exc}", file=sys.stderr)
            raise SystemExit(1)
        reason = line_error(record)
        if reason is not None:
            print(f"FAIL {ledger_path}:{lineno}: {reason}", file=sys.stderr)
            raise SystemExit(1)
        count += 1

print(f"PASS {ledger_path}: {count} fact{'' if count == 1 else 's'}")
PY
