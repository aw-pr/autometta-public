#!/usr/bin/env python3
"""Isolated checks of hook delivery, suppression, replay and installation."""

from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
HOOK = SCRIPTS / "hooks/session-start-escalations.sh"
spec = importlib.util.spec_from_file_location("context", SCRIPTS / "hooks/escalation-context.py")
context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(context)


class EscalationContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.pending = self.home / "escalations/pending"
        self.pending.mkdir(parents=True)
        (self.home / "subscribers").mkdir()
        self.repo = self.root / "alpha"
        self.repo.mkdir()
        self.other = self.root / "beta"
        self.other.mkdir()
        for repo in (self.repo, self.other):
            (self.home / "subscribers" / (repo.name + ".yaml")).write_text(
                f'repo_path: "{repo}"\nweight: 1\nenabled: true\n'
            )
        self.env = dict(os.environ, AUTOMETTA_HOME=str(self.home),
                        AUTOMETTA_ESCALATIONS=str(self.pending.parent))
        self.env.pop("AUTOMETTA_ESCALATION_HOOK", None)

    def write(self, name="001", repo=None, summary="needs review"):
        path = self.pending / (name + ".md")
        path.write_text(f'---\nrepo: "{repo or self.repo}"\nstage: "01-test"\nkind: "failed"\n---\n\n{summary}\n')
        return path

    def invoke(self, event="UserPromptSubmit", family="claude", session="session-one", **kwargs):
        payload = dict(session_id=session, hook_event_name=event, cwd=str(self.repo))
        payload.update(kwargs)
        result = subprocess.run([str(HOOK), "--live", family], input=json.dumps(payload),
            env=self.env, text=True, capture_output=True, check=True, timeout=10)
        self.assertEqual(result.stderr, "")
        if not result.stdout:
            return ""
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["hookSpecificOutput"]["hookEventName"], event)
        self.assertNotIn("decision", parsed)
        return parsed["hookSpecificOutput"]["additionalContext"]

    def test_each_family_gets_changes_once_without_acknowledging(self):
        file = self.write()
        for family in ("claude", "codex"):
            self.assertIn("needs review", self.invoke("SessionStart", family))
            self.assertEqual(self.invoke(family=family), "")
        file.write_text(file.read_text() + "changed evidence\n")
        for family in ("claude", "codex"):
            self.assertIn("needs review", self.invoke(family=family))
            self.assertEqual(self.invoke(family=family), "")
        self.assertTrue(file.exists())
        self.assertFalse((self.home / "escalations/processed").exists())

    def test_session_scope_uses_payload_cwd_and_symlinks(self):
        self.write(summary="ALPHA")
        self.write("002", self.other, "BETA")
        self.env["CLAUDE_PROJECT_DIR"] = str(self.other)
        self.assertNotIn("BETA", self.invoke())
        self.assertIn("BETA", self.invoke(cwd=str(self.other)))
        self.assertIn("ALPHA", self.invoke(session="new-session"))
        alias = self.root / "alias"
        alias.symlink_to(self.repo, target_is_directory=True)
        self.assertEqual(self.invoke(cwd=str(alias)), "")

    def test_compaction_rehydrates_but_resume_does_not_repeat(self):
        self.write()
        self.assertTrue(self.invoke("SessionStart", source="startup"))
        self.assertEqual(self.invoke("SessionStart", source="resume"), "")
        self.assertTrue(self.invoke("SessionStart", source="compact"))
        self.assertTrue(self.invoke("SessionStart", source="clear"))

    def test_tool_throttle_does_not_delay_next_user_prompt(self):
        self.assertEqual(self.invoke("PostToolUse"), "")
        self.write()
        self.assertEqual(self.invoke("PostToolUse"), "")
        self.assertTrue(self.invoke())
        self.write("002")
        for path in (self.home / "hook-delivery").glob("*.json"):
            state = json.loads(path.read_text())
            state["checked_at"] -= 16
            path.write_text(json.dumps(state))
        self.assertIn("002.md", self.invoke("PostToolUse"))

    def test_parallel_tools_deliver_once(self):
        self.write()
        with ThreadPoolExecutor(max_workers=4) as pool:
            outputs = list(pool.map(lambda _: self.invoke("PostToolUse"), range(4)))
        self.assertEqual(sum(bool(output) for output in outputs), 1)

    def test_overflow_remains_unseen_and_removed_files_do_not_alert(self):
        for index in range(12):
            self.write(f"{index:03}")
        first = self.invoke()
        self.assertIn("+2 more", first)
        self.assertNotIn("011.md", first)
        second = self.invoke()
        self.assertIn("011.md", second)
        self.assertNotIn("000.md", second)
        self.assertEqual(self.invoke(), "")
        for file in self.pending.glob("*.md"):
            file.unlink()
        self.assertEqual(self.invoke(), "")

    def test_advisory_failures_and_worker_suppression(self):
        self.write()
        for extra in ({"agent_id": "worker"}, {"agent_type": "verifier"}, {"source": "fork"}):
            self.assertEqual(self.invoke(**extra), "")
        self.env["AUTOMETTA_ESCALATION_HOOK"] = "0"
        self.assertEqual(self.invoke(), "")
        self.env.pop("AUTOMETTA_ESCALATION_HOOK")
        self.assertEqual(self.invoke(session=""), "")
        self.assertEqual(self.invoke(cwd=str(self.root / "missing")), "")
        cache = self.home / "hook-delivery"
        cache.write_text("blocked")
        self.assertEqual(self.invoke(), "")
        result = subprocess.run([str(HOOK), "--live", "codex"], input="not json",
            env=self.env, capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_headless_command_detection(self):
        for command in ('/bin/codex exec -C /repo "work"',
                        '/bin/claude --model test -p "work"',
                        '/home/user/.local/share/claude/versions/2.1.310 --print work'):
            self.assertTrue(context.headless_command(command), command)
        for command in ('/bin/codex --model test', '/bin/claude --model test',
                        '/bin/bash -c "echo codex exec"'):
            self.assertFalse(context.headless_command(command), command)

    def test_headless_parent_is_suppressed(self):
        # A CLI-shaped parent exercises process ancestry without spending tokens.
        parent = self.root / "claude"
        parent.symlink_to("/bin/bash")
        helper = self.root / "parent.sh"
        helper.write_text('"$1" --live claude\nwait\n')
        self.write()
        payload = dict(session_id="headless", cwd=str(self.repo), hook_event_name="SessionStart")
        result = subprocess.run([str(parent), str(helper), str(HOOK), "-p"],
            input=json.dumps(payload), env=self.env, capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_codex_installer_migrates_preserves_and_checks(self):
        path = self.root / "hooks.json"
        path.write_text(json.dumps({"keep": True, "hooks": {"SessionStart": [{"hooks": [
            {"type": "command", "command": "/old/hooks/session-start-escalations.sh"},
            {"type": "command", "command": "keep-me"}]}]}}))
        command = [str(SCRIPTS / "install-escalation-hook.sh"), "--family", "codex", "--settings", str(path)]
        subprocess.run(command, check=True, capture_output=True)
        installed = path.read_bytes()
        data = json.loads(installed)
        self.assertTrue(data["keep"])
        self.assertIn("keep-me", installed.decode())
        self.assertEqual(installed.count(b"--live codex"), 3)
        subprocess.run(command, check=True, capture_output=True)
        subprocess.run(command + ["--check"], check=True, capture_output=True)
        self.assertEqual(path.read_bytes(), installed)
        self.assertEqual(len(list(self.root.glob("hooks.json.bak-*"))), 1)


if __name__ == "__main__":
    unittest.main()
