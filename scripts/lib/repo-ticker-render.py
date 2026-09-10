#!/usr/bin/env python3
"""repo-ticker-render.py: the sole renderer for scripts/repo-ticker.sh.

Reads the single-repo aggregated JSON (scripts/aggregate-dashboard.sh
--repo, the one walker in the tree) from the AUTOMETTA_TICKER_PAYLOAD
environment variable and prints exactly one frame: NOW, NEXT, ESCALATIONS,
SPEND AND LOSS, FRESHNESS, in that order (card 63). Never reads state.yaml,
cost-log.jsonl, budget.json or a transcript directly -- every figure here
is already in the payload, so there is exactly one place any of them could
be computed wrong.

Aggregation boundary (criterion 9): a figure derived by iterating or
grouping over multiple payload records (a count, a sum, a group-by) is an
aggregate and belongs in aggregate-dashboard.sh, so this file never does
that -- see queue_counts in render_next. A figure derived by arithmetic on
scalars the payload already carries (a percentage of two counters, "now"
minus a timestamp, a threshold comparison) is presentation, not a new fact
about the fleet, and stays here -- see the elapsed/budget and cap
percentages and the freshness age below. The freshness age specifically
cannot move: it is "now" relative to a fixed timestamp, and "now" is only
meaningful at render time, one 5s-refresh reading behind the moment the
aggregator ran.

Usage: repo-ticker-render.py <repo_root> <width> <height> <interval> <freshness_threshold>
"""
import calendar
import json
import os
import re
import sys
import time

USE_COLOUR = sys.stdout.isatty() and not os.environ.get("NO_COLOUR") and not os.environ.get("NO_COLOR")

# The one definition of which stage statuses are alert-worthy lives in
# scripts/alert-statuses.sh; scripts/repo-ticker.sh sources it and passes
# the same JSON array through here rather than this file enumerating its
# own copy (scripts/superseded-status-smoke.sh asserts there is exactly
# one definition in the tree, so no fallback literal belongs here either).
try:
    ALERT_STAGE_STATUSES = frozenset(json.loads(os.environ.get("AUTOMETTA_ALERT_STATUSES_JSON") or "[]"))
except ValueError:
    ALERT_STAGE_STATUSES = frozenset()


def paint(text, code):
    return "\x1b[%sm%s\x1b[0m" % (code, text) if USE_COLOUR else text


def RED(s): return paint(s, "31")
def YELLOW(s): return paint(s, "33")
def DIM(s): return paint(s, "2")
def BOLD(s): return paint(s, "1")


def build_warning(payload):
    check = (payload or {}).get("build_check") or {}
    status = check.get("status")
    if status == "stale":
        return "BUILD STALE installed %s, checkout %s" % (
            check.get("installed_sha") or "unknown",
            check.get("checkout_sha") or "unknown")
    if status == "unreadable":
        return "BUILD CHECK UNREADABLE"
    return ""


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def strip_ansi(s):
    return ANSI_RE.sub("", s)


def fit(line, width):
    """Truncate on printable width, keeping escape codes intact."""
    plain = strip_ansi(line)
    if len(plain) <= width:
        return line
    if line == plain:
        return line[:max(0, width - 1)] + "…"
    return plain[:max(0, width - 1)] + "…" + "\x1b[0m"


def short_tokens(n):
    n = int(n or 0)
    if n >= 1_000_000_000:
        return "%.1fB" % (n / 1_000_000_000)
    if n >= 1_000_000:
        return "%.1fM" % (n / 1_000_000)
    if n >= 1_000:
        return "%.1fK" % (n / 1_000)
    return str(n)


def short_secs(s):
    try:
        s = int(s)
    except (TypeError, ValueError):
        return "?"
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm%02ds" % (s // 60, s % 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)


def parse_iso(ts):
    if not ts:
        return None
    ts = ts.strip().strip('"').strip("'")
    for f in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return calendar.timegm(time.strptime(ts, f))
        except ValueError:
            continue
    return None


def identity_short(identity):
    if not identity:
        return "-"
    return identity.split("<")[0].strip()


def family_from_identity(identity):
    s = (identity or "").lower()
    if "claude" in s:
        return "claude"
    if "codex" in s or "gpt" in s or "chatgpt" in s:
        return "codex"
    if "gemini" in s:
        return "gemini"
    if "cursor" in s:
        return "cursor"
    return "-"


# ------------------------------------------------------------- column layout

