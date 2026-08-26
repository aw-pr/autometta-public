#!/usr/bin/env python3
"""Pure payload-to-canvas rendering for the Autometta TUI."""
import importlib.util
import os
import time


_LIB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_LIB_DIR, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_repo = _load("autometta_repo_ticker", "repo-ticker-render.py")
_fleet = _load("autometta_fleet_ticker", "fleet-ticker-render.py")
short_tokens = _repo.short_tokens
short_secs = _repo.short_secs
parse_iso = _repo.parse_iso
wrap_groups = _fleet.wrap_groups
render_grouped_lines = _fleet.render_grouped_lines

NORMAL = 0
BOLD = 1
REVERSE = 2
ACTIVE = 3
ALERT = 4
DIM = 5

ANSI = {
    NORMAL: "\x1b[0m",
    BOLD: "\x1b[1m",
    REVERSE: "\x1b[7m",
    ACTIVE: "\x1b[1;36m",
    ALERT: "\x1b[1;31m",
    DIM: "\x1b[2m",
}


class Canvas:
    def __init__(self, width, height):
        self.width = max(1, width)
        self.height = max(1, height)
        self.cells = [[" " for _ in range(self.width)] for _ in range(self.height)]
        self.attrs = [[NORMAL for _ in range(self.width)] for _ in range(self.height)]

    def put(self, x, y, text, attr=NORMAL):
        if y < 0 or y >= self.height:
            return
        for offset, char in enumerate(str(text)):
            px = x + offset
            if 0 <= px < self.width:
                self.cells[y][px] = char
                self.attrs[y][px] = attr

    def line(self, x, y, text, spans=None, attr=NORMAL):
        self.put(x, y, text, attr)
        for start, end, span_attr in spans or []:
            for px in range(max(x, x + start), min(self.width, x + end)):
                if 0 <= y < self.height:
                    self.attrs[y][px] = span_attr

    def text(self, ansi=False):
        rendered = []
        for chars, attrs in zip(self.cells, self.attrs):
            last = self.width - 1
            while last >= 0 and chars[last] == " ":
                last -= 1
            if last < 0:
                rendered.append("")
                continue
            if not ansi:
                rendered.append("".join(chars[:last + 1]))
                continue
            line = []
            current = NORMAL
            for char, attr in zip(chars[:last + 1], attrs[:last + 1]):
                if attr != current:
                    line.append(ANSI[attr])
                    current = attr
                line.append(char)
            if current != NORMAL:
                line.append(ANSI[NORMAL])
            rendered.append("".join(line))
        return "\n".join(rendered)


def identity_alias(identity):
    value = (identity or "").lower()
    if "sol" in value:
        return "sol"
    if "fable" in value:
        return "fable"
    if "terra" in value:
        return "terra"
    if "luna" in value:
        return "luna"
    if "claude" in value:
        return "claude"
    if "codex" in value or "gpt" in value:
        return "codex"
    if "gemini" in value:
        return "gemini"
    return "-"


def relative_age(stamp, now):
    epoch = parse_iso(stamp) if isinstance(stamp, str) else None
    return short_secs(max(0, now - epoch)) if epoch is not None else "?"


def stage_total(payload, stage_id):
    for agent in payload.get("agents") or []:
        if agent.get("stage_id") == stage_id:
            value = agent.get("live_total_tokens")
            if value is None:
                value = agent.get("stage_tokens")
            if value is not None:
                return int(value)
    for row in (payload.get("spend") or {}).get("by_stage") or []:
        if row.get("stage_id") == stage_id:
            return int(row.get("tokens") or 0)
    for stage in payload.get("stages") or []:
        if stage.get("id") == stage_id:
            return int(stage.get("tokens") or 0)
    return 0


