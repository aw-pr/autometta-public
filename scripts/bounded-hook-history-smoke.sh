#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/175-bounded-hook-history.md
python3 - <<'PY'
import hashlib, importlib.util, json, os, subprocess, unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("hook_fixture", "scripts/lib/test-escalation-context.py")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)

class History(unittest.TestCase):
    def setUp(self):
        self.host = hooks.EscalationContextTests()
        self.host.setUp()
        self.addCleanup(self.host.doCleanups)
        bin_dir = self.host.root / "bin"
        bin_dir.mkdir()
        ps = bin_dir / "ps"
        ps.write_text("#!/bin/sh\nprintf '1 interactive-fixture\\n'\n")
        ps.chmod(0o755)
        self.host.env["PATH"] = str(bin_dir) + os.pathsep + os.environ["PATH"]
        self.project = self.host.root / "design"
        subprocess.run(["git", "init", "-q", str(self.project)], check=True)
        self.old = datetime.now(timezone.utc) - timedelta(days=1)
        with patch.dict(os.environ, self.host.env):
            for i in range(24):
                for order, kind in enumerate(("worker_started", "stage_landed")):
                    self.notice(kind, f"01-done-{i}", "HISTORICAL-DETAIL", 2*i+order)
            self.notice("run_finished", "", "FINISHED-RUN", 50)
            self.notice("stage_blocked", "02-open", "ACTION-STILL-OPEN", 51)
        self.host.write(summary="PENDING-ESCALATION")
        state = self.host.repo / "state"
        state.mkdir()
        (state / "state.yaml").write_text("stages:\n" + "".join(
            f"  - id: 01-done-{i}\n    status: completed\n    run_id: done\n    integration: {{state: merged}}\n"
            for i in range(24)) + "  - id: 02-open\n    status: verifier_failed\n    run_id: active\n")

    def notice(self, kind, stage, summary, secs):
        run = "active" if stage == "02-open" else "done"
        path = hooks.lifecycle.emit(self.host.repo, kind, [stage, secs], stage,
                                    summary=summary, run_id=run)
        record = json.loads(path.read_text())
        if stage == "02-open":
            record.pop("run_id")
        record["created_at"] = (self.old + timedelta(seconds=secs)).isoformat()
        path.write_text(json.dumps(record))

    def test_design_chat(self):
        for family in ("codex", "claude"):
            first = self.host.invoke("SessionStart", family, cwd=str(self.project))
            self.assertNotIn("HISTORICAL-DETAIL", first, "unsubscribed Git project inherited fleet history")
            self.assertNotIn("ACTION-STILL-OPEN", first)
            self.assertEqual(self.host.invoke(family=family, cwd=str(self.project)), "")
            with patch.dict(os.environ, self.host.env):
                hooks.lifecycle.emit(None, "quota_window_cleared", family, summary="WINDOW-"+family)
            self.assertIn("WINDOW-"+family, self.host.invoke(family=family, cwd=str(self.project)))

    def test_preexisting_cache(self):
        session = "partially-drained"
        cwd = str(self.host.root)
        key = hashlib.sha256(json.dumps(["codex", session, cwd]).encode()).hexdigest()
        cache = self.host.home / "hook-delivery"
        cache.mkdir()
        seen = {}
        files = sorted((self.host.home / "lifecycle-events").glob("*.json"))
        for file in [p for p in files if json.loads(p.read_text())["kind"] == "worker_started"][:10]:
            seen[str(file)] = hashlib.sha256(file.read_bytes()).hexdigest()
        (cache / (key + ".json")).write_text(json.dumps(dict(checked_at=0,seen=seen)))
        output = self.host.invoke(family="codex", cwd=cwd, session=session)
        self.assertIn("ACTION-STILL-OPEN", output)
        self.assertNotIn("HISTORICAL-DETAIL", output)
        self.assertEqual(self.host.invoke(family="codex", cwd=cwd, session=session), "")

    def test_fleet_catchup(self):
        for family in ("codex", "claude"):
            def read(event, **kwargs):
                return self.host.invoke(event, family, cwd=str(self.host.root), **kwargs)
            for source in ("startup", "compact", "clear"):
                text = read("SessionStart", source=source)
                self.assertIn("PENDING-ESCALATION", text)
                self.assertIn("ACTION-STILL-OPEN", text)
                self.assertRegex(text.lower(), r'finish|complet|summari')
                self.assertNotIn("HISTORICAL-DETAIL", text)
                self.assertLess(len(text), 4500)
                self.assertEqual(read("UserPromptSubmit"), "")
            with patch.dict(os.environ, self.host.env):
                hooks.lifecycle.emit(self.host.repo, "worker_started", family, "03-new", summary="NEW-"+family)
            self.assertIn("NEW-"+family, read("UserPromptSubmit"))
            self.assertEqual(read("UserPromptSubmit"), "")

unittest.main()
PY
# AUTOMETTA-CONTRACT-END
