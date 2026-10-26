#!/usr/bin/env python3
"""Read provider window utilisation without owning provider credentials."""

from __future__ import annotations

import json
import math
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


def sanitise_windows(value: Any, *, allow_overage: bool = False) -> list[dict[str, Any]] | None:
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
            or not math.isfinite(float(utilisation))
            or float(utilisation) < 0
            or (not allow_overage and float(utilisation) > 100)
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


def read_snapshot(family: str) -> dict[str, Any]:
    quota_dir = Path(
        os.path.expanduser(os.environ.get("AI_QUOTA_DIR", "~/.local/state/ai-quota"))
    )
    snapshot = quota_dir / f"{family}.json"
    if not snapshot.is_file():
        return unknown(family, "snapshot absent")
    try:
        payload = json.loads(snapshot.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return unknown(family, "snapshot malformed")
    if not isinstance(payload, dict):
        return unknown(family, "snapshot malformed")
    fetched_epoch = parse_time(payload.get("fetched_at"))
    source = payload.get("source")
    windows = sanitise_windows(payload.get("windows"), allow_overage=family == "codex")
    if fetched_epoch is None or not isinstance(source, str) or not source or windows is None:
        return unknown(family, "snapshot malformed")
    try:
        stale_seconds = int(os.environ.get("AI_QUOTA_STALE_SECONDS", DEFAULT_STALE_SECONDS))
    except ValueError:
        stale_seconds = DEFAULT_STALE_SECONDS
    age = max(0, int(now_epoch() - fetched_epoch))
    if age > max(0, stale_seconds):
        return unknown(family, f"snapshot stale ({age}s old, limit {max(0, stale_seconds)}s)")
    return {
        "family": family,
        "status": "known",
        "reason": None,
        "source": source,
        "fetched_at": iso(fetched_epoch),
        "windows": windows,
    }


def read_claude() -> dict[str, Any]:
    return read_snapshot("claude")

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
    windows = sanitise_windows(windows, allow_overage=True)
    if windows is None:
        return None
    fetched_epoch = parse_time(event.get("timestamp"))
    return {
        "family": "codex",
        "status": "known",
        "reason": None,
        "source": "codex-rollout-log",
        "fetched_at": iso(fetched_epoch) if fetched_epoch is not None else None,
        "windows": windows,
    }


def read_codex_rollout() -> dict[str, Any]:
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


def read_codex() -> dict[str, Any]:
    rollout = read_codex_rollout()
    snapshot = read_snapshot("codex")
    candidates = [value for value in (rollout, snapshot) if value.get("status") == "known"]
    if not candidates:
        return rollout
    return max(candidates, key=lambda value: parse_time(value.get("fetched_at")) or 0)


def codex_admission(reading: Any) -> dict[str, Any]:
    result = {"allowed": False, "reason": "Codex quota reading unavailable", "window": "", "reset": None}
    if codex_admission_off():
        return {**result, "allowed": True,
                "reason": "Codex admission ceiling off by operator; new cards may run into reserve credits"}
    if not isinstance(reading, dict) or reading.get("status") != "known":
        return result
    now = now_epoch()
    fetched = parse_time(reading.get("fetched_at"))
    try:
        max_age = max(0, int(os.environ.get("AI_QUOTA_STALE_SECONDS", DEFAULT_STALE_SECONDS)))
    except ValueError:
        max_age = DEFAULT_STALE_SECONDS
    if fetched is None or fetched > now + 60 or now - fetched > max_age:
        return {**result, "reason": "Codex quota reading stale or undated"}
    windows = sanitise_windows(reading.get("windows"), allow_overage=True)
    # Plus reports a five-hour and a weekly window; Pro reports the weekly one alone.
    if not windows or not any(is_weekly(w) for w in windows):
        return {**result, "reason": "Codex quota windows incomplete"}
    for window in windows:
        reset = parse_time(window["resets_at"])
        if reset is None or reset <= now:
            return {**result, "reason": "Codex quota needs a fresh reading after reset", "window": window["label"]}
        ceiling = codex_window_ceiling(window, reset, now)
        if window["utilization"] >= ceiling:
            state = "exhausted" if ceiling >= 100 else f"at or past the {ceiling:g}% admission ceiling"
            return {**result, "reason": f"Codex {window['label']} {state} ({window['utilization']:g}% used)",
                    "window": window["label"], "reset": int(reset)}
    return {**result, "allowed": True, "reason": f"Codex quota below {ceiling:g}%; current card may finish in overage"}


def codex_admission_off() -> bool:
    """`off` is the operator's explicit decision to spend past the subscription
    window into reserve credits, so no reading, stale or exhausted, holds a card."""
    return os.environ.get("AUTOMETTA_CODEX_ADMIT_PERCENT", "").strip().lower() == "off"


WEEK_SECONDS = 7 * 24 * 3600


def is_weekly(window: dict[str, Any]) -> bool:
    return str(window.get("label", "")).strip().lower() == "weekly"


def codex_pace_headroom() -> float | None:
    """`pace` paces the weekly window by the share of the week gone, plus one
    day's share by default (`pace+N` sets N points instead); None when not pacing."""
    value = os.environ.get("AUTOMETTA_CODEX_ADMIT_PERCENT", "").strip().lower()
    if value == "pace":
        return 100 / 7
    if value.startswith("pace+"):
        try:
            headroom = float(value[5:])
        except ValueError:
            return 100 / 7
        return headroom if 0 <= headroom <= 100 else 100 / 7
    return None


def codex_window_ceiling(window: dict[str, Any], reset: float, now: float) -> float:
    """A paced weekly window admits up to the share of the week already gone plus
    the headroom, so a week cannot be spent in a day; any other window keeps the
    fixed ceiling, which pacing leaves at 100."""
    headroom = codex_pace_headroom()
    if headroom is None:
        return codex_admit_percent()
    if not is_weekly(window):
        return 100.0
    elapsed = min(1.0, max(0.0, 1 - (reset - now) / WEEK_SECONDS))
    return min(100.0, elapsed * 100 + headroom)


def codex_admit_percent() -> float:
    """Used percentage at which no new Codex card is admitted. Out-of-range or
    unparseable values fall back to 100 rather than to a stricter guess."""
    try:
        value = float(os.environ.get("AUTOMETTA_CODEX_ADMIT_PERCENT", "100"))
    except ValueError:
        return 100.0
    return value if 0 < value <= 100 else 100.0


def pace_action() -> str:
    value = os.environ.get("AUTOMETTA_PACE_ACTION", "").strip().lower()
    return value if value in {"hold", "observe"} else "off"


def pace_slot_seconds() -> int:
    """Length of one pacing slot. Twelve hours unless a whole number of hours
    between 1 and 168 is given."""
    try:
        hours = int(os.environ.get("AUTOMETTA_PACE_SLOT_HOURS", "12"))
    except ValueError:
        hours = 12
    return (hours if 1 <= hours <= 168 else 12) * 3600


def weekly_window(reading: Any) -> dict[str, Any] | None:
    if not isinstance(reading, dict) or reading.get("status") != "known":
        return None
    windows = sanitise_windows(reading.get("windows"), allow_overage=True) or []
    return next((window for window in windows if is_weekly(window)), None)


def pace_state_path() -> Path | None:
    value = os.environ.get("AUTOMETTA_PACE_STATE", "")
    return Path(os.path.expanduser(value)) if value else None


def pace_slot_base(family: str, week_reset: str, slot: int, candidate: float) -> float:
    """The utilisation a slot is measured from: the first one this host saw in
    the slot, so spend inside the slot cannot raise its own ceiling. Without a
    state file every call is a first sighting."""
    path = pace_state_path()
    if path is None:
        return candidate
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(state, dict):
            state = {}
    except (OSError, UnicodeError, json.JSONDecodeError):
        state = {}
    entry = state.get(family)
    if (
        isinstance(entry, dict)
        and entry.get("week_resets_at") == week_reset
        and entry.get("slot") == slot
        and isinstance(entry.get("base"), (int, float))
    ):
        return float(entry["base"])
    state[family] = {"week_resets_at": week_reset, "slot": slot, "base": candidate}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
        tmp.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(path)
    except OSError:
        pass
    return candidate


def pace_admission(family: str, reading: Any) -> dict[str, Any]:
    """Spread a weekly window evenly over what is left of the week.

    The week is cut into slots (half-days by default). A slot may spend the
    remaining headroom divided by the slots left, measured from the slot's
    base. The base is never above the straight pace line, so a family that ran
    ahead is held until the calendar catches up, and one that fell behind may
    catch up only a slot's share at a time. A stale reading still counts:
    weekly use only rises until reset, so an old figure understates it."""
    result: dict[str, Any] = {"family": family, "allowed": True, "action": pace_action(),
                              "used": None, "ceiling": None, "allowance": None,
                              "slot_ends_at": None, "week_resets_at": None}
    if result["action"] == "off":
        return {**result, "reason": "pace off"}
    window = weekly_window(reading)
    if window is None:
        return {**result, "reason": f"{family} weekly reading unavailable; pace not applied"}
    now = now_epoch()
    reset = parse_time(window["resets_at"])
    if reset is None or reset <= now:
        return {**result, "reason": f"{family} weekly window has reset; pace waits for a fresh reading"}
    slot_seconds = pace_slot_seconds()
    slots = math.ceil(WEEK_SECONDS / slot_seconds)
    start = reset - WEEK_SECONDS
    slot = min(slots - 1, max(0, int((now - start) // slot_seconds)))
    slots_left = slots - slot
    used = window["utilization"]
    base = pace_slot_base(family, window["resets_at"], slot, min(used, 100.0 * slot / slots))
    allowance = max(0.0, 100.0 - base) / slots_left
    ceiling = base + allowance
    slot_end = min(reset, start + (slot + 1) * slot_seconds)
    result.update({"used": used, "ceiling": round(ceiling, 2), "allowance": round(allowance, 2),
                   "slot_ends_at": iso(slot_end), "week_resets_at": window["resets_at"]})
    if used < ceiling:
        return {**result, "reason": f"{family} weekly {used:g}% used, under this slot's {ceiling:.1f}% pace ceiling"}
    reason = (f"{family} weekly {used:g}% used, at or past this slot's {ceiling:.1f}% pace ceiling "
              f"({allowance:.1f}% per slot over {slots_left} slots left); next slot {iso(slot_end)}")
    if result["action"] == "observe":
        return {**result, "reason": f"{reason}; observe does not hold"}
    return {**result, "allowed": False, "reason": reason}


def read_family(family: str) -> dict[str, Any]:
    if family == "claude":
        return read_claude()
    if family == "codex":
        return read_codex()
    return unknown(family, "unsupported family")


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "pace" and sys.argv[2] in {"claude", "codex"}:
        try:
            reading = json.load(sys.stdin)
        except (ValueError, OSError):
            reading = None
        print(json.dumps(pace_admission(sys.argv[2], reading), separators=(",", ":"), sort_keys=True))
        return 0
    if len(sys.argv) != 2 or sys.argv[1] not in {"claude", "codex", "all", "codex-admission"}:
        print(f"usage: {Path(sys.argv[0]).name} claude|codex|all|codex-admission|pace claude|codex", file=sys.stderr)
        return 2
    if sys.argv[1] == "codex-admission":
        try:
            reading = json.load(sys.stdin)
        except (ValueError, OSError):
            reading = None
        result = codex_admission(reading)
    elif sys.argv[1] == "all":
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