class TuiState:
    def __init__(self, interval=5.0):
        self.interval = float(interval)
        self.payload = {}
        self.focus = 2
        self.page = 1
        self.selection = {1: 0, 2: 0, 3: 0, 4: 0}
        self.pinned_stage = None
        self.history_selection = 0
        self.pinned_history_card = None
        self.history = {}
        self.now = int(time.time())

    def update(self, payload, observed_at=None):
        self.payload = payload or {}
        self.now = int(self.payload.get("_now") or time.time())
        stamp = float(observed_at if observed_at is not None else time.monotonic())
        for stage in self.payload.get("stages") or []:
            stage_id = stage.get("id")
            if not stage_id:
                continue
            points = self.history.setdefault(stage_id, [])
            total = stage_total(self.payload, stage_id)
            if not points or points[-1][1] != total:
                points.append((stamp, total))
                del points[:-9]
        ids = [s.get("id") for s in self.payload.get("stages") or []]
        if self.pinned_stage not in ids:
            preferred = self.payload.get("current_stage")
            self.pinned_stage = preferred if preferred in ids else (ids[0] if ids else None)
        if self.pinned_stage in ids and not self.selection[2]:
            self.selection[2] = ids.index(self.pinned_stage)
        history_ids = [row.get("id") for row in history_cards(self.payload)]
        if history_ids:
            self.history_selection = min(self.history_selection, len(history_ids) - 1)
            if self.pinned_history_card not in history_ids:
                self.pinned_history_card = history_ids[0]
        else:
            self.history_selection = 0
            self.pinned_history_card = None

    def rows_for_focus(self):
        if self.focus == 2:
            return self.payload.get("stages") or []
        if self.focus == 3:
            return self.payload.get("agents") or []
        if self.focus == 4:
            return escalation_rows(self.payload)
        return [self.payload]

    def key(self, key):
        if key in ("1", "2", "3", "4"):
            self.focus = int(key)
            return
        if key in ("TAB", "\t"):
            self.focus = self.focus % 4 + 1
            return
        if key in ("PAGE_NEXT", "]"):
            self.page = self.page % 3 + 1
            return
        if key in ("PAGE_PREV", "["):
            self.page = (self.page - 2) % 3 + 1
            return
        if self.page == 2:
            rows = history_cards(self.payload)
            if key in ("j", "DOWN") and rows:
                self.history_selection = min(len(rows) - 1, self.history_selection + 1)
            elif key in ("k", "UP") and rows:
                self.history_selection = max(0, self.history_selection - 1)
            elif key in ("ENTER", "\n", "\r") and rows:
                self.pinned_history_card = rows[self.history_selection].get("id")
            return
        rows = self.rows_for_focus()
        if key in ("j", "DOWN") and rows:
            self.selection[self.focus] = min(len(rows) - 1, self.selection[self.focus] + 1)
        elif key in ("k", "UP") and rows:
            self.selection[self.focus] = max(0, self.selection[self.focus] - 1)
        elif key in ("ENTER", "\n", "\r") and self.focus == 2 and rows:
            self.pinned_stage = rows[self.selection[2]].get("id")


def stage_state(payload, stage):
    status = stage.get("status") or "pending"
    agent = next((a for a in payload.get("agents") or [] if a.get("stage_id") == stage.get("id")), None)
    if status == "completed":
        return "✔", "done", None
    if status == "pending":
        return "○", "queued", None
    if status in ("stalled", "verifier_failed", "failed"):
        return "✖", "ESCALTD", None
    if status == "superseded":
        return "○", "superseded", None
    role = (agent or {}).get("role") or "worker"
    return "▶", "VERIFY" if role == "verifier" else "WORKER", role


def escalation_rows(payload):
    rows = []
    if payload.get("halted"):
        rows.append(("HALTED", payload.get("halt_reason") or "budget"))
    for stage in payload.get("stages") or []:
        if stage.get("status") in ("stalled", "verifier_failed", "failed"):
            rows.append((stage.get("id") or "?", stage.get("status")))
    return rows


def content_line(text, spans=None):
    return text, spans or []


def history_cards(payload):
    return (payload.get("history") or {}).get("cards") or []


def marked_tokens(value, marked=False):
    return short_tokens(value or 0) + ("?" if marked else "")


def marked_cost(value, marked=False):
    return "$%.2f%s" % (value or 0, "?" if marked else "")


def compact_when(stamp):
    if not isinstance(stamp, str) or len(stamp) < 16:
        return "?"
    months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    try:
        month = months[int(stamp[5:7]) - 1]
        return "%s %s %s" % (stamp[8:10], month, stamp[11:16])
    except (ValueError, IndexError):
        return stamp


