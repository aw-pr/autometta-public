#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=regression suite; no stage card freezes it
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/lib/test_wakeups.py"
