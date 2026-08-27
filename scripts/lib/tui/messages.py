#!/usr/bin/env python3
"""Read and write the phat-controller filesystem message bus."""
import datetime
import json
import os
import re


def _state_path(repo_root, *parts):
    return os.path.join(repo_root, "state", *parts)


def _single_line(value):
    return " ".join(str(value or "").split())


def _clock_from_iso(stamp):
    if not isinstance(stamp, str):
        return "?"
    match = re.search(r"T(\d\d:\d\d)", stamp)
    return match.group(1) if match else "?"


def _clock_from_epoch(epoch):
    return datetime.datetime.fromtimestamp(epoch).strftime("%H:%M")


def _read_text(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def _journal(repo_root):
    path = _state_path(repo_root, "phat-controller-journal.jsonl")
    rows = []
    refusal_ids = set()
    if not os.path.isfile(path):
        return rows, refusal_ids
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            try:
                row = json.loads(raw)
            except (TypeError, ValueError):
                continue
            if not isinstance(row, dict):
                continue
            phase = row.get("phase") or "decision"
            refused = row.get("verb") == "inbox-refuse" or row.get("result") == "refused"
            kind = "refusal" if refused else ("outcome" if phase == "outcome" else "decision")
            summary = row.get("summary")
            if summary is None:
                summary = row.get("note") if phase == "outcome" else row.get("rationale")
            rows.append({
                "time": _clock_from_iso(row.get("ts")),
                "kind": kind,
                "summary": _single_line(summary or row.get("verb") or row.get("result") or "recorded"),
            })
            if refused:
                message_id = row.get("message_id")
                if not message_id:
                    evidence = str(row.get("evidence") or "")
                    match = re.search(r"\binbox message ([^ (]+)", evidence)
                    message_id = match.group(1) if match else None
                if message_id:
                    refusal_ids.add(str(message_id))
    return rows, refusal_ids


def _message_files(directory):
    if not os.path.isdir(directory):
        return []
    rows = []
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            continue
        try:
            rows.append((name.rsplit(".", 1)[0], _read_text(path), os.path.getmtime(path)))
        except OSError:
            continue
    return rows


def read_bus(repo_root):
    """Return journal and time-interleaved conversation rows for one repo."""
    journal, refusal_ids = _journal(repo_root)
    pending = _state_path(repo_root, "phat-controller-inbox", "pending")
    processed = _state_path(repo_root, "phat-controller-inbox", "processed")
    outbox = _state_path(repo_root, "phat-controller-outbox")
    conversation = []
    for status, directory in (("pending", pending), ("processed", processed)):
        for message_id, body, modified in _message_files(directory):
            conversation.append({
                "id": message_id,
                "speaker": "you",
                "time": _clock_from_epoch(modified),
                "timestamp": modified,
                "status": status,
                "text": _single_line(body),
            })
    for message_id, body, modified in _message_files(outbox):
        conversation.append({
            "id": message_id,
            "speaker": "ctrl",
            "time": _clock_from_epoch(modified),
            "timestamp": modified,
            "status": "refusal" if message_id in refusal_ids else "reply",
            "text": _single_line(body),
        })
    conversation.sort(key=lambda row: (row["timestamp"], 0 if row["speaker"] == "you" else 1, row["id"]))
    return {"journal": journal, "conversation": conversation}


def write_pending(repo_root, message):
    """Write one single-line operator message and return its message id."""
    body = str(message or "").replace("\r", " ").replace("\n", " ").strip()
    if not body:
        raise ValueError("message is empty")
    pending = _state_path(repo_root, "phat-controller-inbox", "pending")
    os.makedirs(pending, mode=0o700, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    for suffix in range(100):
        message_id = "operator-%s-%d-%02d" % (stamp, os.getpid(), suffix)
        path = os.path.join(pending, message_id + ".md")
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(body + "\n")
        return message_id
    raise OSError("could not allocate a unique pending message name")