def sparkline(values):
    bars = "▁▂▃▄▅▆▇█"
    peak = max(values or [0])
    if peak <= 0:
        return "▁" * len(values)
    return "".join(bars[min(7, int((value or 0) * 7 / peak))] for value in values)


def history_table_lines(state, inner_width, inner_height=None):
    rows = history_cards(state.payload)
    summary = (state.payload.get("history") or {}).get("summary") or {}
    summary_text = "%d cards · %s lost 7d · %s cost 7d" % (
        summary.get("card_count", len(rows)),
        marked_tokens(summary.get("lost_seven_day_tokens", 0),
                      summary.get("lost_seven_day_marked", False)),
        marked_cost(summary.get("seven_day_cost_usd_est", 0),
                    summary.get("seven_day_cost_marked", False)))
    lines = [content_line(summary_text, [(0, len(summary_text), BOLD)])]
    if summary.get("lost_seven_day_marked") or summary.get("seven_day_cost_marked"):
        lines.append(content_line("? codex zero-output read: marked totals are undercounts", [(0, 1, ALERT)]))
    if not rows:
        lines.append(content_line("no historic dispatches", [(0, 21, DIM)]))
        return lines

    rendered_rows = []
    for row in rows:
        rendered_rows.append({
            "card": row.get("id") or "?",
            "result": row.get("result") or "UNKNOWN",
            "attempts": str(row.get("attempts") or 0),
            "tokens": marked_tokens(row.get("tokens", 0), row.get("tokens_marked", False)),
            "lost": marked_tokens(row.get("lost_tokens", 0), row.get("lost_marked", False)),
            "cost": marked_cost(row.get("cost_usd_est", 0), row.get("cost_marked", False)),
            "pair": "%s→%s" % (identity_alias(row.get("worker")), identity_alias(row.get("verifier"))),
            "when": compact_when(row.get("last_dispatch_at")),
        })

    order = ["card", "result", "attempts", "tokens", "lost", "cost", "pair", "when"]
    if inner_width < 105:
        order.remove("when")
    if inner_width < 82:
        order.remove("lost")
    if inner_width < 68:
        order.remove("attempts")
    headings = {"card": "card", "result": "result", "attempts": "attempts", "tokens": "tokens",
                "lost": "lost", "cost": "cost", "pair": "worker→verifier", "when": "when"}
    widths = {name: max(len(headings[name]), max(len(row[name]) for row in rendered_rows)) for name in order}
    aligns = {"attempts": "right", "tokens": "right", "lost": "right", "cost": "right"}
    lines.append(content_line(""))
    for heading_line in render_grouped_lines(headings, order, widths, aligns, inner_width, indent="  "):
        lines.append(content_line(heading_line.rstrip(), [(0, len(heading_line.rstrip()), BOLD)]))
    row_blocks = []
    for index, row in enumerate(rendered_rows):
        selected = index == state.history_selection
        block = []
        for row_line in render_grouped_lines(row, order, widths, aligns, inner_width, indent="  "):
            row_line = row_line.rstrip()
            block.append(content_line(row_line, [(0, len(row_line), REVERSE)] if selected else []))
        row_blocks.append(block)

    fortnight = (state.payload.get("history") or {}).get("fortnight") or {}
    days = fortnight.get("by_day") or []
    day_spark = sparkline([day.get("cost_usd_est", 0) for day in days])
    models = fortnight.get("by_model") or []
    shares = " ".join("%s %d%%%s" % (
        identity_alias(model.get("identity")), model.get("share_percent", 0),
        "?" if model.get("marked") else "") for model in models)
    footer_lines = [content_line("spend 14d %s" % day_spark),
                    content_line("by model: " + (shares or "no spend"))]
    if inner_height is None:
        return lines + [item for block in row_blocks for item in block] + footer_lines

    row_capacity = max(1, inner_height - len(lines) - len(footer_lines) - 1)
    selected = min(state.history_selection, len(row_blocks) - 1)
    start = 0
    while start < selected and sum(len(block) for block in row_blocks[start:selected + 1]) > row_capacity:
        start += 1
    end = start
    used = 0
    while end < len(row_blocks) and used + len(row_blocks[end]) <= row_capacity:
        used += len(row_blocks[end])
        end += 1
    if end <= selected:
        end = selected + 1
    visible = [item for block in row_blocks[start:end] for item in block]
    range_line = content_line("rows %d-%d of %d" % (start + 1, end, len(row_blocks)), [(0, 4, DIM)])
    return lines + visible + [range_line] + footer_lines


