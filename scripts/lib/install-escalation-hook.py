#!/usr/bin/env python3
"""Install change-only escalation delivery for Claude Code and Codex."""

import argparse
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile


MARKER = "hooks/session-start-escalations.sh"
EVENTS = ("SessionStart", "UserPromptSubmit", "PostToolUse")


def expected_settings(current, script, family):
    result = copy.deepcopy(current)
    hooks = result.setdefault("hooks", {})
    for event, groups in list(hooks.items()):
        kept = []
        for group in groups:
            original = group.get("hooks", [])
            remaining = [item for item in original if MARKER not in item.get("command", "")]
            if len(remaining) == len(original):
                kept.append(group)
            elif remaining:
                kept.append(dict(group, hooks=remaining))
        hooks[event] = kept
    command = f"{shlex.quote(str(script))} --live {family}"
    for event in EVENTS:
        hooks.setdefault(event, []).append({"hooks": [{
            "type": "command", "command": command, "timeout": 8,
        }]})
    result["hooks"] = dict(sorted(hooks.items()))
    return result


def install(path, script, family, check):
    current = json.loads(path.read_text()) if path.exists() else {}
    expected = expected_settings(current, script, family)
    if current == expected:
        print(f"installed: {family} escalation hooks in {path}")
        return True
    if check:
        print(f"missing or stale: {family} escalation hooks in {path}")
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".escalation-hooks-")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(expected, output, indent=2)
            output.write("\n")
        if path.exists():
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            shutil.copy2(path, str(path) + ".bak-" + stamp)
            os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"installed: {family} escalation hooks in {path}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--family", choices=("claude", "codex", "all"), default="claude")
    parser.add_argument("--settings", type=Path)
    args = parser.parse_args()
    if args.settings and args.family == "all":
        parser.error("--settings requires one family")
    script = Path(__file__).resolve().parents[1] / "hooks/session-start-escalations.sh"
    if not os.access(script, os.X_OK):
        parser.error("escalation reader is missing or not executable")
    families = ("claude", "codex") if args.family == "all" else (args.family,)
    paths = {
        "claude": Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "settings.json",
        "codex": Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "hooks.json",
    }
    ok = True
    for family in families:
        ok = install(args.settings or paths[family], script, family, args.check) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print(f"install-escalation-hook: {error}", file=sys.stderr)
        sys.exit(1)
