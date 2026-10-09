#!/usr/bin/env bash
set -euo pipefail
# One frozen oracle serves the three serial implementation cards.
# Modes: inspect (142), dispatch (143), lifecycle (144), all.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_root="${AUTOMETTA_GRAPH_TEST_ROOT:-$(cd "$script_dir/.." && pwd)}"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/142-dependency-readiness-has-evidence.md
python3 - "$source_root" "${1:-all}" <<'PY'
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1]).resolve()
MODE = sys.argv[2]
if MODE not in {"inspect", "dispatch", "lifecycle", "all"}:
    raise SystemExit("usage: dependency-graph-smoke.sh [inspect|dispatch|lifecycle|all]")


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="autometta-graph-")
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.env = dict(os.environ)
        self.env.update(AUTOMETTA_ROOT=str(ROOT), AUTOMETTA_HOME=str(self.tmp / "controller"),
                        PHAT_CONTROLLER_HOME=str(self.tmp / "controller"),
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.run_cmd(["git", "init", "-q", "-b", "dev", str(self.repo)])
        self.git("config", "user.name", "Graph fixture")
        self.git("config", "user.email", "fixture@local")
        self.git("config", "core.hooksPath", str(self.tmp / "no-hooks"))
        self.git("config", "commit.gpgsign", "false")
        (self.repo / ".gitignore").write_text("state/\n")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "seed")
        self.seed = self.git("rev-parse", "HEAD")
        self.git("switch", "-qc", "unlanded")
        (self.repo / "feature.txt").write_text("unlanded implementation\n")
        self.git("add", "feature.txt")
        self.git("commit", "-qm", "unlanded")
        self.unlanded = self.git("rev-parse", "HEAD")
        self.git("switch", "-q", "dev")
        (self.repo / "state").mkdir()
        (self.repo / "state/budget.json").write_text(json.dumps(
            {"token_cap_total": 1000000, "tokens_spent": 0, "halted": False}))
        (self.repo / "stage-cards").mkdir()
        self.state_path = self.repo / "state/state.yaml"
        self.state = dict(version=1, current_stage=None, last_tick_at="2026-10-03T00:00:00Z",
                          tick_count=0, clock_tick_budget_remaining=100, stages=[])
        self.a = self.stage("01-parent", "completed", commit=self.seed,
                            integration={"state": "merged", "head": self.seed})
        self.b = self.stage("02-parent", "completed", commit=self.unlanded,
                            integration={"state": "awaiting", "head": self.unlanded})
        self.child = self.stage("03-join", depends_on=[self.a["id"], self.b["id"]])
        self.free = self.stage("04-independent")
        self.state["stages"] = [self.a, self.b, self.child, self.free]
        self.save()

    def run_cmd(self, args, *, check=True, **kwargs):
        result = subprocess.run(args, text=True, capture_output=True, env=self.env,
                                cwd=self.repo, **kwargs)
        if check:
            self.assertEqual(result.returncode, 0, f"{args}\n{result.stdout}\n{result.stderr}")
        return result

    def git(self, *args):
        return self.run_cmd(["git", "-C", str(self.repo), *args]).stdout.strip()

    @staticmethod
    def stage(stage_id, status="pending", **fields):
        return dict(id=stage_id, status=status, worker="Fixture worker", verifier="Fixture verifier",
                    worker_pid=None, verifier_pid=None, verifier_artefact=None,
                    verifier_attempts=0, started_at=None, completed_at=None, **fields)

    def save(self):
        self.state_path.write_text(json.dumps(self.state))

    def read_state(self):
        return json.loads(self.run_cmd(["yq", "-o=json", ".", str(self.state_path)]).stdout)

    def inspect(self, valid=True):
        before = self.state_path.read_bytes()
        refs = self.git("show-ref")
        result = self.run_cmd(["bash", str(ROOT / "scripts/dependency-graph.sh"),
                               str(self.repo), str(self.state_path), "dev"], check=False)
        self.assertEqual(result.returncode, 0 if valid else 2, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["valid"], valid)
        self.assertEqual(self.state_path.read_bytes(), before, "inspection mutated state")
        self.assertEqual(self.git("show-ref"), refs, "inspection moved a Git ref")
        return report

    def node(self, report, stage_id="03-join"):
        return next(n for n in report["stages"] if n["id"] == stage_id)

    def card(self, stage_id, metadata=""):
        path = self.repo / "stage-cards" / (stage_id + ".md")
        path.write_text(f"# Stage card {stage_id}\n- **Worker:** Fixture worker\n"
                        f"- **Verifier:** Fixture verifier\n- **Dispatch:** serial\n{metadata}\n")
        return path

    def add(self, stage_id, metadata="", success=True):
        path = self.card(stage_id, metadata)
        before = self.state_path.read_bytes()
        result = self.run_cmd(["bash", str(ROOT / "scripts/add-stage.sh"),
                               str(self.repo), str(path)], check=False)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, "invalid dependency card was accepted")
            self.assertEqual(self.state_path.read_bytes(), before, "refusal changed queue bytes")
            self.assertTrue(result.stderr.strip(), "refusal has no diagnostic")
        return result

    def selected(self):
        # Exercise the shipped selector in a fresh process, not a second scheduler in this test.
        result = self.run_cmd(["bash", "-c", '''
source "$1/scripts/tick.sh"
select_next_dispatchable_stage "$2/state/state.yaml" "$2" dev
''', "graph-selector", str(ROOT), str(self.repo)])
        return result.stdout.strip()