def history_detail_lines(state, inner_width):
    card = next((row for row in history_cards(state.payload)
                 if row.get("id") == state.pinned_history_card), None)
    if not card:
        return [content_line("No card selected", [(0, 16, DIM)])]
    pair = "%s→%s" % (identity_alias(card.get("worker")), identity_alias(card.get("verifier")))
    lines = [content_line(card.get("id") or "?", [(0, len(card.get("id") or "?"), BOLD)]),
             content_line("%s · %s · %s" % (
                 card.get("result") or "UNKNOWN", pair,
                 marked_cost(card.get("cost_usd_est", 0), card.get("cost_marked", False)))),
             content_line("")]
    detail_headings = {"role": "role", "result": "result", "tokens": "tokens",
                       "cost": "cost", "when": "when"}
    detail_order = ["role", "result", "tokens", "cost", "when"]
    detail_widths = {name: len(detail_headings[name]) for name in detail_order}
    for heading_line in render_grouped_lines(
            detail_headings, detail_order, detail_widths, {}, inner_width, indent="  "):
        lines.append(content_line(heading_line.rstrip(), [(0, len(heading_line.rstrip()), BOLD)]))
    for dispatch in card.get("dispatches") or []:
        cells = {
            "role": dispatch.get("role") or "?",
            "result": dispatch.get("result") or "UNKNOWN",
            "tokens": marked_tokens(dispatch.get("tokens", 0), dispatch.get("tokens_marked", False)),
            "cost": marked_cost(dispatch.get("cost_usd_est", 0), dispatch.get("cost_marked", False)),
            "when": compact_when(dispatch.get("when")),
        }
        order = ["role", "result", "tokens", "cost", "when"]
        widths = {name: len(cells[name]) for name in order}
        for detail_line in render_grouped_lines(cells, order, widths, {}, inner_width, indent="  "):
            lines.append(content_line(detail_line.rstrip()))
    return wrap_content_lines(lines, inner_width)


