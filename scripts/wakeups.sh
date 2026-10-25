#!/usr/bin/env bash
exec python3 "$(dirname "${BASH_SOURCE[0]}")/lib/wakeups.py" "$@"
