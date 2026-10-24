"""Read-only subscription observations. Account movement is never card spend."""

import importlib.util
import json
import os
from pathlib import Path
import sys


def quota_reader():
    path = Path(__file__).resolve().parents[1] / "quota-window.py"
    spec = importlib.util.spec_from_file_location("quota_window", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def current_reading(family):
    q = quota_reader()
    reading = q.read_family(family)
    fetched = q.parse_time(reading.get("fetched_at"))
    try:
        max_age = max(0, int(os.environ.get("AI_QUOTA_STALE_SECONDS", q.DEFAULT_STALE_SECONDS)))
    except ValueError:
        max_age = q.DEFAULT_STALE_SECONDS
    if reading.get("status") == "known" and (fetched is None or
            q.now_epoch() - fetched > max_age or fetched > q.now_epoch() + 30):
        return {**reading, "status": "unknown", "reason": "reading stale or future-dated"}
    return reading


def movement(start, end):
    result = {"status": "unavailable", "attribution": "shared_account",
              "start": start, "end": end, "windows": []}
    if not start or not end or start.get("status") != "known" or end.get("status") != "known":
        return result
    q = quota_reader()
    first, last = q.parse_time(start.get("fetched_at")), q.parse_time(end.get("fetched_at"))
    if first is None or last is None or last <= first:
        return {**result, "reason": "no newer provider reading"}
    for before in start.get("windows", []):
        after = next((w for w in end.get("windows", []) if w.get("key") == before.get("key")), None)
        reset = q.parse_time(before.get("resets_at"))
        if not after or reset is None or reset <= last or before.get("resets_at") != after.get("resets_at"):
            continue
        a, b = before.get("utilization"), after.get("utilization")
        if isinstance(a, bool) or isinstance(b, bool) or not isinstance(a, (float, int)) or not isinstance(b, (float, int)) or b < a:
            continue
        result["windows"].append({"key": before.get("key"), "label": before.get("label"),
                                  "percentage_points": round(b - a, 3), "resets_at": before["resets_at"]})
    if result["windows"]:
        result["status"] = "observed"
    else:
        result["reason"] = "window reset, decreased or unavailable"
    return result


def capture(registration, repo):
    registration["subscription_start"] = current_reading(registration["family"])
    # The reaper can remove the liveness file before writing the cost log.
    target = Path(repo) / "state" / "usage-starts" / (registration["agent_id"] + ".json")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(registration) + "\n")


def finish(repo, log_path, role, family, since):
    q = quota_reader()
    matches = []
    if since <= 0:
        return {"status": "unavailable", "attribution": "shared_account", "windows": []}
    for path in (Path(repo) / "state" / "usage-starts").glob("*.json"):
        try:
            row = json.loads(path.read_text())
            timestamp = q.parse_time(row.get("started_at"))
            if (row.get("log_path") == log_path and row.get("role") == role
                    and row.get("family") == family and timestamp is not None
                    and abs(timestamp - since) <= 120):
                matches.append((abs(timestamp - since), row))
        except (ValueError, OSError, TypeError):
            continue
    if len(matches) != 1:
        return {"status": "unavailable", "attribution": "shared_account", "windows": []}
    return movement(matches[0][1].get("subscription_start"), current_reading(family))


if __name__ == "__main__":
    print(json.dumps(finish(*sys.argv[1:5], int(sys.argv[5]))))
