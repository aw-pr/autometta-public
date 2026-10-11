#!/usr/bin/env python3
"""Attach each stage's card text to a rendered dashboard payload.

A file:// page cannot fetch a sibling file, so a card the reader can open has
to travel in the data. This runs from dashboard.sh rather than from
aggregate-dashboard.sh because the ticker calls the aggregator every 120s per
repo and has no use for card bodies.

Usage: attach-card-text.py <data.json> <data.js>
"""
import json
import os
import sys
import tempfile

# The same cap as the TUI's card pane: past this a card has gone wrong, and a
# dashboard is not the place to read it whole.
MAX_LINES = 400


def card_text(root, card):
    path = card if os.path.isabs(card) else os.path.join(root, card)
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        return "could not read %s: %s" % (card, error)
    text = "\n".join(lines[:MAX_LINES])
    if len(lines) > MAX_LINES:
        text += "\n\n... %d more line(s); open %s" % (len(lines) - MAX_LINES, card)
    return text


def replace_atomically(path, write):
    """Write through a temporary file beside path, then rename it over path."""
    directory = os.path.dirname(os.path.abspath(path))
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        mode = 0o600
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".attach-")
    try:
        with os.fdopen(descriptor, "w") as handle:
            write(handle)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def write_js(handle, data):
    handle.write("window.AUTOMETTA_DATA = ")
    json.dump(data, handle)
    handle.write(";\n")


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: attach-card-text.py <data.json> <data.js>\n")
        return 2
    data_path, js_path = sys.argv[1:3]
    try:
        with open(data_path) as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:
        sys.stderr.write("attach-card-text.py: cannot read %s: %s\n" % (data_path, error))
        return 1

    for repo in data.get("repos") or []:
        root = repo.get("repo_path") or ""
        for stage in repo.get("stages") or []:
            card = stage.get("card")
            if card:
                stage["card_text"] = card_text(root, card)

    replace_atomically(data_path, lambda handle: json.dump(data, handle))
    replace_atomically(js_path, lambda handle: write_js(handle, data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