def allocate_columns(total_width, columns, sep=2):
    """lazygit-style allocation: each column declares a min width and a
    share of what is left; columns marked droppable are dropped, lowest
    priority first, until what remains fits. Returns (widths, dropped)."""
    cols = [dict(c) for c in columns]
    dropped = []

    def needed(cs):
        if not cs:
            return 0
        return sum(c["min"] for c in cs) + sep * (len(cs) - 1)

    while cols and needed(cols) > total_width:
        droppable = [c for c in cols if c.get("droppable")]
        if not droppable:
            break
        victim = max(droppable, key=lambda c: c["drop_rank"])
        cols.remove(victim)
        dropped.append(victim["name"])

    if not cols:
        return {}, dropped

    remaining = max(0, total_width - needed(cols))
    weight_sum = sum(c.get("weight", 0) for c in cols) or 1
    widths = {}
    for c in cols:
        share = int(remaining * c.get("weight", 0) / weight_sum) if c.get("weight", 0) > 0 else 0
        w = c["min"] + share
        if "max" in c:
            w = min(w, c["max"])
        widths[c["name"]] = w
    return widths, dropped


def pad(text, width, align="left"):
    text = text[:width] if len(text) > width else text
    return text.rjust(width) if align == "right" else text.ljust(width)


# ------------------------------------------------------------------- NOW

def render_now(payload, width):
    agents = payload.get("agents") or []
    stages = {s["id"]: s for s in (payload.get("stages") or []) if s.get("id")}
    lines = [BOLD("NOW")]

    if agents:
        agent = agents[0]
        stage_id = agent.get("stage_id") or "unknown"
        role = agent.get("role") or "worker"
        phase = "verifying" if role == "verifier" else ("worker running" if role == "worker" else role)
        identity = identity_short(agent.get("identity"))
        elapsed = int(agent.get("elapsed_seconds") or 0)
        budget = int(agent.get("budget_seconds") or 0)
        flags = agent.get("flags") or []
        over = "over-budget" in flags or (budget > 0 and elapsed > budget)

        lines.append("  %s" % fit(stage_id, max(1, width - 2)))

        if budget > 0:
            pct = elapsed * 100.0 / budget
            budget_plain = "%s/%s (%.1f%%)" % (short_secs(elapsed), short_secs(budget), pct)
            if over:
                budget_plain = "OVER BUDGET " + budget_plain
                budget_display = RED(budget_plain)
            else:
                budget_display = budget_plain
        else:
            budget_plain = budget_display = short_secs(elapsed)

        tokens_status = agent.get("stage_tokens_status")
        tokens_val = agent.get("stage_tokens")
        tokens_text = None
        if tokens_status == "counted" and tokens_val is not None:
            tokens_text = "tokens:%s" % short_tokens(tokens_val)
        elif tokens_status == "waiting":
            tokens_text = "tokens:waiting"

        attempt_text = None
        if role == "verifier":
            stage = stages.get(stage_id) or {}
            attempts = stage.get("verifier_attempts")
            cap = payload.get("verifier_attempt_cap")
            if attempts is not None and cap:
                attempt_text = "attempt %s/%s" % (attempts, cap)

        # Fixed display order (phase, agent, elapsed/budget never drop --
        # criteria 3/4 require them present); tokens is the first thing
        # dropped when space runs out, attempt (only present while
        # verifying, and the clearest sign a stage is near its retry cap)
        # is dropped only if there is still not enough room after that.
        columns = [
            {"name": "phase", "min": len(phase), "weight": 0, "text": phase},
            {"name": "identity", "min": len(identity), "weight": 0, "text": identity},
            {"name": "budget", "min": len(budget_plain), "weight": 0, "text": budget_display},
        ]
        if tokens_text:
            columns.append({"name": "tokens", "min": len(tokens_text), "weight": 0,
                             "droppable": True, "drop_rank": 2, "text": tokens_text})
        if attempt_text:
            columns.append({"name": "attempt", "min": len(attempt_text), "weight": 0,
                             "droppable": True, "drop_rank": 1, "text": attempt_text})

        widths, _dropped = allocate_columns(max(1, width - 2), columns)
        detail = [c["text"] for c in columns if c["name"] in widths]
        lines.append("  %s" % fit("  ".join(detail), max(1, width - 2)))
        return lines

    for stage in stages.values():
        integration = stage.get("integration") or {}
        if integration.get("state") == "awaiting":
            lines.append("  %s" % fit(stage["id"], max(1, width - 2)))
            lines.append("  %s" % fit(
                "landing  awaiting merge into %s" % (integration.get("base_branch") or "?"),
                max(1, width - 2)))
            return lines

    lines.append("  %s" % DIM("idle"))
    return lines