class Inspect(Fixture):
    def test_join_waits_for_actual_integration(self):
        report = self.inspect()
        self.assertFalse(self.node(report)["dependency_ready"])
        self.assertIn({"id": "02-parent", "reason": "awaiting-integration"},
                      self.node(report)["blocked_by"])
        self.b["integration"]["state"] = "merged"
        self.save()
        self.assertIn({"id": "02-parent", "reason": "commit-not-on-base"},
                      self.node(self.inspect())["blocked_by"])
        self.git("merge", "--ff-only", "unlanded")
        self.save()
        self.assertTrue(self.node(self.inspect())["dependency_ready"])

    def test_parent_status_and_commit_evidence(self):
        for status in ["pending", "in_progress", "failed", "verifier_failed", "stalled", "superseded"]:
            with self.subTest(status=status):
                self.b.update(status=status, commit=self.seed,
                              integration={"state": "merged", "head": self.seed})
                self.save()
                self.assertIn({"id": "02-parent", "reason": "not-completed"},
                              self.node(self.inspect())["blocked_by"])
        self.b.update(status="completed", integration=None)
        self.b.pop("commit")
        self.save()
        self.assertIn({"id": "02-parent", "reason": "missing-commit"},
                      self.node(self.inspect())["blocked_by"])
        self.b["commit"] = self.seed
        self.save()
        self.assertTrue(self.node(self.inspect())["dependency_ready"], "legacy ancestor evidence lost")

    def test_rebased_tip_is_the_landed_evidence(self):
        self.b["integration"] = {"state": "merged", "head": self.unlanded, "rebased_tip": self.seed}
        self.save()
        self.assertTrue(self.node(self.inspect())["dependency_ready"])
        self.git("branch", "other-base", self.seed)
        self.git("merge", "--ff-only", "unlanded")
        self.b["integration"]["rebased_tip"] = self.unlanded
        self.save()
        result = self.run_cmd(["bash", str(ROOT / "scripts/dependency-graph.sh"),
                               str(self.repo), str(self.state_path), "other-base"])
        self.assertFalse(self.node(json.loads(result.stdout))["dependency_ready"],
                         "evidence was checked against current HEAD instead of requested base")

    def test_invalid_graphs_and_mixed_legacy_cycle(self):
        good = copy.deepcopy(self.state)
        variants = [
            ("missing", lambda s: s["stages"][2].update(depends_on=["99-absent"])),
            ("self", lambda s: s["stages"][2].update(depends_on=["03-join"])),
            ("duplicate dependency", lambda s: s["stages"][2].update(depends_on=["01-parent"] * 2)),
            ("empty", lambda s: s["stages"][2].update(depends_on=[])),
            ("wrong type", lambda s: s["stages"][2].update(depends_on="01-parent")),
            ("duplicate id", lambda s: s["stages"].append(copy.deepcopy(s["stages"][0]))),
            ("cycle", lambda s: s["stages"][0].update(depends_on=["03-join"])),
            ("mixed cycle", lambda s: s["stages"][0].update(
                gate={"type": "stage_completed", "stage_id": "03-join"})),
        ]
        for name, mutate in variants:
            with self.subTest(name=name):
                self.state = copy.deepcopy(good)
                mutate(self.state)
                self.save()
                report = self.inspect(valid=False)
                self.assertTrue(report["errors"], "invalid graph has no actionable diagnostic")
                self.assertFalse(self.node(report)["dependency_ready"])

    def test_failure_does_not_invalidate_an_unrelated_node(self):
        self.b["status"] = "failed"
        self.save()
        report = self.inspect()
        self.assertTrue(self.node(report, "04-independent")["dependency_ready"])
        self.assertEqual([n["id"] for n in report["stages"]], [n["id"] for n in self.state["stages"]])
        self.assertTrue(self.node(report, "01-parent")["graph_member"])
        self.assertFalse(self.node(report, "04-independent")["graph_member"])


