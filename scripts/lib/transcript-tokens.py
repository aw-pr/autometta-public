#!/usr/bin/env python3
"""transcript-tokens.py: enrich data.json agents[] from live transcripts.

Ported from scripts/agent-ticker.sh's ACTIVE panel (card 44) so
aggregate-dashboard.sh's --repo mode can offer the same figure through the
one aggregated-JSON seam scripts/repo-ticker.sh reads, rather than the
renderer re-parsing transcripts itself (card 63 acceptance criterion 9).

Usage: transcript-tokens.py <active_agents_dir> <claude_projects_root> <codex_sessions_root>
Reads a JSON array of agent objects (pid, family, working_dir, started_at
required) on stdin, writes the same array back on stdout with
`stage_tokens` (int or null), `stage_tokens_status`
("counted"|"waiting"|"unavailable") and `activity` added to each entry.

Offsets are cached in <active_agents_dir>/<pid>.json (the same registry
file scripts/register-agent.sh and scripts/heartbeat.sh use), so repeated
calls only read the bytes appended since the last one.
"""
import calendar
import glob
import json
import os
import re
import sys


def epoch(ts):
    try:
        return calendar.timegm(__import__("datetime").datetime.strptime(
            ts, "%Y-%m-%dT%H:%M:%SZ").timetuple())
    except Exception:
        return 0


def registry_path(active_dir, pid):
    return os.path.join(active_dir, "%s.json" % pid)