# ------------------------------------------------------------------ NEXT

def render_next(payload, width):
    # done/outstanding/escalated are aggregates over the full stages list --
    # scripts/aggregate-dashboard.sh computes them once (queue_counts) so
    # this stays presentation-only, per the aggregation boundary above.
    counts = payload.get("queue_counts") or {}
    done = counts.get("done", 0)
    outstanding = counts.get("outstanding", 0)
    escalated = counts.get("escalated", 0)

    lines = [BOLD("NEXT")]
    lines.append("  %s" % fit(
        "%d done · %d outstanding (%d escalated)" % (done, outstanding, escalated),
        max(1, width - 2)))

    queue = (payload.get("queue") or [])[:3]
    if not queue:
        return lines

    # No "max" on stage: capping it at the widest queued id made 119 and 160
    # allocate identically once that id fit (card 63 criterion 8 FAIL,
    # attempt 1). "stage" is the last visible field on the row (no detail
    # column competing for the remainder, unlike render_escalations), so a
    # weighted column can take its full share and keep responding to the
    # window past the point content alone would need.
    widths, _dropped = allocate_columns(width - 2, [
        {"name": "family", "min": 8, "weight": 0, "droppable": True, "drop_rank": 1},
        {"name": "stage", "min": 16, "weight": 1},
    ])
    for item in queue:
        stage_id = item.get("stage_id") or "?"
        row = pad(stage_id, widths.get("stage", len(stage_id)))
        if "family" in widths:
            row += "  " + pad(family_from_identity(item.get("worker")), widths["family"])
        lines.append("  %s" % fit(row.rstrip(), max(1, width - 2)))
    return lines


# ------------------------------------------------------------ ESCALATIONS

def render_escalations(payload, width, now):
    rows = []
    if payload.get("halted"):
        rows.append(("HALTED", payload.get("halt_reason") or "unknown", None))
    paused_until = payload.get("paused_until")
    if isinstance(paused_until, (int, float)) and paused_until > now:
        rows.append(("PAUSED", payload.get("paused_reason") or "provider limit",
                      "resumes in %s" % short_secs(paused_until - now)))

    for stage in payload.get("stages") or []:
        status = stage.get("status")
        if status not in ALERT_STAGE_STATUSES:
            continue
        wip = stage.get("wip_branch")
        detail = ("wip:%s" % wip) if wip else None
        rows.append((status, stage.get("id") or "?", detail))

    for agent in payload.get("agents") or []:
        outlier = agent.get("token_outlier") or {}
        if "token-outlier" not in (agent.get("flags") or []) or not outlier:
            continue
        live_tokens = outlier.get("live_total_tokens") or 0
        multiple = outlier.get("multiple") or 0
        role = outlier.get("role") or agent.get("role") or "agent"
        detail = "%s · %.1fx %s median" % (
            short_tokens(live_tokens), float(multiple), role)
        rows.append(("OUTLIER", agent.get("stage_id") or "?", detail))

    if not rows:
        return []

    lines = [BOLD("ESCALATIONS")]
    status_natural = max(len(r[0]) for r in rows)
    id_natural = max(len(r[1]) for r in rows)
    # Unlike render_next, "id" here shares its row with an optional detail
    # (the wip pin) that needs whatever width "id" does not use, so it keeps
    # its cap at the natural id width rather than consuming the remainder.
    widths, _dropped = allocate_columns(width - 2, [
        {"name": "status", "min": status_natural, "weight": 0},
        {"name": "id", "min": 16, "weight": 1, "max": id_natural},
    ])
    for status, ident, detail in rows:
        row = pad(status, widths.get("status", len(status)))
        if "id" in widths:
            row += "  " + pad(ident, widths["id"])
        remaining = max(0, (width - 2) - len(row) - 2)
        if detail and "id" in widths and remaining > 4:
            row += "  " + fit(detail, min(remaining, 40))
        lines.append("  %s" % fit(row.rstrip(), max(1, width - 2)))
    return lines


# ---------------------------------------------------------- SPEND AND LOSS

