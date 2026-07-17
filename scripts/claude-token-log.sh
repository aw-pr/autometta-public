#!/usr/bin/env bash
# claude-token-log.sh — stdout filter for `claude -p --output-format json`.
#
# `claude -p` prints no token-usage line in text mode, so Claude-family
# dispatches recorded zero tokens against the budget (the parser greps for
# "Total tokens:", see budget_parse_tokens_from_log). Spawn scripts now
# request JSON output and pipe it through this filter, which restores a
# human-readable log: the result text, then a "Total tokens: N" line in
# exactly the format the parser expects.
#
# Non-JSON input (CLI errors, auth prompts, partial output) passes through
# byte-for-byte so a failure message is never swallowed.
#
# The program is passed with -c, not a heredoc: a heredoc would replace
# stdin and swallow the piped claude output.
set -euo pipefail

exec python3 -c '
import json
import sys

raw = sys.stdin.read()
try:
    doc = json.loads(raw)
except ValueError:
    sys.stdout.write(raw)
    sys.exit(0)

if not isinstance(doc, dict):
    sys.stdout.write(raw)
    sys.exit(0)

result = doc.get("result")
if isinstance(result, str) and result:
    sys.stdout.write(result.rstrip("\n") + "\n")
else:
    sys.stdout.write(raw.rstrip("\n") + "\n")

usage = doc.get("usage") or {}
total = 0
for key in (
    "input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "output_tokens",
):
    value = usage.get(key)
    if isinstance(value, int) and value > 0:
        total += value

if total > 0:
    sys.stdout.write("Total tokens: %d\n" % total)
'
