#!/usr/bin/env bash
# Install or check advisory escalation hooks without replacing unrelated hooks.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/lib/install-escalation-hook.py" "$@"
