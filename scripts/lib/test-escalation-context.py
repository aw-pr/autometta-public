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
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
HOOK = SCRIPTS / "hooks/session-start-escalations.sh"
spec = importlib.util.spec_from_file_location("context", SCRIPTS / "hooks/escalation-context.py")
context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(context)
import lifecycle_events as lifecycle


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

    def notices(self):
        return [json.loads(path.read_text()) for path in (self.home / "lifecycle-events").glob("*.json")]

    def emit(self, repo=None, kind="worker_finished", episode="attempt-one", **details):
        with patch.dict(os.environ, self.env):
            lifecycle.emit(repo or self.repo, kind, episode, "01-test",
                           summary="Worker finished: pass", **details)

    def test_lifecycle_scopes_deduplicates_and_survives_without_escalations(self):
        self.pending.rmdir()
        self.emit()
        self.emit(self.other)
        for family in ("claude", "codex"):
            text = self.invoke(family=family)
            self.assertIn("worker_finished", text)
            self.assertNotIn(str(self.other), text)
            self.assertEqual(self.invoke(family=family), "")
            self.assertIn(str(self.other), self.invoke(family=family, cwd=str(self.root)))
            self.assertIn("worker_finished", self.invoke("SessionStart", family=family, source="compact"))
        self.assertEqual(len(self.notices()), 2)

    def test_notices_do_not_displace_escalations_and_overflow_is_delivered(self):
        self.write(summary="ACTION FIRST")
        for index in range(12):
            self.emit(episode=str(index))
        first = self.invoke()
        self.assertLess(first.index("ACTION FIRST"), first.index("worker_finished"))
        self.assertIn("+3 more", first)
        self.assertEqual(self.invoke().count('"kind": "worker_finished"'), 3)
        self.assertEqual(self.invoke(), "")

    def test_events_are_atomic_deduplicated_and_expire(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _: self.emit(), range(4)))
        self.assertEqual(len(self.notices()), 1)
        path = next((self.home / "lifecycle-events").glob("*.json"))
        os.utime(path, (1, 1))
        self.assertEqual(self.invoke(), "")
        self.emit(episode="new")
        self.assertEqual(len(self.notices()), 1)
        self.assertFalse(path.exists())

    def test_agent_exit_requires_fresh_evidence_and_keeps_unknown_unknown(self):
        doc = dict(role="worker", pid=10, agent_id="10-one", started_at="2026-10-25T10:00:00Z",
                   card_path="stage-cards/01-test.md", log_path="state/logs/01-test-worker.log")
        artifact = self.repo / "state/envelopes/01-test.json"
        artifact.parent.mkdir(parents=True)
        artifact.write_text('{"status":"pass"}')
        os.utime(artifact, (1, 1))
        with patch.dict(os.environ, self.env):
            lifecycle.agent_event(self.repo, doc)
            lifecycle.agent_event(self.repo, doc, finished=True)
            artifact.touch()
            lifecycle.agent_event(self.repo, dict(doc, agent_id="10-two"), finished=True)
            verifier = self.repo / "state/verifiers/01-test.json"
            verifier.parent.mkdir()
            verifier.write_text('{"overall":"FAIL"}')
            lifecycle.agent_event(self.repo, dict(doc, role="verifier"), finished=True)
        observed = {(n["kind"], n["agent_id"]): n["result"] for n in self.notices()}
        self.assertEqual(observed[("worker_started", "10-one")], "started")
        self.assertEqual(observed[("worker_finished", "10-one")], "unknown")
        self.assertEqual(observed[("worker_finished", "10-two")], "pass")
        self.assertEqual(observed[("verifier_finished", "10-one")], "FAIL")

    def test_stage_pass_is_not_landing_until_integration_and_run_is_finished(self):
        active = dict(id="01-test", status="in_progress", started_at="start")
        awaiting = dict(active, status="completed", completed_at="end", commit="abc",
                        integration=dict(state="awaiting"))
        merged = dict(awaiting, integration=dict(state="merged", rebased_tip="def"))
        with patch.dict(os.environ, self.env):
            lifecycle.stage_changes(self.repo, {"stages": [active]}, {"stages": [awaiting]})
            self.assertEqual([n["kind"] for n in self.notices()], ["stage_awaiting_integration"])
            lifecycle.stage_changes(self.repo, {"stages": [awaiting]}, {"stages": [merged]})
            lifecycle.stage_changes(self.repo, {"stages": [merged]}, {"stages": [merged]})
        observed = {n["kind"]: n for n in self.notices()}
        self.assertEqual(set(observed), {"stage_awaiting_integration", "stage_landed", "run_finished"})
        self.assertEqual(observed["stage_landed"]["commit"], "def")

    def test_malformed_artifacts_and_missing_start_times_stay_unknown(self):
        artifact = self.repo / "state/verifiers/01-test.json"
        artifact.parent.mkdir(parents=True)
        doc = dict(role="verifier", pid=10, card_path="01-test.md")
        with patch.dict(os.environ, self.env):
            for index, value in enumerate(("null", "[]", "not json", '{"overall":"PASS"}')):
                artifact.write_text(value)
                lifecycle.agent_event(self.repo, dict(doc, agent_id=str(index), started_at=None), finished=True)
        self.assertEqual(len(self.notices()), 4)
        self.assertEqual({n["result"] for n in self.notices()}, {"unknown"})

    def test_real_state_and_budget_writers_emit_without_mutating_policy(self):
        state = self.repo / "state/state.yaml"
        state.parent.mkdir()
        state.write_text('stages:\n  - id: 01-test\n    status: in_progress\n')
        budget = state.with_name("budget.json")
        budget.write_text('{"halted":false,"tokens_spent":42}')
        command = '''source "$1/tick.sh"
record_stage_integration "$2/state/state.yaml" 01-test "$(integration_record awaiting dev autometta/01-test abc '')"
state_apply_json "$2/state/state.yaml" '.stages[0].status = "completed" | .stages[0].commit = "abc"'
record_stage_integration "$2/state/state.yaml" 01-test "$(integration_record merged dev autometta/01-test abc '')"
budget_halt "$2" operator-pause
budget_halt "$2" operator-pause
'''
        subprocess.run(["bash", "-c", command, "test", str(SCRIPTS), str(self.repo)],
                       env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual({n["kind"] for n in self.notices()},
                         {"stage_awaiting_integration", "stage_landed", "run_finished", "run_blocked"})
        self.assertEqual(len(self.notices()), 4)
        self.assertEqual(json.loads(budget.read_text())["tokens_spent"], 42)

    def test_run_completion_uses_run_identity_and_waits_for_pending_members(self):
        historic = dict(id="00-old", run_id="old-run", status="verifier_failed")
        active = dict(id="01-test", run_id="new-run", status="in_progress")
        pending = dict(id="02-next", run_id="new-run", status="pending")
        complete = dict(active, status="completed", commit="abc")
        with patch.dict(os.environ, self.env):
            lifecycle.stage_changes(self.repo, {"stages": [historic, active, pending]},
                                    {"stages": [historic, complete, pending]})
            self.assertNotIn("run_finished", [n["kind"] for n in self.notices()])
            lifecycle.stage_changes(self.repo, {"stages": [historic, complete, pending]},
                                    {"stages": [historic, complete, dict(pending, status="superseded")]})
        runs = [n for n in self.notices() if n["kind"] == "run_finished"]
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["run_id"], "new-run")

    def test_notice_storage_failure_does_not_break_state_writes(self):
        (self.home / "lifecycle-events").write_text("blocked")
        state = self.repo / "state/state.yaml"
        state.parent.mkdir()
        state.write_text('stages:\n  - id: 01-test\n    status: in_progress\n')
        command = '''source "$1/tick.sh"
state_apply_json "$2/state/state.yaml" '.stages[0].status = "completed"'
'''
        subprocess.run(["bash", "-c", command, "test", str(SCRIPTS), str(self.repo)],
                       env=self.env, capture_output=True, text=True, check=True)
        self.assertIn("completed", state.read_text())

    def test_registration_and_heartbeat_produce_real_start_and_finish_notices(self):
        artifact = self.repo / "state/envelopes/01-test.json"
        artifact.parent.mkdir(parents=True)
        subprocess.run([str(SCRIPTS / "register-agent.sh"), str(self.repo), "99999999",
                        "worker", "claude", "test identity", "stage-cards/01-test.md",
                        "state/logs/01-test-worker.log"], env=self.env,
                       capture_output=True, text=True, check=True)
        artifact.write_text('{"status":"pass"}')
        env = dict(self.env, AUTOMETTA_BUILD_CHECK_JSON=json.dumps(dict(
            status="current", stale=False, installed_sha="test", checkout_sha="test",
            checked_at="2026-10-25T10:00:00Z")))
        subprocess.run([str(SCRIPTS / "heartbeat.sh"), str(self.repo)], env=env,
                       capture_output=True, text=True, check=True)
        observed = {n["kind"]: n for n in self.notices()}
        self.assertEqual(set(observed), {"worker_started", "worker_finished"})
        self.assertEqual(observed["worker_finished"]["result"], "pass")
        self.assertFalse((self.repo / "state/active-agents/99999999.json").exists())
        self.assertTrue(list((self.repo / "state/recent-agents").glob("*.json")))


if __name__ == "__main__":
    unittest.main()
