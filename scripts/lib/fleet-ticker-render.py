#!/usr/bin/env python3
"""fleet-ticker-render.py: the sole renderer for the fleet page (card 66),
the sibling of scripts/lib/repo-ticker-render.py (card 63) one level up.

Two modes, selected by argv[1]:

  fleet  -- the fleet-wide page: TOTALS across every enabled subscriber and
            a REPOS table, one row per subscriber. Reachable on purpose (a
            dedicated tmux window / `attach.sh --fleet-ticker`); never the
            landing view for a per-repo session.
  repo   -- the repo-scoped page: TOTALS for one repo, no REPOS table. This
            is window 0 of the per-repo viewer.

Both modes share one ESCALATIONS table: every halted, paused, attempt-capped
or stale-vendor repo, every stage in an alert status, and every live agent
that is over its budget. A repo nobody needs to act on earns no row.

Reads its payload from AUTOMETTA_FLEET_PAYLOAD (fleet mode: the parsed
contents of dashboard/data.json; repo mode: one repo object, the same shape
`aggregate-dashboard.sh --repo` already gives scripts/repo-ticker.sh) and
never opens a file of its own -- the aggregation boundary from card 63
applies here too: a sum, a count or a group-by is aggregate-dashboard.sh's
job, and this file only selects rows to display and does arithmetic on
scalars the payload already carries.

Usage: fleet-ticker-render.py <mode> <scope> <width> <height> <stale_seconds>
"""
import importlib.util
import json
import os
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "repo_ticker_render", os.path.join(_LIB_DIR, "repo-ticker-render.py"))
_repo_ticker_render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_repo_ticker_render)

# Reused rather than reimplemented (card 66 inputs): the column-allocation
# algorithm, ANSI-safe fit/pad, and the shared formatting helpers all come
# from card 63's renderer so the two pages never disagree about how a token
# count, a duration or a truncation reads.
allocate_columns = _repo_ticker_render.allocate_columns
pad = _repo_ticker_render.pad
fit = _repo_ticker_render.fit
short_tokens = _repo_ticker_render.short_tokens
short_secs = _repo_ticker_render.short_secs
parse_iso = _repo_ticker_render.parse_iso
identity_short = _repo_ticker_render.identity_short
RED = _repo_ticker_render.RED
YELLOW = _repo_ticker_render.YELLOW
DIM = _repo_ticker_render.DIM
BOLD = _repo_ticker_render.BOLD

try:
    ALERT_STAGE_STATUSES = frozenset(json.loads(os.environ.get("AUTOMETTA_ALERT_STATUSES_JSON") or "[]"))
except ValueError:
    ALERT_STAGE_STATUSES = frozenset()