class Dispatch(Fixture):
    def test_queue_parsing_and_schema(self):
        self.add("05-consumer", "- **Depends on:** 01-parent, 02-parent")
        record = self.read_state()["stages"][-1]
        self.assertEqual(record["depends_on"], ["01-parent", "02-parent"])
        self.assertNotIn("gate", record)
        import jsonschema
        schema = json.loads((ROOT / "schemas/state.yaml.json").read_text())
        validator = jsonschema.Draft202012Validator(schema)
        # Minimal schema fixtures avoid asserting incidental integration fields.
        state = copy.deepcopy(self.state)
        state["stages"] = [self.stage("05-consumer", depends_on=["01-parent", "02-parent"])]
        self.assertEqual(list(validator.iter_errors(state)), [])
        for value in [[], "01-parent", ["01-parent", "01-parent"], ["../bad"]]:
            state["stages"][0]["depends_on"] = value
            self.assertTrue(list(validator.iter_errors(state)), f"schema accepted {value!r}")

    def test_bad_cards_are_atomic_refusals(self):
        for metadata in [
            "- **Depends on:** 99-missing",
            "- **Depends on:** 05-consumer",
            "- **Depends on:** 01-parent, 01-parent",
            "- **Depends on:**",
            "- **Depends on:** 01-parent,",
            "- **Depends on:** ../bad",
            "- **Depends on:** 01-parent\n- **Depends on:** 02-parent",
            "- **Depends on:** 01-parent\n- **Gate:** queue-empty",
            "- **Depends on:** 01-parent\n- **Path claims:** src",
        ]:
            with self.subTest(metadata=metadata):
                self.add("05-consumer", metadata, success=False)
        self.a["gate"] = {"type": "stage_completed", "stage_id": "05-consumer"}
        self.save()
        self.add("05-consumer", "- **Depends on:** 01-parent", success=False)

    def test_legacy_card_is_not_migrated(self):
        before = copy.deepcopy(self.state["stages"])
        self.add("05-legacy", "- **Gate:** stage-completed: 99-missing")
        state = self.read_state()
        self.assertEqual(state["stages"][:-1], before)
        self.assertNotIn("depends_on", state["stages"][-1])
        self.assertEqual(state["stages"][-1]["gate"]["stage_id"], "99-missing")

    def test_selection_steps_over_blocked_then_uses_stable_order(self):
        self.assertEqual(self.selected(), "04-independent")
        self.git("merge", "--ff-only", "unlanded")
        self.b["integration"]["state"] = "merged"
        self.save()
        self.assertEqual(self.selected(), "03-join")
        self.b["status"] = "failed"
        self.save()
        self.assertEqual(self.selected(), "04-independent")
        self.child["depends_on"] = ["99-missing"]
        self.save()
        self.assertEqual(self.selected(), "04-independent", "malformed graph dispatched")

    def test_legacy_gate_does_not_silently_change_meaning(self):
        self.child.pop("depends_on")
        self.child["gate"] = {"type": "stage_completed", "stage_id": "02-parent"}
        self.save()
        self.assertEqual(self.selected(), "03-join")

    def test_graph_cannot_enter_pipeline_as_head_or_tail(self):
        # Calling the actual pair dispatcher detects an attempted spawn even if a guard is bypassed.
        for head, tail, graph in [(self.child, self.free, True), (self.free, self.child, True),
                                  (self.a, self.free, True), (self.free, self.a, False)]:
            with self.subTest(head=head["id"], tail=tail["id"]):
                stages = copy.deepcopy([head, tail])
                stages[0]["status"] = "in_progress"
                stages[1]["status"] = "pending"
                for i, stage in enumerate(stages):
                    stage["path_claims"] = [f"area{i}"]
                ids = {s["id"] for s in stages}
                stages += [copy.deepcopy(s) for s in [self.a, self.b, self.child] if s["id"] not in ids]
                if not graph:
                    for s in stages:
                        s.pop("depends_on", None)
                self.git("merge", "--ff-only", "unlanded")
                for s in stages:
                    if s["id"] == "02-parent":
                        s["integration"]["state"] = "merged"
                self.state["stages"] = stages
                self.state["current_stage"] = head["id"]
                self.save()
                result = self.run_cmd(["bash", "-c", '''
source "$1/scripts/tick.sh"
pipeline_pair_on() { printf 'off\n'; }
pipeline_p95_tokens() { printf '1\n'; }
quota_gate_role_dispatch() { QUOTA_GATE_RESOLVED_WINDOW=normal; return 0; }
budget_gate_dispatch() { return 0; }
network_preflight_ok() { return 0; }
stage_card_for_id() { printf '%s/stage-cards/%s.md\n' "$1" "$2"; }
resolve_base_branch() { printf 'dev\n'; }
ensure_run_worktree() { printf '%s\n' "$1"; }
spawn_worker_for_stage() { printf 'UNEXPECTED-SPAWN\n'; }
pipeline_try_dispatch_tail "$2" "$2/state/state.yaml" "$3" "" || true
''', "graph-pair", str(ROOT), str(self.repo), head["id"]])
                if graph:
                    self.assertNotIn("UNEXPECTED-SPAWN", result.stdout)
                    self.assertNotIn("pipeline_pair", self.read_state())
                else:
                    self.assertIn("UNEXPECTED-SPAWN", result.stdout, "control never reached spawn")
                    self.assertIn("pipeline_pair", self.read_state())


