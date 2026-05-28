#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
schema_path="$repo_root/schemas/verifier.json"

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=("$repo_root"/state/verifiers/*.json)
fi

python3 - "$schema_path" "${files[@]}" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import sys

try:
    from jsonschema import Draft202012Validator
except ImportError:
    print(
        "FAIL: missing jsonschema; install with: python3 -m pip install -r scripts/requirements-sdk.txt",
        file=sys.stderr,
    )
    raise SystemExit(2)

schema_path = Path(sys.argv[1])
paths = [Path(item) for item in sys.argv[2:]]

schema = json.loads(schema_path.read_text(encoding="utf-8"))
validator = Draft202012Validator(schema)
failed = False

for path in paths:
    if not path.exists():
        print(f"FAIL {path}: file not found")
        failed = True
        continue
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"FAIL {path}: invalid JSON: {exc}")
        failed = True
        continue

    errors = sorted(validator.iter_errors(data), key=lambda err: list(err.path))
    if errors:
        err = errors[0]
        where = ".".join(str(part) for part in err.path) or "<root>"
        print(f"FAIL {path}: {where}: {err.message}")
        failed = True
    else:
        print(f"PASS {path}")

raise SystemExit(1 if failed else 0)
PY
