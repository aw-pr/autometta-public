#!/usr/bin/env python3
"""Pending escalation count for the TUI's escalations panel."""
import os
import subprocess

_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "escalations.sh")


def read_pending_count():
    """Return how many escalations await the operator, or None if unreadable."""
    try:
        result = subprocess.run(
            [_SCRIPT, "list"], check=True, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return len([line for line in result.stdout.splitlines() if line.strip()])
