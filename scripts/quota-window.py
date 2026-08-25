#!/usr/bin/env python3
"""Read provider window utilisation without owning provider credentials."""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_STALE_SECONDS = 600
MAX_CODEX_FILES = 20
TAIL_BYTES = 262_144


def now_epoch() -> float:
    value = os.environ.get("AI_QUOTA_NOW_EPOCH")
    return float(value) if value else datetime.now(timezone.utc).timestamp()


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def unknown(family: str, reason: str) -> dict[str, Any]:
    return {
        "family": family,
        "status": "unknown",
        "reason": reason,
        "source": None,
        "fetched_at": None,
        "windows": [],
    }


def sanitise_windows(value: Any) -> list[dict[str, Any]] | None:
    if not isinstance(value, list) or not value:
        return None
    result = []
    for entry in value:
        if not isinstance(entry, dict):
            return None
        key = entry.get("key")
        label = entry.get("label")
        utilisation = entry.get("utilization")
        reset_epoch = parse_time(entry.get("resets_at"))
        if (
            not isinstance(key, str)
            or not key
            or not isinstance(label, str)
            or not label
            or not isinstance(utilisation, (int, float))
            or isinstance(utilisation, bool)
            or not 0 <= float(utilisation) <= 100
        ):
            return None
        result.append(
            {
                "key": key,
                "label": label,
                "utilization": float(utilisation),
                "resets_at": iso(reset_epoch) if reset_epoch is not None else None,
            }
        )
    return result


def read_claude() -> dict[str, Any]:
    quota_dir = Path(
        os.path.expanduser(os.environ.get("AI_QUOTA_DIR", "~/.local/state/ai-quota"))
    )
    snapshot = quota_dir / "claude.json"
    if not snapshot.is_file():
        return unknown("claude", "snapshot absent")
    try:
        payload = json.loads(snapshot.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return unknown("claude", "snapshot malformed")
    if not isinstance(payload, dict):
        return unknown("claude", "snapshot malformed")
    fetched_epoch = parse_time(payload.get("fetched_at"))
    source = payload.get("source")
    windows = sanitise_windows(payload.get("windows"))
    if fetched_epoch is None or not isinstance(source, str) or not source or windows is None:
        return unknown("claude", "snapshot malformed")
    try:
        stale_seconds = int(os.environ.get("AI_QUOTA_STALE_SECONDS", DEFAULT_STALE_SECONDS))
    except ValueError:
        stale_seconds = DEFAULT_STALE_SECONDS
    age = max(0, int(now_epoch() - fetched_epoch))
    if age > max(0, stale_seconds):
        return unknown("claude", f"snapshot stale ({age}s old, limit {max(0, stale_seconds)}s)")
    return {
        "family": "claude",
        "status": "known",
        "reason": None,
        "source": source,
        "fetched_at": iso(fetched_epoch),
        "windows": windows,
    }


def find_rate_limits(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    limits = value.get("rate_limits")
    if isinstance(limits, dict):
        return limits
    for nested in value.values():
        found = find_rate_limits(nested)
        if found is not None:
            return found
    return None


def codex_label(minutes: int | None) -> str:
    if minutes == 300:
        return "5-hour"
    if minutes == 10080:
        return "Weekly"
    if minutes is None:
        return "Window"
    if minutes % 60 == 0:
        return f"{minutes // 60}-hour"
    return f"{minutes}-min"


def codex_snapshot(line: str) -> dict[str, Any] | None:
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return None
    limits = find_rate_limits(event)
    if limits is None:
        return None
    windows = []
    for key in ("primary", "secondary"):
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        used = window.get("used_percent")
        if not isinstance(used, (int, float)) or isinstance(used, bool):
            continue
        minutes_value = window.get("window_minutes")
        minutes = int(minutes_value) if isinstance(minutes_value, (int, float)) else None
        reset_epoch = parse_time(window.get("resets_at"))
        windows.append(
            {
                "key": key,
                "label": codex_label(minutes),
                "utilization": float(used),
                "resets_at": iso(reset_epoch) if reset_epoch is not None else None,
            }
        )
    windows = sanitise_windows(windows)
    if windows is None:
        return None
    fetched_epoch = parse_time(event.get("timestamp"))
    return {
        "family": "codex",
        "status": "known",
        "reason": None,
        "source": "codex-rollout-log",
        "fetched_at": iso(fetched_epoch if fetched_epoch is not None else now_epoch()),
        "windows": windows,
    }


def read_codex() -> dict[str, Any]:
    sessions_root = Path(
        os.path.expanduser(os.environ.get("AUTOMETTA_CODEX_SESSIONS", "~/.codex/sessions"))
    )
    if not sessions_root.is_dir():
        return unknown("codex", "rollout directory absent")
    try:
        files = sorted(
            sessions_root.rglob("rollout-*.jsonl"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )[:MAX_CODEX_FILES]
    except OSError:
        return unknown("codex", "rollout directory unreadable")
    if not files:
        return unknown("codex", "no rollout files")
    for path in files:
        try:
            with path.open("rb") as handle:
                handle.seek(0, 2)
                size = handle.tell()
                handle.seek(max(0, size - TAIL_BYTES))
                text = handle.read().decode("utf-8", errors="ignore")
        except OSError:
            continue
        for line in reversed(text.splitlines()):
            if '"rate_limits"' not in line:
                continue
            reading = codex_snapshot(line)
            if reading is not None:
                return reading
    return unknown("codex", f"no rate_limits event in newest {MAX_CODEX_FILES} rollout files")


def read_family(family: str) -> dict[str, Any]:
    if family == "claude":
        return read_claude()
    if family == "codex":
        return read_codex()
    return unknown(family, "unsupported family")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"claude", "codex", "all"}:
        print(f"usage: {Path(sys.argv[0]).name} claude|codex|all", file=sys.stderr)
        return 2
    if sys.argv[1] == "all":
        result = {
            "read_at": iso(now_epoch()),
            "families": {family: read_family(family) for family in ("claude", "codex")},
        }
    else:
        result = read_family(sys.argv[1])
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
