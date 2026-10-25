"""Durable advisory notices; runtime state remains the authority."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time


RETENTION_SECONDS = 7 * 86400


def home():
    for name in ("AUTOMETTA_HOME", "PHAT_CONTROLLER_HOME"):
        if os.environ.get(name):
            return Path(os.environ[name]).expanduser()
    current = Path.home() / ".autometta"
    legacy = Path.home() / ".phat-controller"
    return current if current.exists() or not legacy.exists() else legacy


def emit(repo, kind, episode, stage="", **details):
    try:
        repo = str(Path(repo).resolve())
        key = hashlib.sha256(json.dumps([repo, kind, episode, stage]).encode()).hexdigest()
        directory = home() / "lifecycle-events"
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = directory / (key + ".json")
        if path.exists():
            return
        record = dict(id=key, repo=repo, kind=kind, stage=stage,
                      created_at=datetime.now(timezone.utc).isoformat(), **details)
        fd, temporary = tempfile.mkstemp(dir=directory, prefix=".event-")
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(record, output, ensure_ascii=True)
            # A hard link publishes complete bytes without replacing an episode
            # another producer has already published.
            try:
                os.link(temporary, path)
            except FileExistsError:
                pass
        finally:
            os.unlink(temporary)
        cutoff = time.time() - RETENTION_SECONDS
        for old in directory.glob("*.json"):
            if old.stat().st_mtime < cutoff:
                old.unlink(missing_ok=True)
    except Exception:
        pass


def records(repos):
    allowed = {str(Path(repo).resolve()) for repo in repos}
    notices = []
    cutoff = time.time() - RETENTION_SECONDS
    for path in (home() / "lifecycle-events").glob("*.json"):
        try:
            if path.stat().st_mtime < cutoff:
                continue
            record = json.loads(path.read_text())
            if (record["repo"] in allowed and isinstance(record.get("created_at"), str)
                    and isinstance(record.get("id"), str) and isinstance(record.get("kind"), str)):
                notices.append(dict(record, path=str(path), record_type="lifecycle"))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return sorted(notices, key=lambda item: (item["created_at"], item["id"]))


def agent_event(repo, doc, finished=False):
    try:
        _agent_event(repo, doc, finished)
    except Exception:
        pass


def _agent_event(repo, doc, finished):
    role = doc.get("role")
    if role not in ("worker", "verifier"):
        return
    stage = doc.get("stage_id") or Path(doc.get("card_path") or "unknown").stem
    episode = doc.get("agent_id") or f'{doc.get("pid")}:{doc.get("started_at")}'
    evidence = doc.get("log_path") or "state/active-agents"
    result = "started"
    if finished:
        result = "unknown"
        candidates = ([f"state/envelopes/{stage}.json", f"state/handoffs/{stage}.json"]
                      if role == "worker" else [f"state/verifiers/{stage}.json"])
        for relative in candidates:
            path = Path(repo) / relative
            try:
                started = datetime.fromisoformat(doc["started_at"].replace("Z", "+00:00")).timestamp()
                if path.stat().st_mtime < started:
                    continue
                artifact = json.loads(path.read_text())
                if not isinstance(artifact, dict):
                    continue
                verdict = artifact.get("status" if role == "worker" else "overall")
                accepted = ("pass", "partial", "fail") if role == "worker" else ("PASS", "FAIL")
                if verdict in accepted:
                    result, evidence = verdict, str(path)
                    break
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                continue
    summary = f'{role.capitalize()} {"finished" if finished else "started"}: {result}'
    if finished and result == "unknown":
        summary += "; process exited without a fresh verdict; success is unconfirmed"
    emit(repo, f'{role}_{"finished" if finished else "started"}', episode, stage,
         summary=summary, result=result, evidence=evidence,
         card=doc.get("card_path"), agent_id=episode, outcome=doc.get("outcome"))


def stage_changes(repo, before, after):
    old = {s["id"]: s for s in before.get("stages", [])}
    stages = after.get("stages", [])
    for stage in stages:
        previous = old.get(stage["id"], {})
        integration = stage.get("integration") or {}
        previous_integration = previous.get("integration") or {}
        status = stage.get("status")
        if status in ("stalled", "verifier_failed", "failed") and previous.get("status") != status:
            emit(repo, "stage_blocked", [stage.get("started_at"), stage.get("verifier_started_at"), status],
                 stage["id"], summary=f"Stage needs attention: {status}",
                 evidence=str(Path(repo) / "state/state.yaml"))
        if status != "completed":
            continue
        if previous.get("status") == status and previous_integration.get("state") == integration.get("state"):
            continue
        outcome = integration.get("state", "unrecorded")
        commit = integration.get("rebased_tip") or integration.get("head") or stage.get("commit")
        if outcome == "merged":
            kind, summary = "stage_landed", f"Stage landed: {commit or 'commit unavailable'}"
        elif outcome == "awaiting":
            kind, summary = "stage_awaiting_integration", "Verifier PASS; awaiting integration, not landed"
        else:
            kind, summary = "stage_finished", "Stage completed; integration was not recorded"
        emit(repo, kind, [stage.get("started_at"), stage.get("completed_at"), commit, outcome],
             stage["id"], summary=summary, commit=commit, integration=outcome,
             evidence=str(Path(repo) / "state/state.yaml"))
    def finished(items):
        return any(s.get("status") == "completed" for s in items) and all(
            s.get("status") in ("completed", "superseded") and
            (s.get("integration") or {}).get("state") != "awaiting" for s in items)
    for run_id in {s.get("run_id") for s in stages}:
        current = [s for s in stages if s.get("run_id") == run_id]
        previous = [s for s in before.get("stages", []) if s.get("run_id") == run_id]
        if previous and finished(current) and not finished(previous):
            emit(repo, "run_finished", [run_id, [[s["id"], s.get("completed_at"), s.get("commit")] for s in current]],
                 summary=f'Run {run_id or "(legacy)"} finished: all remaining stages completed; none awaiting integration',
                 run_id=run_id, evidence=str(Path(repo) / "state/state.yaml"))


def main():
    try:
        mode, repo, *args = sys.argv[1:]
        if mode == "state":
            stage_changes(repo, json.loads(Path(args[0]).read_text()), json.loads(Path(args[1]).read_text()))
        elif mode == "halt":
            budget = json.loads((Path(repo) / "state/budget.json").read_text())
            if budget.get("halted") is not True:
                return
            emit(repo, "run_blocked", [budget.get("halted_at"), budget.get("halt_reason")],
                 summary=f'Run blocked: {budget.get("halt_reason", "unknown")}',
                 evidence=str(Path(repo) / "state/budget.json"))
    except Exception:
        pass


if __name__ == "__main__":
    main()
