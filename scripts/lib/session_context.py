"""Identify interactive primary chats before delivering operator context."""

import os
from pathlib import Path
import shlex
import stat
import subprocess


def headless_command(command):
    words = shlex.split(command)
    for index, word in enumerate(words):
        name = Path(word).name
        if name in ("codex", "codex.exe", "codex.js"):
            return "exec" in words[index + 1:index + 3]
        if name in ("claude", "claude.exe") or "/claude/versions/" in word:
            return any(w in ("-p", "--print") for w in words[index + 1:])
    return False


def ancestors():
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1:
            break
        result = subprocess.run(["ps", "-ww", "-p", str(pid), "-o", "ppid=", "-o", "args="],
                                capture_output=True, text=True, timeout=1, check=True)
        parent, command = result.stdout.strip().split(None, 1)
        yield pid, command
        pid = int(parent)


def headless_ancestor():
    return any(headless_command(command) for _, command in ancestors())


def interactive(payload):
    return (bool(payload.get("session_id")) and not payload.get("agent_id")
            and not payload.get("agent_type") and payload.get("source") != "fork"
            and os.environ.get("AUTOMETTA_ESCALATION_HOOK") != "0"
            and not headless_ancestor())


def codex_socket():
    """Find the control socket of the ancestor that actually owns this chat."""
    for pid, command in ancestors():
        words = shlex.split(command)
        if not words or Path(words[0]).name not in ("codex", "codex.exe") or "app-server" not in words:
            continue
        result = subprocess.run(["lsof", "-a", "-p", str(pid), "-U", "-Fn"],
                                capture_output=True, text=True, timeout=3, check=True)
        sockets = set()
        for line in result.stdout.splitlines():
            if not line.startswith("n/"):
                continue
            path = Path(line[1:])
            try:
                if stat.S_ISSOCK(path.stat().st_mode):
                    sockets.add(str(path))
            except OSError:
                continue
        if len(sockets) == 1:
            return sockets.pop(), pid
        raise ValueError("owning Codex server has no unambiguous local control socket")
    raise ValueError("no owning Codex app-server ancestor")