def render_history(canvas, state, width, usable):
    name = state.payload.get("name") or "repo"
    table_title = "[0]─History: %s" % name
    if width > 80:
        left_width = min(width - 34, max(82, int(width * 0.70)))
        right_x = left_width + 1
        draw_box(canvas, (0, 0, left_width, usable), table_title,
                 history_table_lines(state, left_width - 4, usable - 2))
        draw_box(canvas, (right_x, 0, width - right_x, usable), "[0]─Card detail",
                 history_detail_lines(state, width - right_x - 4))
        return
    detail_height = max(10, min(24, usable // 3))
    table_height = usable - detail_height - 1
    draw_box(canvas, (0, 0, width, table_height), table_title,
             history_table_lines(state, width - 4, table_height - 2))
    draw_box(canvas, (0, table_height + 1, width, detail_height), "[0]─Card detail",
             history_detail_lines(state, width - 4))


def draw_box(canvas, rect, title, lines, focused=False):
    x, y, width, height = rect
    if width < 3 or height < 2:
        return
    top = "┌" + "─" * (width - 2) + "┐"
    bottom = "└" + "─" * (width - 2) + "┘"
    canvas.put(x, y, top)
    canvas.put(x, y + height - 1, bottom)
    for row in range(y + 1, y + height - 1):
        canvas.put(x, row, "│")
        canvas.put(x + width - 1, row, "│")
    label = "─" + title
    canvas.put(x + 1, y, label[:max(0, width - 2)], REVERSE if focused else BOLD)
    inner = max(0, height - 2)
    visible = list(lines)
    if len(visible) > inner:
        keep = max(0, inner - 1)
        hidden = len(visible) - keep
        visible = visible[:keep] + [content_line("and %d more" % hidden, [(0, len("and %d more" % hidden), DIM)])]
    for offset, (text, spans) in enumerate(visible[:inner]):
        canvas.line(x + 2, y + 1 + offset, text[:max(0, width - 4)], spans)


def status_lines(state):
    payload = state.payload
    agents = payload.get("agents") or []
    running = bool(agents)
    name = payload.get("name") or "repo"
    light = "RUNNING" if running else ("HALTED" if payload.get("halted") else "IDLE")
    run_start = payload.get("run_started_at")
    run_epoch = parse_iso(run_start) if isinstance(run_start, str) else None
    elapsed = short_secs(max(0, state.now - run_epoch)) if run_epoch is not None else "?"
    spend = payload.get("spend") or {}
    cap = payload.get("effective_token_cap") or payload.get("token_cap_total") or 0
    spent = payload.get("tokens_spent") or 0
    pct = int(spent * 100 / cap) if cap else 0
    lines = [
        content_line("● %s → dev  %s" % (name, light), [(0, 1, ACTIVE if running else DIM)]),
        content_line("last tick %s ago  tick #%s" % (relative_age(payload.get("last_tick_at"), state.now), payload.get("tick_count", 0))),
        content_line("run start %s  elapsed %s" % ((run_start or "?")[-9:], elapsed)),
        content_line("tokens %s  $%.2f  cap %s (%d%%)" % (
            short_tokens(spend.get("tokens_total", 0)), spend.get("cost_usd_est", 0) or 0,
            short_tokens(cap), pct)),
    ]
    if state.focus == 1:
        lines[0][1].insert(0, (0, len(lines[0][0]), REVERSE))
    return lines


def run_lines(state, inner_width, force_pair_wrap=False):
    payload = state.payload
    lines = []
    for index, stage in enumerate(payload.get("stages") or []):
        glyph, status, active_role = stage_state(payload, stage)
        worker = identity_alias(stage.get("worker"))
        verifier = identity_alias(stage.get("verifier"))
        pair = "%s→%s" % (worker, verifier)
        cells = {"glyph": glyph, "id": stage.get("id") or "?", "role": status,
                 "pair": pair, "tokens": short_tokens(stage_total(payload, stage.get("id")))}
        widths = {name: len(value) for name, value in cells.items()}
        if force_pair_wrap:
            groups = wrap_groups(["glyph", "id", "role"], widths, inner_width)
            groups += wrap_groups(["pair", "tokens"], widths, inner_width)
        else:
            groups = wrap_groups(["glyph", "id", "role", "pair", "tokens"], widths, inner_width)
        selected = state.focus == 2 and state.selection[2] == index
        for physical, group in enumerate(groups):
            rendered = render_grouped_lines(cells, group, widths, {}, inner_width, indent="  ")[0].rstrip()
            if physical:
                rendered = "  " + rendered
            spans = []
            if selected:
                spans.append((0, len(rendered), REVERSE))
            if "pair" in group and active_role:
                alias = worker if active_role == "worker" else verifier
                start = rendered.find(alias, rendered.find(pair))
                if start >= 0:
                    spans.append((start, start + len(alias), ACTIVE))
            lines.append(content_line(rendered, spans))
    return lines


def agent_lines(state):
    lines = []
    for index, agent in enumerate(state.payload.get("agents") or []):
        alias = identity_alias(agent.get("identity"))
        elapsed = short_secs(agent.get("elapsed_seconds") or 0)
        budget = short_secs(agent.get("budget_seconds") or 0)
        text = "● %s %s  %s  %s / %s" % (
            agent.get("stage_id") or "?", agent.get("role") or "?", alias, elapsed, budget)
        spans = [(0, 1, ACTIVE)]
        if state.focus == 3 and state.selection[3] == index:
            spans.insert(0, (0, len(text), REVERSE))
        lines.append(content_line(text, spans))
    return lines or [content_line("no live agents", [(0, 14, DIM)])]


def inbox_lines(state):
    rows = escalation_rows(state.payload)
    if not rows:
        return [content_line("no escalations or messages", [(0, 27, DIM)])]
    lines = []
    for index, (stage_id, status) in enumerate(rows):
        heading = "✖ %s  needs you" % status
        spans = [(0, 1, ALERT)]
        if state.focus == 4 and state.selection[4] == index:
            spans.insert(0, (0, len(heading), REVERSE))
        lines.append(content_line(heading, spans))
        lines.append(content_line("  " + stage_id))
    return lines


def usage_for_stage(payload, stage_id):
    for row in (payload.get("spend") or {}).get("by_stage") or []:
        if row.get("stage_id") == stage_id:
            return row
    return {}


def sparkline_and_rate(state, stage_id):
    points = state.history.get(stage_id) or []
    deltas = []
    rate = 0
    for (before_t, before_n), (after_t, after_n) in zip(points, points[1:]):
        elapsed = max(0.001, after_t - before_t)
        delta = max(0, after_n - before_n)
        deltas.append(delta)
        rate = int(round(delta * 60 / elapsed))
    if not deltas:
        return "▁", 0
    bars = "▁▂▃▄▅▆▇█"
    peak = max(deltas) or 1
    spark = "".join(bars[min(7, int(value * 7 / peak))] for value in deltas[-8:])
    return spark, rate


def wrap_content_lines(lines, inner_width):
    wrapped = []
    for text, spans in lines:
        if len(text) <= inner_width or not text:
            wrapped.append((text, spans))
            continue
        remaining = text
        continuation = ""
        while len(continuation) + len(remaining) > inner_width:
            available = max(1, inner_width - len(continuation))
            split_at = remaining.rfind(" ", 0, available + 1)
            if split_at > 0:
                piece = remaining[:split_at]
                remaining = remaining[split_at + 1:]
            else:
                piece = remaining[:available]
                remaining = remaining[available:]
            wrapped.append(content_line(continuation + piece))
            continuation = "  "
        wrapped.append(content_line(continuation + remaining))
    return wrapped


def detail_lines(state, inner_width):
    stages = state.payload.get("stages") or []
    stage = next((item for item in stages if item.get("id") == state.pinned_stage), None)
    if not stage:
        return [content_line("No card selected", [(0, 16, DIM)])]
    glyph, status, _ = stage_state(state.payload, stage)
    agent = next((a for a in state.payload.get("agents") or [] if a.get("stage_id") == stage.get("id")), {})
    usage = usage_for_stage(state.payload, stage.get("id"))
    attempts = stage.get("verifier_attempts") or 0
    cap = state.payload.get("verifier_attempt_cap") or 3
    elapsed = agent.get("elapsed_seconds") or 0
    budget = agent.get("budget_seconds") or 0
    budget_pct = int(elapsed * 100 / budget) if budget else 0
    spark, rate = sparkline_and_rate(state, stage.get("id"))
    lines = [
        content_line("%s %s  %s" % (glyph, stage.get("id"), status), [(0, 1, ACTIVE if glyph == "▶" else NORMAL)]),
        content_line(""),
    ]
    for label, identity in (("worker", stage.get("worker") or "-"),
                            ("verifier", stage.get("verifier") or "-")):
        combined = "%-10s%s" % (label, identity)
        if len(combined) <= inner_width:
            lines.append(content_line(combined))
        else:
            lines.extend((content_line(label), content_line("  " + identity)))
    lines.extend([
        content_line("attempt   %s of %s" % (attempts, cap)),
        content_line("budget    %s / %s (%d%% used)" % (short_secs(elapsed), short_secs(budget), budget_pct)),
        content_line("card      %s" % (stage.get("card") or "stage-cards/%s.md" % stage.get("id"))),
        content_line(""),
        content_line("─ acceptance " + "─" * max(0, inner_width - 13)),
        content_line(stage.get("acceptance") or "see stage card"),
        content_line(""),
        content_line("tokens  in %s  cached %s  out %s  $%.2f" % (
            short_tokens(usage.get("input_tokens", 0)), short_tokens(usage.get("cached_input_tokens", 0)),
            short_tokens(usage.get("output_tokens", 0)), usage.get("cost_usd_est", 0) or 0)),
        content_line("%s  burn last 8 polls (%s/min)" % (spark, short_tokens(rate))),
    ])
    return wrap_content_lines(lines, inner_width)


def fit_heights(desired, minimum, available, shrink_order):
    heights = list(desired)
    while sum(heights) > available:
        changed = False
        for index in shrink_order:
            if heights[index] > minimum[index]:
                heights[index] -= 1
                changed = True
                if sum(heights) <= available:
                    break
        if not changed:
            break
    return heights


def footer(canvas, state):
    tabs = "[1]run [2]history [3]messages"
    hints = "  j/k select · enter detail · [/] page · m message controller · q quit"
    text = tabs + hints
    if len(text) > canvas.width:
        text = tabs + "  j/k select · enter detail · q quit"
    canvas.put(0, canvas.height - 1, text[:canvas.width])
    label = "[%d]" % state.page
    start = text.find(label)
    if start >= 0:
        for x in range(start, min(canvas.width, start + len(label))):
            canvas.attrs[canvas.height - 1][x] = REVERSE


def render(state, width, height):
    canvas = Canvas(width, height)
    if width < 40 or height < 18:
        canvas.put(0, 0, "Autometta TUI: resize to at least 40x18", ALERT)
        footer(canvas, state)
        return canvas
    if state.page == 2:
        render_history(canvas, state, width, height - 1)
        footer(canvas, state)
        return canvas
    if state.page != 1:
        draw_box(canvas, (0, 0, width, height - 1), "[3] Messages", [
            content_line("arrives with card 71", [(0, 20, DIM)])])
        footer(canvas, state)
        return canvas

    usable = height - 1
    stacked = width <= 80
    stages = state.payload.get("stages") or []
    done = len([s for s in stages if s.get("status") == "completed"])
    run_title = "[2]─This run  %d of %d" % (done, len(stages))
    live_count = len(state.payload.get("agents") or [])
    esc_count = len(escalation_rows(state.payload))
    if not stacked:
        left_width = min(86, max(74, int(width * 0.52)))
        left_width = min(left_width, width - 45)
        right_x = left_width + 1
        right_width = width - right_x
        panel_total = usable - 3
        heights = fit_heights([6, 16, 6, 4], [4, 5, 4, 3], panel_total, [1, 2, 0, 3])
        status_h, run_h, agents_h, inbox_h = heights
        y1 = 0
        y2 = y1 + status_h + 1
        y3 = y2 + run_h + 1
        y4 = y3 + agents_h + 1
        draw_box(canvas, (0, y1, left_width, status_h), "[1]─Status", status_lines(state), state.focus == 1)
        draw_box(canvas, (0, y2, left_width, run_h), run_title,
                 run_lines(state, left_width - 4), state.focus == 2)
        draw_box(canvas, (0, y3, left_width, agents_h), "[3]─Agents  %d live" % live_count,
                 agent_lines(state), state.focus == 3)
        draw_box(canvas, (0, y4, left_width, inbox_h), "[4]─Escalations & inbox  %d · 0" % esc_count,
                 inbox_lines(state), state.focus == 4)
        draw_box(canvas, (right_x, 0, right_width, usable), "[0]─Card detail",
                 detail_lines(state, right_width - 4))
    else:
        available = usable - 4
        heights = fit_heights([6, 18, 6, 4, 18], [3, 5, 3, 3, 6], available, [1, 4, 2, 0, 3])
        status_h, run_h, agents_h, inbox_h, detail_h = heights
        rects = []
        cursor = 0
        for panel_height in heights:
            rects.append((0, cursor, width, panel_height))
            cursor += panel_height + 1
        draw_box(canvas, rects[0], "[1]─Status", status_lines(state), state.focus == 1)
        draw_box(canvas, rects[1], run_title, run_lines(state, width - 4, True), state.focus == 2)
        draw_box(canvas, rects[2], "[3]─Agents  %d live" % live_count, agent_lines(state), state.focus == 3)
        draw_box(canvas, rects[3], "[4]─Escalations & inbox  %d · 0" % esc_count,
                 inbox_lines(state), state.focus == 4)
        draw_box(canvas, rects[4], "[0]─Card detail", detail_lines(state, width - 4))
    footer(canvas, state)
    return canvas
