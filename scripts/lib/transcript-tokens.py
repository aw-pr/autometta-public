#!/usr/bin/env python3
"""transcript-tokens.py: enrich a data.json agents[] array with a live,
incrementally-read transcript token total per agent.

Ported from scripts/agent-ticker.sh's ACTIVE panel (card 44) so
aggregate-dashboard.sh's --repo mode can offer the same figure through the
one aggregated-JSON seam scripts/repo-ticker.sh reads, rather than the
renderer re-parsing transcripts itself (card 63 acceptance criterion 9).

Usage: transcript-tokens.py <active_agents_dir> <claude_projects_root> <codex_sessions_root>
Reads a JSON array of agent objects (pid, family, working_dir, started_at
required) on stdin, writes the same array back on stdout with
`stage_tokens` (int or null) and `stage_tokens_status`
("counted"|"waiting"|"unavailable") added to each entry.

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
        reg["transcript_path"] = max(candidates, key=os.path.getmtime)
        return reg["transcript_path"]
    return None


def transcript_tokens(path, family, reg):
    if not path:
        return None
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
                offset = min(int(reg.get("transcript_offset") or 0), size)
                total = int(reg.get("transcript_tokens") or 0)
                previously_found = bool(reg.get("transcript_tokens_found"))
                fh.seek(offset)
                chunk = fh.read(16 * 1024 * 1024)
                cut = chunk.rfind(b"\n")
                if cut < 0:
                    return total if previously_found else None
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
        return None
    found = False
    for line in data.splitlines():
        if '"usage"' not in line and '"total_token_usage"' not in line:
            continue
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
        else:
            usage = (doc.get("message") or {}).get("usage") or doc.get("usage")
            if isinstance(usage, dict):
                values = [usage.get(k) for k in (
                    "input_tokens", "output_tokens",
                    "cache_creation_input_tokens", "cache_read_input_tokens")]
                if any(isinstance(v, int) for v in values):
                    total += sum(v for v in values if isinstance(v, int))
                    found = True
    if family == "claude":
        reg["transcript_tokens"] = total
        reg["transcript_tokens_found"] = found or previously_found
        return total if reg["transcript_tokens_found"] else None
    return total if found else None


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
        tokens = transcript_tokens(path, family, reg) if path else None
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
        out.append(agent)
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