class Lifecycle(Fixture):
    def harness(self):
        harness = self.tmp / "harness"
        shutil.copytree(ROOT / "scripts", harness / "scripts")
        shutil.copytree(ROOT / "templates", harness / "templates")
        shutil.copytree(ROOT / "schemas", harness / "schemas")
        worker = harness / "scripts/spawn-worker.sh"
        worker.write_text('''#!/usr/bin/env bash
set -euo pipefail
stage_id="$(basename "$1" .md)"
printf '%s\n' "$stage_id" >> "$GRAPH_SPAWN_LOG"
STAGE_ID="$stage_id" GRAPH_LIVE_PID="$GRAPH_LIVE_PID" yq -i \\
 '(.stages[] | select(.id == strenv(STAGE_ID))).worker_pid = (strenv(GRAPH_LIVE_PID) | tonumber)' "$2/state/state.yaml"
''')
        worker.chmod(0o755)
        for name in ["spawn-verifier.sh", "spawn-verifier-panel.sh"]:
            path = harness / "scripts" / name
            path.write_text("#!/bin/sh\nprintf 'unexpected verifier dispatch\\n' >&2\nexit 97\n")
            path.chmod(0o755)
        self.spawn_log = self.tmp / "spawns"
        self.env.update(GRAPH_SPAWN_LOG=str(self.spawn_log), GRAPH_LIVE_PID=str(os.getpid()))
        self.harness_root = harness
        (self.repo / "state/budget.json").write_text(json.dumps(dict(
            version=1, token_cap_total=1000000, tokens_spent=0, wall_clock_cap_seconds=3600,
            wall_clock_elapsed_seconds=0, clock_tick_cap=100, clock_ticks_used=0,
            consecutive_failure_cap=3, consecutive_failures=0, halted=False,
            window_started_at="2026-10-03")))
        for stage in self.state["stages"]:
            self.card(stage["id"])
        self.git("add", "stage-cards")
        self.git("commit", "-qm", "fixture cards")

    def tick(self, budget=True, quota=True, network=True):
        self.env.update(GRAPH_BUDGET="0" if budget else "1", GRAPH_QUOTA="0" if quota else "1",
                        GRAPH_NETWORK="0" if network else "1")
        self.run_cmd(["bash", "-c", '''
source "$1/scripts/tick.sh"
log() { printf '%s\n' "$*" >&2; }
quota_write_repo_state() { return 0; }
budget_ensure_window() { return 0; }
budget_pause_active() { return 1; }
budget_drain_active() { return 1; }
budget_check_caps() { return 0; }
budget_gate_dispatch() { return "$GRAPH_BUDGET"; }
quota_gate_role_dispatch() { QUOTA_GATE_RESOLVED_WINDOW=normal; return "$GRAPH_QUOTA"; }
network_preflight_ok() { NETWORK_PREFLIGHT_REASON=fixture; return "$GRAPH_NETWORK"; }
commit_state_branch() { return 0; }
resolve_base_branch() { printf 'dev\n'; }
_process_repo_locked "$2" ""
''', "graph-tick", str(self.harness_root), str(self.repo)])

    def test_restart_does_not_dispatch_twice_and_guards_still_hold(self):
        self.state["stages"] = [self.a, self.b, self.child]
        self.harness()
        self.save()
        self.tick()
        self.assertFalse(self.spawn_log.exists(), "join ran before its second parent landed")
        self.git("merge", "--no-edit", "unlanded")
        self.b["integration"]["state"] = "merged"
        self.save()
        for options in [dict(budget=False), dict(quota=False), dict(network=False)]:
            with self.subTest(options=options):
                self.tick(**options)
                self.assertFalse(self.spawn_log.exists(), "graph bypassed dispatch admission")
                self.assertEqual(self.read_state()["stages"][2]["status"], "pending")
        self.tick()
        self.assertEqual(self.spawn_log.read_text().splitlines(), ["03-join"])
        self.assertEqual(self.read_state()["current_stage"], "03-join")
        self.tick()
        self.assertEqual(self.spawn_log.read_text().splitlines(), ["03-join"], "restart duplicated worker")
        self.assertEqual(self.read_state()["stages"][2]["status"], "in_progress")

    def test_unrelated_work_can_run_after_a_failed_parent(self):
        self.b["status"] = "failed"
        self.harness()
        self.save()
        self.tick()
        self.assertEqual(self.spawn_log.read_text().splitlines(), ["04-independent"])
        self.assertEqual(self.read_state()["stages"][2]["status"], "pending")

    def test_admission_and_restart_control_without_dependencies(self):
        self.state["stages"] = [self.free]
        self.harness()
        self.save()
        for options in [dict(budget=False), dict(quota=False), dict(network=False)]:
            self.tick(**options)
            self.assertFalse(self.spawn_log.exists())
        self.tick()
        self.tick()
        self.assertEqual(self.spawn_log.read_text().splitlines(), ["04-independent"])
        self.assertEqual(self.read_state()["stages"][0]["status"], "in_progress")

    def test_operator_command_uses_the_same_read_only_report(self):
        self.assertTrue((ROOT / "scripts/dependency-graph.sh").exists(), "graph inspector missing")
        before = {p: p.read_bytes() for p in (self.repo / "state").rglob("*") if p.is_file()}
        refs = self.git("show-ref")
        result = self.run_cmd(["bash", str(ROOT / "bin/autometta"), "graph", "--repo", str(self.repo), "--json"])
        self.assertEqual(json.loads(result.stdout), self.inspect())
        text = self.run_cmd(["bash", str(ROOT / "bin/autometta"), "graph", "--repo", str(self.repo)]).stdout
        for phrase in ["03-join", "01-parent", "02-parent", "awaiting-integration"]:
            self.assertIn(phrase, text)
        self.assertIn("depend", text.lower())
        self.assertEqual({p: p.read_bytes() for p in (self.repo / "state").rglob("*") if p.is_file()}, before)
        self.assertEqual(self.git("show-ref"), refs)
        self.child["depends_on"] = ["99-missing"]
        self.save()
        result = self.run_cmd(["bash", str(ROOT / "bin/autometta"), "graph", "--repo", str(self.repo), "--json"], check=False)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(json.loads(result.stdout)["valid"])


classes = {"inspect": Inspect, "dispatch": Dispatch, "lifecycle": Lifecycle}
suite = unittest.TestSuite()
for mode, cls in classes.items():
    if MODE in {mode, "all"}:
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(cls))
result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
# AUTOMETTA-CONTRACT-END