def render_spend(payload, width):
    spend = payload.get("spend") or {}
    lines = [BOLD("SPEND AND LOSS")]

    rows = [
        ("spent today", spend.get("tokens_total", 0), spend.get("cost_usd_est", 0)),
        ("lost today", (spend.get("lost") or {}).get("tokens", 0), (spend.get("lost") or {}).get("cost_usd_est", 0)),
        ("lost 7d", (spend.get("lost_seven_day") or {}).get("tokens", 0), (spend.get("lost_seven_day") or {}).get("cost_usd_est", 0)),
    ]
    label_w = max(len(r[0]) for r in rows + [("cap", 0, 0)])
    tok_w = 10
    lines.append("  %s  %s      %s" % (" " * label_w, pad("tokens", tok_w, "right"), "est cost"))
    for label, tokens, cost in rows:
        lines.append("  %s  %s      $%.2f" % (
            pad(label, label_w), pad(short_tokens(tokens), tok_w, "right"), cost or 0.0))

    cap = payload.get("effective_token_cap") or 0
    spent = payload.get("tokens_spent") or 0
    pct = (spent * 100.0 / cap) if cap else 0.0
    lines.append("  %s  %s   %s (%d%% used)" % (
        pad("cap", label_w), pad(short_tokens(cap), tok_w, "right"),
        payload.get("cap_source") or "host-default", int(pct)))

    if (spend.get("openai_zero_output_caveat")):
        lines.append("  " + YELLOW(fit(
            "note: codex/GPT output_tokens reads 0 on some dispatches -- those "
            "cost figures undercount", max(1, width - 2))))
    return [fit(l, width) for l in lines]


# -------------------------------------------------------------- FRESHNESS

def render_freshness(payload, now, threshold):
    last_tick_at = payload.get("last_tick_at")
    epoch = parse_iso(last_tick_at) if isinstance(last_tick_at, str) else None
    lines = [BOLD("FRESHNESS")]
    if epoch is None:
        lines.append("  " + RED("no tick recorded for this repo"))
        return lines
    if epoch <= 0:
        lines.append("  never ticked")
        return lines
    age = max(0, now - epoch)
    text = "last tick %s ago" % short_secs(age)
    if age > threshold:
        lines.append("  " + RED("%s -- STALE (threshold %s)" % (text, short_secs(threshold))))
    else:
        lines.append("  " + text)
    return lines


# ------------------------------------------------------------------- frame

def build_frame(repo_root, payload, width, height, interval, threshold):
    now = int(time.time())
    lines = []

    if payload is None:
        lines.append(BOLD("repo-ticker"))
        lines.append(RED("no data: %s is not an enabled subscriber, or the aggregator failed" % repo_root))
        lines.append(DIM("run `autometta status` to check subscription, or `autometta refresh-repo %s`" % repo_root))
        lines += [""] * max(0, height - len(lines) - 1)
        lines.append(DIM("Refresh: %ss  Ctrl+C to quit" % interval))
        return [fit(l, width) for l in lines[:height]]

    name = payload.get("name") or os.path.basename(repo_root.rstrip("/"))
    warning = build_warning(payload)
    header = BOLD(name)
    if warning:
        rendered_warning = RED(BOLD(warning)) if "UNREADABLE" in warning else YELLOW(BOLD(warning))
        header += "  " + rendered_warning
    else:
        header += "  " + time.strftime("%H:%M:%SZ", time.gmtime(now))
    if payload.get("state_error"):
        header += "  " + RED("STATE UNREADABLE: %s" % payload["state_error"])
    lines.append(header)
    lines.append("")

    lines += render_now(payload, width)
    lines.append("")
    lines += render_next(payload, width)
    esc = render_escalations(payload, width, now)
    if esc:
        lines.append("")
        lines += esc
    lines.append("")
    lines += render_spend(payload, width)
    lines.append("")
    lines += render_freshness(payload, now, threshold)

    footer = "Refresh: %ss  Ctrl+C to quit" % interval
    available = max(0, height - 1)
    if len(lines) > available:
        hidden = len(lines) - max(0, available - 1)
        lines = lines[:max(0, available - 1)] + [DIM("... %d more line(s) hidden, widen or grow this pane" % hidden)]
    lines += [""] * max(0, height - len(lines) - 1)
    lines.append(footer)
    return [fit(l, width) for l in lines[:height]]


def main():
    if len(sys.argv) != 6:
        sys.stderr.write("usage: %s <repo_root> <width> <height> <interval> <freshness_threshold>\n" % sys.argv[0])
        return 2
    repo_root, width, height, interval, threshold = sys.argv[1:]
    payload_raw = os.environ.get("AUTOMETTA_TICKER_PAYLOAD", "")
    try:
        payload = json.loads(payload_raw) if payload_raw.strip() else None
    except ValueError:
        payload = None
    frame = build_frame(repo_root, payload, int(width), int(height), interval, int(threshold))
    sys.stdout.write("\n".join(frame))
    return 0


if __name__ == "__main__":
    sys.exit(main())