def relative_age(stamp, now):
    epoch = parse_iso(stamp) if isinstance(stamp, str) else None
    if epoch is None:
        return "never"
    age = max(0, now - epoch)
    if age < 120:
        return "%ds ago" % age
    if age < 3600:
        return "%dm" % (age // 60)
    if age < 86400:
        return "%dh" % (age // 3600)
    return "%dd" % (age // 86400)


# --------------------------------------------------------------- REPOS state

def repo_state_text(repo):
    if repo.get("state_error"):
        return "state unreadable: %s" % repo["state_error"]
    if repo.get("halted"):
        return "HALTED: %s" % (repo.get("halt_reason") or "budget")
    for stage in repo.get("stages") or []:
        if stage.get("status") in ALERT_STAGE_STATUSES:
            return "STALLED: %s" % (stage.get("id") or "unknown")
    paused_until = repo.get("paused_until")
    now = int(time.time())
    if isinstance(paused_until, (int, float)) and paused_until > now:
        return "PAUSED: %s" % (repo.get("paused_reason") or "provider limit")
    agents = repo.get("agents") or []
    if agents:
        return "running %s" % (agents[0].get("stage_id") or "unknown")
    queue = repo.get("queue") or []
    if queue:
        return "queued %s" % (queue[0].get("stage_id") or "unknown")
    return "idle"


def render_totals(payload, width, scoped):
    lines = [BOLD("TOTALS")]
    if scoped:
        spend = payload.get("spend") or {}
        enabled_text = ""
        today_tokens = spend.get("tokens_total", 0)
        today_cost = spend.get("cost_usd_est", 0)
        window_spent = payload.get("tokens_spent", 0)
        window_cap = payload.get("effective_token_cap") or payload.get("token_cap_total") or 0
    else:
        totals = payload.get("fleet_totals") or {}
        spend = payload.get("spend") or {}
        enabled_text = "enabled: %s  " % totals.get("enabled_repos", 0)
        today_tokens = spend.get("tokens_total", totals.get("today_tokens", 0))
        today_cost = spend.get("cost_usd_est", totals.get("today_cost_usd_est", 0))
        window_spent = totals.get("window_tokens_spent", 0)
        window_cap = totals.get("window_token_cap_total", 0)
    line = "  %stoday: %s tokens / $%.2f est  window: %s / %s tokens" % (
        enabled_text, short_tokens(today_tokens), today_cost or 0.0,
        short_tokens(window_spent), short_tokens(window_cap))
    lines.append(fit(line, width))
    return lines


# ------------------------------------------------------- row layout (shared)

def wrap_groups(order, widths, avail, sep=2):
    """Greedily place fixed-width columns onto physical lines, never
    splitting a column: a column that would push a line past `avail` starts
    a new one instead. Every column entering here already carries its
    natural (or drop-survived) width, so a group's own join always fits --
    the row-level fit() below this becomes a no-op safety net rather than
    the truncation mechanism it used to be (re-brief attempt 3, criterion
    4: identifying and enumeration columns never drop and never truncate;
    when they alone outgrow the frame the row wraps instead)."""
    groups = []
    current = []
    used = 0
    for name in order:
        w = widths[name]
        add = w if not current else w + sep
        if current and used + add > avail:
            groups.append(current)
            current = [name]
            used = w
        else:
            current.append(name)
            used += add
    if current:
        groups.append(current)
    return groups


def render_grouped_lines(cells, order, widths, aligns, avail, indent="    "):
    lines = []
    for i, group in enumerate(wrap_groups(order, widths, avail)):
        parts = [pad(cells[n], widths[n], aligns.get(n, "left")) for n in group]
        text = "  ".join(parts)
        lines.append(text if i == 0 else indent + text)
    return lines


# ------------------------------------------------------------------- REPOS

def repo_row_priority(repo):
    """Rows that carry an operator condition survive a tight page first."""
    if repo.get("halted"):
        return 0
    if any(s.get("status") in ALERT_STAGE_STATUSES for s in (repo.get("stages") or [])):
        return 1
    cap = repo.get("consecutive_failure_cap") or 0
    if cap > 0 and (repo.get("consecutive_failures") or 0) >= cap:
        return 2
    if repo.get("state_error"):
        return 3
    paused_until = repo.get("paused_until")
    if isinstance(paused_until, (int, float)) and paused_until > int(time.time()):
        return 4
    if repo.get("vendor_stale"):
        return 5
    if any("over-budget" in (a.get("flags") or []) for a in (repo.get("agents") or [])):
        return 6
    if repo.get("agents") or repo.get("queue"):
        return 7
    return 8


def render_repos(payload, width, row_limit=None):
    repos = [r for r in (payload.get("repos") or []) if r.get("enabled")]
    lines = [BOLD("REPOS")]
    if not repos:
        lines.append("  " + DIM("no enabled subscribers"))
        return lines

    rows = []
    for source_index, repo in enumerate(repos):
        name = repo.get("name") or "unknown"
        state = repo_state_text(repo)
        queue = str(repo.get("queue_depth", 0))
        window_spend = "%s/%s" % (short_tokens(repo.get("tokens_spent", 0)),
                                   short_tokens(repo.get("effective_token_cap") or repo.get("token_cap_total") or 0))
        today = short_tokens((repo.get("spend") or {}).get("tokens_total", 0))
        rows.append({"repo": name, "state": state, "queue": queue,
                     "window": window_spend, "today": today,
                     "_priority": repo_row_priority(repo), "_index": source_index})

    rows.sort(key=lambda r: (r["_priority"], r["_index"]))
    total_rows = len(rows)
    if row_limit is not None:
        rows = rows[:max(0, row_limit)]
    hidden_rows = total_rows - len(rows)
    if not rows:
        lines.append("  " + DIM("and %d more - see failures-history" % hidden_rows))
        return lines

    columns = [
        {"name": "repo", "min": max(len("repo"), max(len(r["repo"]) for r in rows)), "weight": 1},
        {"name": "state", "min": max(len("state"), max(len(r["state"]) for r in rows)), "weight": 1},
        # Least-actionable dropped first at a narrow width: "today" (a second
        # spend figure once "window" is shown), then "queue" (a count the
        # REPOS state text often already names via "queued <id>"), keeping
        # "window" spend against cap -- the figure deliverable 3 names by
        # name -- as the last column to give up.
        {"name": "today", "min": max(len("today"), max(len(r["today"]) for r in rows)),
         "weight": 0, "droppable": True, "drop_rank": 3},
        {"name": "queue", "min": max(len("q"), max(len(r["queue"]) for r in rows)),
         "weight": 0, "droppable": True, "drop_rank": 2},
        {"name": "window", "min": max(len("window"), max(len(r["window"]) for r in rows)),
         "weight": 0, "droppable": True, "drop_rank": 1},
    ]
    widths, dropped = allocate_columns(max(1, width - 2), columns)
    order = [c["name"] for c in columns if c["name"] in widths]
    header_map = {"repo": "repo", "state": "state", "queue": "q", "window": "window", "today": "today"}
    aligns = {"queue": "right"}
    avail = max(1, width - 2)
    if dropped:
        lines.append("  columns hidden: %s" % ", ".join(header_map[n] for n in dropped))
    for hl in render_grouped_lines(header_map, order, widths, aligns, avail):
        lines.append("  " + fit(hl, avail))
    for r in rows:
        for rl in render_grouped_lines(r, order, widths, aligns, avail):
            lines.append("  " + fit(rl.rstrip(), avail))
    if hidden_rows:
        lines.append("  " + DIM("and %d more - see failures-history" % hidden_rows))
    return lines


# ------------------------------------------------------------- ESCALATIONS

def collect_escalation_rows(repos, now):
    rows = []

    def add(priority, row):
        row["_priority"] = priority
        row["_index"] = len(rows)
        rows.append(row)

    for repo in repos:
        name = repo.get("name") or "unknown"
        if repo.get("halted"):
            add(0, {"repo": name, "result": "halted", "stage": "-", "role": "-",
                    "identity": "-", "detail": repo.get("halt_reason") or "budget"})
        if repo.get("vendor_stale"):
            add(5, {"repo": name, "result": "vendor-stale", "stage": "-", "role": "-",
                    "identity": "-", "detail": "from %s, run: autometta refresh-repo %s" % (
                        repo.get("vendor_from") or "unknown", repo.get("repo_path") or name)})
        paused_until = repo.get("paused_until")
        if isinstance(paused_until, (int, float)) and paused_until > now:
            add(4, {"repo": name, "result": "paused", "stage": "-", "role": "-", "identity": "-",
                    "detail": "%s, resumes in %s" % (
                        repo.get("paused_reason") or "provider limit",
                        short_secs(paused_until - now))})
        cap = repo.get("consecutive_failure_cap") or 0
        failures = repo.get("consecutive_failures") or 0
        if cap > 0 and failures >= cap:
            add(2, {"repo": name, "result": "attempt-cap", "stage": "-", "role": "-",
                    "identity": "-", "detail": "%s/%s" % (failures, cap)})
        for stage in repo.get("stages") or []:
            status = stage.get("status")
            if status not in ALERT_STAGE_STATUSES:
                continue
            detail = stage.get("wip_branch") or stage.get("verifier_overall") or "-"
            add(1, {"repo": name, "result": status, "stage": stage.get("id") or "unknown",
                    "role": "-", "identity": "-", "detail": detail})
        for agent in repo.get("agents") or []:
            flags = agent.get("flags") or []
            if "over-budget" not in flags:
                continue
            add(3, {"repo": name, "result": "over-budget", "stage": agent.get("stage_id") or "unknown",
                    "role": agent.get("role") or "unknown",
                    "identity": identity_short(agent.get("identity")), "detail": "-"})
        for alert in repo.get("alerts") or []:
            occurred_epoch = parse_iso(alert.get("occurred_at")) if isinstance(alert.get("occurred_at"), str) else None
            if not occurred_epoch or (now - occurred_epoch) >= 86400:
                continue
            # The message, not the log path, is what the operator needs to
            # read: a long log filename ahead of it ate the whole truncation
            # budget and left the actual provider-limit text unreadable.
            add(6, {"repo": name, "result": "provider-limit", "stage": "-", "role": "-", "identity": "-",
                    "detail": alert.get("line") or "provider limit"})
    return sorted(rows, key=lambda r: (r["_priority"], r["_index"]))


def render_escalations(repos, width, now, show_repo, row_limit=None):
    rows = collect_escalation_rows(repos, now)
    lines = [BOLD("ESCALATIONS")]
    if not rows:
        lines.append("  " + DIM("no outstanding escalations"))
        return lines

    total_rows = len(rows)
    if row_limit is not None:
        rows = rows[:max(0, row_limit)]
    hidden_rows = total_rows - len(rows)
    if not rows:
        lines.append("  " + DIM("and %d more - see failures-history" % hidden_rows))
        return lines

    def col(name, header):
        return max(len(header), max(len(r[name]) for r in rows))

    # repo, result, role, identity and stage are all identifying or
    # enumeration columns (criterion 4): each is fixed to its natural
    # width, never shrunk and never truncated. Unlike REPOS's droppable
    # detail figures, none of these five ever drop either -- "detail" (the
    # halt/pause/wip reason) is the one column allowed to give up whole or
    # to ellipsis, so it is not in this set at all; it is appended to the
    # last physical line separately, below. When the five columns' natural
    # widths do not fit one line, render_grouped_lines wraps rather than
    # shrinking any of them (re-brief attempt 3's drop-then-wrap rule).
    order = (["repo"] if show_repo else []) + ["result", "stage", "role", "identity"]
    header_map = {"repo": "repo", "result": "result", "stage": "stage", "role": "role", "identity": "identity"}
    widths = {n: col(n, header_map[n]) for n in order}

    avail = max(1, width - 2)
    for hl in render_grouped_lines(header_map, order, widths, {}, avail):
        lines.append("  " + fit(hl, avail))

    for r in rows:
        row_lines = render_grouped_lines(r, order, widths, {}, avail)
        if r["detail"] and r["detail"] != "-":
            last = row_lines[-1]
            remaining = max(0, avail - len(last) - 2)
            if remaining > 4:
                row_lines[-1] = last + "  " + fit(r["detail"], min(remaining, 60))
        for rl in row_lines:
            lines.append("  " + fit(rl.rstrip(), avail))
    if hidden_rows:
        lines.append("  " + DIM("and %d more - see failures-history" % hidden_rows))
    return lines


# ------------------------------------------------------------------- frame

def build_frame(mode, scope, payload, width, height, stale_seconds, build_sha, build_warning):
    now = int(time.time())

    if mode == "fleet":
        heading = BOLD("autometta %s fleet" % build_sha)
    else:
        name = (payload or {}).get("name") or os.path.basename((scope or "repo").rstrip("/"))
        heading = BOLD(name) + "  " + DIM("fleet-wide view: tmux window \"fleet\"")

    if payload is None:
        lines = [heading, ""]
        if mode == "fleet":
            lines.append(RED("FLEET DATA MISSING"))
            lines.append(DIM("Run `autometta dashboard`; an empty fleet is not assumed healthy."))
        else:
            lines.append(RED("no data: %s is not an enabled subscriber, or the aggregator failed" % scope))
        return [fit(l, width) for l in lines]

    repos = [r for r in (payload.get("repos") or []) if r.get("enabled")] if mode == "fleet" else []
    repos_for_escalations = repos if mode == "fleet" else [payload]
    repo_limit = len(repos)
    escalation_limit = len(collect_escalation_rows(repos_for_escalations, now))

    def assemble():
        lines = [heading]
        generated_at = payload.get("generated_at") if mode == "fleet" else None
        if generated_at:
            generated_epoch = parse_iso(generated_at) or 0
            age = now - generated_epoch
            lines.append("Data generated: %s" % relative_age(generated_at, now))
            if generated_epoch == 0 or age > stale_seconds:
                lines.append(RED(BOLD("FLEET DATA STALE: generated %s (limit %ss)" % (
                    relative_age(generated_at, now), stale_seconds))))
            drain = payload.get("drain") or {}
            if drain.get("active"):
                lines.append(YELLOW(BOLD("DRAIN cap %s, expires %s" % (drain.get("cap"), drain.get("expires_at")))))
        if build_warning:
            lines.append(YELLOW(BOLD(build_warning)))
        lines.append("")
        lines.extend(render_totals(payload, width, mode == "repo"))
        lines.append("")
        if mode == "fleet":
            lines.extend(render_repos(payload, width, repo_limit))
            lines.append("")
        lines.extend(render_escalations(
            repos_for_escalations, width, now, mode == "fleet", escalation_limit))
        return lines

    # A fleet page is deliberately bounded to 39 content lines, leaving the
    # fortieth line for attach.sh's refresh footer. `height` may be larger in
    # a capture: it is a smaller-pane constraint, never permission to grow an
    # unbounded page or a slice boundary. Low-priority REPOS rows yield first;
    # only then do the lowest-priority escalation rows yield. Both renderers
    # add an explicit history pointer when they withhold anything.
    page_budget = max(1, min(max(1, height - 1), 39))
    lines = assemble()
    while len(lines) > page_budget and mode == "fleet" and repo_limit > 0:
        repo_limit -= 1
        lines = assemble()
    while len(lines) > page_budget and escalation_limit > 0:
        escalation_limit -= 1
        lines = assemble()
    return [fit(l, width) for l in lines]


def main():
    if len(sys.argv) != 6:
        sys.stderr.write("usage: %s <mode> <scope> <width> <height> <stale_seconds>\n" % sys.argv[0])
        return 2
    mode, scope, width, height, stale_seconds = sys.argv[1:]
    payload_raw = os.environ.get("AUTOMETTA_FLEET_PAYLOAD", "")
    try:
        payload = json.loads(payload_raw) if payload_raw.strip() else None
    except ValueError:
        payload = None
    build_sha = os.environ.get("AUTOMETTA_BUILD_SHA", "unknown")
    build_warning = os.environ.get("AUTOMETTA_BUILD_WARNING", "")
    frame = build_frame(mode, scope, payload, int(width), int(height), int(stale_seconds),
                         build_sha, build_warning)
    sys.stdout.write("\n".join(frame))
    return 0


if __name__ == "__main__":
    sys.exit(main())