def load_registry(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_registry(path, reg):
    try:
        tmp = path + ".ticker-tmp"
        with open(tmp, "w") as fh:
            json.dump(reg, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except OSError:
        pass


def resolve_transcript(agent, reg, claude_root, codex_root):
    cached = reg.get("transcript_path")
    if cached and os.path.isfile(cached):
        return cached
    cwd = agent.get("working_dir")
    if not cwd:
        return None
    started = epoch(agent.get("started_at") or "")
    family = agent.get("family")
    candidates = []
    if family == "claude":
        slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
        candidates = glob.glob(os.path.join(claude_root, slug, "*.jsonl"))
    elif family == "codex":
        paths = glob.glob(os.path.join(codex_root, "*", "*", "*", "rollout-*.jsonl"))
        paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
        for path in paths[:200]:
            try:
                if os.path.getmtime(path) < started - 120:
                    continue
                with open(path, errors="replace") as fh:
                    meta = json.loads(fh.readline()).get("payload") or {}
                if meta.get("cwd") == cwd:
                    candidates.append(path)
            except Exception:
                pass
    candidates = [p for p in candidates if os.path.getmtime(p) >= started - 120]
    if candidates:
        return max(candidates, key=os.path.getmtime)
    return None


def first_line(value):
    if not isinstance(value, str):
        return None
    line = value.splitlines()[0].strip() if value.splitlines() else ""
    return line or None


def command_value(value):
    if isinstance(value, dict):
        for key in ("command", "cmd"):
            if key in value:
                found = command_value(value[key])
                if found:
                    return found
        for key in ("input", "arguments"):
            if key in value:
                found = command_value(value[key])
                if found:
                    return found
        return None
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, (str, int, float)):
                parts.append(str(item))
            else:
                found = command_value(item)
                if found:
                    parts.append(found)
        return " ".join(parts).strip() or None
    if not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None
    try:
        decoded = json.loads(raw)
    except (TypeError, ValueError):
        decoded = None
    if isinstance(decoded, (dict, list)):
        found = command_value(decoded)
        if found:
            return found
    match = re.search(r'"(?:command|cmd)"\s*:\s*("(?:\\.|[^"\\])*")', raw)
    if match:
        try:
            return first_line(json.loads(match.group(1)))
        except (TypeError, ValueError):
            pass
    return None


def fallback_detail(value):
    if isinstance(value, str):
        text = first_line(value)
    else:
        try:
            text = json.dumps(value, separators=(",", ":"), sort_keys=True)
        except (TypeError, ValueError):
            text = None
    return text[:80] if text else None


def claude_tool_detail(block):
    inputs = block.get("input") or {}
    if block.get("name") == "Bash":
        return first_line(inputs.get("command"))
    return first_line(inputs.get("file_path"))


def codex_tool_detail(item):
    source = item.get("input")
    if source is None:
        source = item.get("arguments")
    return command_value(source) or fallback_detail(source)


def cached_claude_activity(reg):
    if not reg.get("transcript_activity_found"):
        return None
    return {
        "turns": int(reg.get("transcript_activity_turns") or 0),
        "tool_calls": int(reg.get("transcript_activity_tool_calls") or 0),
        "last_tool": reg.get("transcript_activity_last_tool"),
        "last_detail": reg.get("transcript_activity_last_detail"),
        "last_at": reg.get("transcript_activity_last_at"),
    }


def transcript_metrics(path, family, reg):
    if not path:
        return None, None
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            if family == "claude":
                if reg.get("transcript_path") != path:
                    reg["transcript_path"] = path
                    reg["transcript_offset"] = 0
                    reg["transcript_tokens"] = 0
                    reg["transcript_tokens_found"] = False
                    reg["transcript_activity_turns"] = 0
                    reg["transcript_activity_tool_calls"] = 0
                    reg["transcript_activity_found"] = False
                    for key in ("last_tool", "last_detail", "last_at"):
                        reg.pop("transcript_activity_" + key, None)
                offset = min(int(reg.get("transcript_offset") or 0), size)
                total = int(reg.get("transcript_tokens") or 0)
                previously_found = bool(reg.get("transcript_tokens_found"))
                fh.seek(offset)
                chunk = fh.read(16 * 1024 * 1024)
                cut = chunk.rfind(b"\n")
                if cut < 0:
                    tokens = total if previously_found else None
                    activity = cached_claude_activity(reg)
                    reg["activity"] = activity
                    return tokens, activity
                consumed = chunk[:cut + 1]
                data = consumed.decode("utf-8", "replace")
                reg["transcript_offset"] = offset + len(consumed)
            else:
                fh.seek(max(0, size - 16 * 1024 * 1024))
                data = fh.read().decode("utf-8", "replace")
                if size > 16 * 1024 * 1024:
                    data = data.split("\n", 1)[-1]
                total = 0
                previously_found = False
    except OSError:
        return None, None
    found = False
    if family == "claude":
        turns = int(reg.get("transcript_activity_turns") or 0)
        tool_calls = int(reg.get("transcript_activity_tool_calls") or 0)
        activity_found = bool(reg.get("transcript_activity_found"))
        last_tool = reg.get("transcript_activity_last_tool")
        last_detail = reg.get("transcript_activity_last_detail")
        last_at = reg.get("transcript_activity_last_at")
    else:
        turns = 0
        tool_calls = 0
        activity_found = False
        last_tool = None
        last_detail = None
        last_at = None
    for line in data.splitlines():
        try:
            doc = json.loads(line)
        except ValueError:
            continue
        if family == "codex":
            info = doc.get("payload") or doc
            usage = info.get("total_token_usage") or (info.get("info") or {}).get("total_token_usage")
            if isinstance(usage, dict) and isinstance(usage.get("total_tokens"), int):
                total = max(total, usage["total_tokens"])
                found = True
            if doc.get("type") == "event_msg" and info.get("type") == "token_count":
                turns += 1
                activity_found = True
            if doc.get("type") == "response_item" and info.get("type") in (
                    "custom_tool_call", "function_call"):
                tool_calls += 1
                activity_found = True
                last_tool = info.get("name") or None
                last_detail = codex_tool_detail(info)
                last_at = doc.get("timestamp") or None
        else:
            usage = (doc.get("message") or {}).get("usage") or doc.get("usage")
            if isinstance(usage, dict):
                values = [usage.get(k) for k in (
                    "input_tokens", "output_tokens",
                    "cache_creation_input_tokens", "cache_read_input_tokens")]
                if any(isinstance(v, int) for v in values):
                    total += sum(v for v in values if isinstance(v, int))
                    found = True
            if doc.get("type") == "assistant":
                turns += 1
                activity_found = True
                content = (doc.get("message") or {}).get("content") or []
                for block in content:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    tool_calls += 1
                    last_tool = block.get("name") or None
                    last_detail = claude_tool_detail(block)
                    last_at = doc.get("timestamp") or None
    if family == "claude":
        reg["transcript_tokens"] = total
        reg["transcript_tokens_found"] = found or previously_found
        reg["transcript_activity_turns"] = turns
        reg["transcript_activity_tool_calls"] = tool_calls
        reg["transcript_activity_found"] = activity_found
        reg["transcript_activity_last_tool"] = last_tool
        reg["transcript_activity_last_detail"] = last_detail
        reg["transcript_activity_last_at"] = last_at
    activity = None
    if activity_found:
        activity = {
            "turns": turns,
            "tool_calls": tool_calls,
            "last_tool": last_tool,
            "last_detail": last_detail,
            "last_at": last_at,
        }
    reg["activity"] = activity
    tokens = total if (found or (family == "claude" and previously_found)) else None
    return tokens, activity


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: %s <active_agents_dir> <claude_root> <codex_root>\n" % sys.argv[0])
        return 2
    active_dir, claude_root, codex_root = sys.argv[1:]
    agents = json.load(sys.stdin)
    out = []
    for agent in agents:
        pid = agent.get("pid")
        family = agent.get("family")
        reg_path = registry_path(active_dir, pid)
        reg = load_registry(reg_path)
        path = resolve_transcript(agent, reg, claude_root, codex_root)
        tokens, activity = transcript_metrics(path, family, reg) if path else (None, None)
        if path:
            save_registry(reg_path, reg)
        elapsed = int(agent.get("elapsed_seconds") or 0)
        if tokens is not None:
            status = "counted"
        elif elapsed < 120:
            status = "waiting"
        else:
            status = "unavailable"
        agent["stage_tokens"] = tokens
        agent["stage_tokens_status"] = status
        agent["activity"] = activity
        out.append(agent)
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
