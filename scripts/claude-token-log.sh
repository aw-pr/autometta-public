#!/usr/bin/env bash
# claude-token-log.sh — stdout filter for Claude JSON output.
#
# `claude -p` prints no token-usage line in text mode, so Claude-family
# dispatches recorded zero tokens against the budget (the parser greps for
# "Total tokens:", see budget_parse_tokens_from_log). Spawn scripts now
# request stream-json output and pipe it through this filter, which forwards
# useful progress as it arrives and restores a human-readable tail: the result
# text, then a "Total tokens: N" line in exactly the format the parser expects.
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


USAGE_KEYS = (
    "input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "output_tokens",
)


def write_line(text):
    sys.stdout.write(text.rstrip("\n") + "\n")
    sys.stdout.flush()


def first_line(value):
    if not isinstance(value, str):
        return ""
    return value.splitlines()[0][:160] if value else ""


def tool_path(inputs):
    if not isinstance(inputs, dict):
        return ""
    for key in ("file_path", "path", "notebook_path"):
        value = inputs.get(key)
        if isinstance(value, str) and value:
            return first_line(value)
    return ""


def write_assistant_progress(doc):
    message = doc.get("message")
    if not isinstance(message, dict):
        return
    content = message.get("content")
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict):
            continue
        block_type = block.get("type")
        if block_type == "text" and isinstance(block.get("text"), str):
            text = block["text"]
            if text:
                sys.stdout.write(text)
                if not text.endswith("\n"):
                    sys.stdout.write("\n")
                sys.stdout.flush()
        elif block_type == "tool_use":
            name = block.get("name")
            if not isinstance(name, str) or not name:
                name = "tool"
            inputs = block.get("input")
            detail = ""
            if name == "Bash" and isinstance(inputs, dict):
                detail = first_line(inputs.get("command"))
            else:
                detail = tool_path(inputs)
            write_line("%s%s" % (name, ": " + detail if detail else ""))


def write_result(doc):
    result = doc.get("result")
    if isinstance(result, str) and result:
        write_line(result)
    usage = doc.get("usage")
    total = 0
    if isinstance(usage, dict):
        for key in USAGE_KEYS:
            value = usage.get(key)
            if isinstance(value, int) and not isinstance(value, bool):
                total += value
    write_line("Total tokens: %d" % total)


for raw_line in sys.stdin:
    try:
        doc = json.loads(raw_line)
    except ValueError:
        sys.stdout.write(raw_line)
        sys.stdout.flush()
        continue
    if not isinstance(doc, dict):
        sys.stdout.write(raw_line)
        sys.stdout.flush()
        continue
    event_type = doc.get("type")
    if event_type == "assistant":
        write_assistant_progress(doc)
    elif event_type == "result":
        write_result(doc)
'
