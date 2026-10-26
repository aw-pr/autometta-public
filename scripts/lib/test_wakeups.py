#!/usr/bin/env python3
"""Offline proofs for wake-up bounds, ownership and native hook delivery."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import lifecycle_events
import session_context
import wakeups


class WakeupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.other = self.root / "other"
        self.other.mkdir()
        self.now = time.time()
        self.env = patch.dict(os.environ, AUTOMETTA_HOME=str(self.root / "home"), AUTOMETTA_WAKEUPS="1")
        self.env.start()
        self.addCleanup(self.env.stop)
        wakeups.directory().mkdir(parents=True)
        self.socket = socket.socket(socket.AF_UNIX)
        self.addCleanup(self.socket.close)
        self.socket_path = str(self.root / "server.sock")
        self.socket.bind(self.socket_path)
        self.state = wakeups.initial()
        self.state["enabled"] = True
        self.owner = wakeups.register(self.state, str(self.repo), "codex", "chat", self.now - 100,
                                      self.socket_path)
        wakeups.save(self.state)

    def event(self, n=0, at=None, repo=None, stage="01-test", kind="worker_started"):
        return dict(id=str(n), repo=str(repo or self.repo), stage=stage, kind=kind,
                    created_at=datetime.fromtimestamp(at or self.now - 20, timezone.utc).isoformat(),
                    summary="Lifecycle event", evidence="state/state.yaml")

    def dispatch(self, events, now=None):
        jobs = wakeups.dispatch(self.state, events, now or self.now)
        wakeups.save(self.state)
        return jobs

    def observe(self, event="Stop", prompt=None, family="codex", **extra):
        payload = dict(session_id="chat", cwd=str(self.repo), hook_event_name=event, **extra)
        if prompt is not None:
            payload["prompt"] = prompt
        with patch.object(wakeups, "interactive", return_value=True), \
             patch.object(wakeups, "codex_socket", return_value=(self.socket_path, None)):
            wakeups.observe(payload, family)
        self.state = wakeups.load()
        self.owner = self.state["owners"][str(self.repo)]

    def test_thousand_events_become_one_bounded_digest_without_replay(self):
        events = [self.event(n, stage=f"{n:02}-card") for n in range(1000)]
        jobs = self.dispatch(events)
        self.assertEqual(len(jobs), 1)
        self.assertLessEqual(len(jobs[0]["text"]), wakeups.MAX_MESSAGE)
        self.assertIn("other cards coalesced", jobs[0]["text"])
        self.assertEqual(len(self.owner["seen"]), 1000)
        self.assertEqual(self.dispatch(events, self.now + 3600), [])
        self.assertEqual(len(self.state["attempts"]), 1)

    def test_busy_stop_does_not_acknowledge_a_queued_wake(self):
        self.dispatch([self.event()])
        batch = self.owner["pending"]["id"]
        expires = self.owner["expires_at"]
        self.observe()
        self.assertEqual(self.owner["pending"]["status"], "queued")
        self.observe("UserPromptSubmit", f"{wakeups.PREFIX}{batch}] update")
        self.assertIsNone(self.owner["pending"])
        self.assertEqual(self.owner["last_received"]["id"], batch)
        self.assertEqual(self.owner["expires_at"], expires)
        self.observe()
        self.assertIsNone(self.owner["pending"])

    def test_one_outstanding_per_chat_even_when_it_owns_multiple_scopes(self):
        wakeups.register(self.state, "fleet", "codex", "chat", self.now - 100, self.socket_path)
        events = [self.event(), self.event(1, repo=self.other)]
        self.assertEqual(len(self.dispatch(events)), 1)
        self.assertEqual(self.dispatch([self.event(2)], self.now + 200), [])

    def test_repository_owner_takes_priority_over_fleet_without_fanout(self):
        fleet = wakeups.register(self.state, "fleet", "claude", "fleet-chat", self.now - 100)
        self.dispatch([self.event()])
        self.assertIsNone(fleet["pending"])
        self.assertIsNotNone(self.owner["pending"])
        self.dispatch([self.event(1, at=self.now + 100, repo=self.other)], self.now + 120)
        self.assertIsNotNone(fleet["pending"])
        self.assertEqual(len(self.state["attempts"]), 2)

    def test_coalescing_keeps_role_transitions_and_latest_card_outcome(self):
        events = [self.event(), self.event(1, at=self.now - 15, kind="stage_landed"),
                  self.event(2, kind="verifier_started"), self.event(3, kind="worker_finished")]
        job = self.dispatch(events)[0]
        self.assertIn("stage_landed", job["text"])
        self.assertNotIn('"kind": "worker_started"', job["text"])
        self.assertEqual(set(self.owner["seen"]), {"0", "1", "2", "3"})
        for kind in ("worker_started", "worker_finished", "verifier_started"):
            self.assertIn(kind, job["text"])

    def test_worker_verifier_stalled_and_failed_outcomes_each_qualify(self):
        for n, (kind, result) in enumerate([
                ("worker_finished", "pass"), ("worker_finished", "fail"),
                ("verifier_started", "started"), ("verifier_finished", "FAIL"),
                ("stage_blocked", "stalled"), ("stage_blocked", "verifier_failed"),
                ("stage_blocked", "failed")]):
            state = wakeups.initial()
            state["enabled"] = True
            wakeups.register(state, str(self.repo), "codex", "chat", self.now - 100, self.socket_path)
            event = dict(self.event(n, kind=kind), result=result)
            jobs = wakeups.dispatch(state, [event], self.now)
            self.assertEqual(len(jobs), 1, (kind, result))
            self.assertIn(kind + (":" + result if result != "started" else ""), jobs[0]["text"])

    def test_failure_transition_remains_visible_when_a_retry_starts(self):
        failed = dict(self.event(kind="stage_blocked"), result="stalled")
        retry = self.event(1, kind="worker_started", at=self.now - 15)
        text = self.dispatch([failed, retry])[0]["text"]
        self.assertIn("stage_blocked:stalled", text)
        self.assertIn("worker_started", text)

    def test_no_backlog_future_events_expired_lease_or_closed_session(self):
        self.assertEqual(self.dispatch([self.event(at=self.now - 200)]), [])
        self.assertEqual(self.dispatch([self.event(at=self.now + 20)]), [])
        self.assertEqual(self.dispatch([self.event(at=self.now - wakeups.MAX_AGE - 1)]), [])
        self.owner["expires_at"] = self.now - 1
        self.assertEqual(self.dispatch([self.event()]), [])
        self.owner["expires_at"] = self.now + 1000
        self.owner["closed"] = True
        self.assertEqual(self.dispatch([self.event()]), [])

    def test_debounce_is_not_extended_by_continuous_events_and_cooldown_binds(self):
        self.assertEqual(self.dispatch([self.event(at=self.now - 5)]), [])
        events = [self.event(at=self.now - 11), self.event(1, at=self.now - 1)]
        self.assertEqual(len(self.dispatch(events)), 1)
        self.owner["pending"] = None
        self.assertEqual(self.dispatch([self.event(2)], self.now + 119), [])
        self.assertEqual(len(self.dispatch([self.event(2)], self.now + 120)), 1)

    def test_hourly_and_daily_caps_persist_across_restart_and_owner_changes(self):
        for n in range(wakeups.HOURLY_CAP):
            self.owner["pending"] = None
            self.assertEqual(len(self.dispatch([self.event(n, at=self.now + n * 121 - 20,
                                                          stage=f"{n:02}-card")], self.now + n * 121)), 1)
        self.owner["pending"] = None
        wakeups.save(self.state)
        self.state = wakeups.load()
        self.owner = self.state["owners"][str(self.repo)]
        self.assertEqual(self.dispatch([self.event(999)], self.now + 1000), [])
        self.state["attempts"] = [dict(at=self.now - 4000 - n, cards=[], session="old", scope="old", batch=str(n))
                                  for n in range(wakeups.DAILY_CAP)]
        self.owner["closed"] = True
        self.owner = wakeups.register(self.state, str(self.repo), "codex", "new-chat", self.now,
                                      self.socket_path)
        self.assertEqual(self.dispatch([self.event(888, at=self.now + 10)], self.now + 30), [])
        self.assertEqual(len(self.state["attempts"]), wakeups.DAILY_CAP)

    def test_retry_storm_has_a_per_card_cap(self):
        for n in range(wakeups.CARD_HOURLY_CAP):
            self.owner["pending"] = None
            self.assertEqual(len(self.dispatch([self.event(n, at=self.now + n * 121 - 20)],
                                               self.now + n * 121)), 1)
        self.owner["pending"] = None
        self.assertEqual(self.dispatch([self.event(999, at=self.now + 500)], self.now + 600), [])
        self.assertEqual(len(self.dispatch([self.event(1000, at=self.now + 500, stage="02-next")],
                                           self.now + 600)), 1)

    def test_ambiguous_native_failure_is_latched_and_never_retried(self):
        with patch.object(wakeups, "repos", return_value=[str(self.repo)]), \
             patch.object(wakeups, "records", return_value=[self.event()]), \
             patch.object(wakeups, "native_queue", side_effect=TimeoutError) as send:
            wakeups.flush()
            wakeups.flush()
        self.assertEqual(send.call_count, 1)
        self.state = wakeups.load()
        self.owner = self.state["owners"][str(self.repo)]
        batch = self.owner["pending"]["id"]
        self.assertEqual(self.owner["pending"]["status"], "failed")
        self.observe("UserPromptSubmit", "human prompt")
        self.assertEqual(self.owner["error"], "TimeoutError")
        self.assertEqual(self.owner["pending"]["id"], batch)
        self.assertEqual(len(self.state["attempts"]), 1)

    def test_transport_does_not_hold_the_hook_lock_during_native_delivery(self):
        def receive(owner, text):
            self.observe("UserPromptSubmit", text)
        with patch.object(wakeups, "repos", return_value=[str(self.repo)]), \
             patch.object(wakeups, "records", return_value=[self.event()]), \
             patch.object(wakeups, "native_queue", side_effect=receive):
            wakeups.flush()
        owner = wakeups.load()["owners"][str(self.repo)]
        self.assertIsNone(owner["pending"])
        self.assertTrue(owner["last_received"]["id"])

    def test_parallel_tick_flushes_reserve_only_one_delivery(self):
        sent = []
        def flush():
            try:
                wakeups.flush()
            except BlockingIOError:
                pass
        with patch.object(wakeups, "repos", return_value=[str(self.repo)]), \
             patch.object(wakeups, "records", return_value=[self.event()]), \
             patch.object(wakeups, "native_queue", side_effect=lambda *args: sent.append(args)):
            with ThreadPoolExecutor(max_workers=6) as pool:
                list(pool.map(lambda _: flush(), range(6)))
        self.assertEqual(len(sent), 1)
        self.assertEqual(len(wakeups.load()["attempts"]), 1)

    def test_claude_native_reminder_is_taken_once_and_disabled_or_expired_stays_quiet(self):
        self.state["owners"] = {}
        owner = wakeups.register(self.state, str(self.repo), "claude", "claude-chat", self.now - 100)
        self.assertEqual(self.dispatch([self.event()]), [])
        text = wakeups.take_claude(self.state, "claude-chat", self.now)
        self.assertTrue(text.startswith(wakeups.PREFIX))
        self.assertIsNone(wakeups.take_claude(self.state, "claude-chat", self.now))
        owner["pending"]["status"] = "ready"
        self.assertIsNone(wakeups.take_claude(self.state, "claude-chat", self.now + wakeups.MAX_AGE + 1))
        self.assertEqual(owner["pending"]["status"], "expired")
        self.state["enabled"] = False
        self.assertIsNone(wakeups.take_claude(self.state, "claude-chat", self.now))

    def test_native_claude_waiter_exits_two_with_one_reminder(self):
        self.state["owners"] = {}
        wakeups.register(self.state, str(self.repo), "claude", "chat", self.now - 100)
        self.dispatch([self.event()])
        payload = dict(session_id="chat", hook_event_name="Stop", cwd=str(self.repo))
        result = subprocess.run([str(wakeups.SCRIPTS / "wakeups.sh"), "wait", "claude"],
                                input=json.dumps(payload), text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn(wakeups.PREFIX, result.stderr)
        self.assertEqual(wakeups.load()["owners"][str(self.repo)]["pending"]["status"], "delivered")
        payload["hook_event_name"] = "SessionEnd"
        subprocess.run([str(wakeups.SCRIPTS / "wakeups.sh"), "hook", "claude"],
                       input=json.dumps(payload), text=True, capture_output=True, check=True)
        result = subprocess.run([str(wakeups.SCRIPTS / "wakeups.sh"), "wait", "claude"],
                                input=json.dumps(payload), text=True, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_same_stop_boundary_cannot_acknowledge_its_own_async_reminder(self):
        self.state["owners"] = {}
        owner = wakeups.register(self.state, str(self.repo), "claude", "chat", self.now - 100)
        self.dispatch([self.event()])
        payload = dict(session_id="chat", hook_event_name="Stop", cwd=str(self.repo),
                       last_assistant_message="Original response")
        wakeups.take_claude(self.state, "chat", self.now, wakeups.boundary(payload))
        wakeups.save(self.state)
        with patch.object(wakeups, "interactive", return_value=True):
            wakeups.observe(payload, "claude")
            self.assertIsNotNone(wakeups.load()["owners"][str(self.repo)]["pending"])
            wakeups.observe(dict(payload, last_assistant_message="Wake-up handled"), "claude")
        self.assertIsNone(wakeups.load()["owners"][str(self.repo)]["pending"])

    def test_native_queue_targets_owning_socket_and_preserves_model_and_permissions(self):
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            wakeups.native_queue(self.owner, "message")
        argv = run.call_args.args[0]
        self.assertEqual(argv, ["codex", "queue", "--remote", "unix://" + self.socket_path,
                                "--thread", "chat", "--message", "message"])
        self.assertEqual(run.call_args.kwargs["timeout"], 8)
        self.assertEqual(run.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_scope_registration_is_exclusive_and_requires_a_real_socket(self):
        self.assertIsNone(wakeups.register(self.state, str(self.repo), "claude", "other-chat", self.now))
        self.assertEqual(self.owner["session"], "chat")
        with self.assertRaises((OSError, ValueError)):
            wakeups.register(self.state, "fleet", "codex", "bad", self.now, str(self.root / "missing"))
        with patch.object(session_context, "ancestors", return_value=[(os.getpid(), "/bin/codex app-server")]), \
             patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "n" + self.socket_path + "\n")):
            self.assertEqual(session_context.codex_socket(), (self.socket_path, os.getpid()))

    def test_synthetic_prompts_workers_and_corrupt_state_cannot_register_or_reset_caps(self):
        self.state["owners"] = {}
        wakeups.save(self.state)
        payload = dict(session_id="synthetic", cwd=str(self.repo), hook_event_name="UserPromptSubmit",
                       prompt=wakeups.PREFIX + "unknown] update")
        with patch.object(wakeups, "interactive", return_value=True):
            wakeups.observe(payload, "codex")
        self.assertEqual(wakeups.load()["owners"], {})
        with patch.object(session_context, "headless_ancestor", return_value=False):
            self.assertFalse(session_context.interactive(dict(payload, agent_id="worker")))
            self.assertFalse(session_context.interactive(dict(payload, source="fork")))
        path = wakeups.directory() / "state.json"
        path.write_text("broken")
        result = subprocess.run([str(wakeups.SCRIPTS / "wakeups.sh"), "flush"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), "broken")
        with self.assertRaises(ValueError):
            wakeups.load()

    def test_only_claude_gets_async_rewake_and_install_preserves_other_hooks(self):
        spec = importlib.util.spec_from_file_location("installer", wakeups.SCRIPTS / "lib/install-escalation-hook.py")
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        for family in ("claude", "codex"):
            current = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "keep"}]}]}}
            expected = installer.expected_settings(current, wakeups.SCRIPTS / "hooks/session-start-escalations.sh", family)
            self.assertEqual(expected, installer.expected_settings(expected, wakeups.SCRIPTS / "hooks/session-start-escalations.sh", family))
            self.assertEqual(expected["hooks"]["Stop"][0]["hooks"][0]["command"], "keep")
            waits = [hook for groups in expected["hooks"].values() for group in groups for hook in group["hooks"]
                     if hook.get("asyncRewake")]
            self.assertEqual(len(waits), 3 if family == "claude" else 0)

    def test_disable_enable_and_explicit_acknowledgement_preserve_spend_limits(self):
        self.dispatch([self.event()])
        batch = self.owner["pending"]["id"]
        script = str(wakeups.SCRIPTS / "wakeups.sh")
        subprocess.run([script, "disable"], check=True, capture_output=True)
        env = dict(os.environ)
        env.pop("CODEX_THREAD_ID", None)
        subprocess.run([script, "enable"], check=True, capture_output=True, env=env)
        state = wakeups.load()
        self.assertEqual(len(state["attempts"]), 1)
        self.assertEqual(state["owners"][str(self.repo)]["pending"]["id"], batch)
        wrong = subprocess.run([script, "acknowledge", "--session", "chat", "--batch", "wrong"], capture_output=True)
        self.assertEqual(wrong.returncode, 1)
        subprocess.run([script, "acknowledge", "--session", "chat", "--batch", batch],
                       check=True, capture_output=True)
        state = wakeups.load()
        self.assertIsNone(state["owners"][str(self.repo)]["pending"])
        self.assertEqual(len(state["attempts"]), 1)

    def test_global_cooldown_prevents_a_fleet_wide_burst(self):
        other = wakeups.register(self.state, str(self.other), "claude", "other-chat", self.now - 100)
        self.dispatch([self.event(), self.event(1, repo=self.other)])
        self.assertIsNotNone(self.owner["pending"])
        self.assertIsNone(other["pending"])
        self.assertEqual(len(self.state["attempts"]), 1)

    def test_long_paths_keep_whole_rows_and_material_outcomes_ahead_of_starts(self):
        events = [self.event(n, stage=f"{n:02}-card") for n in range(30)]
        events[-1]["kind"] = "run_blocked"
        for event in events:
            event.update(repo="/" + "r" * 1000, evidence="e" * 1000, summary="s" * 1000)
        text = wakeups.message("batch", events)
        self.assertLessEqual(len(text), wakeups.MAX_MESSAGE)
        rows = [json.loads(line) for line in text.splitlines() if line.startswith("{")]
        self.assertEqual(rows[0]["kind"], "run_blocked")
        self.assertIn("other cards coalesced", text)


if __name__ == "__main__":
    unittest.main()
