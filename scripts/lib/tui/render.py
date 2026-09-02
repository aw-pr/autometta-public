#!/usr/bin/env python3
"""Pure payload-to-canvas rendering for the Autometta TUI."""
import importlib.util
import os
import re
import time


_LIB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_LIB_DIR, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_repo = _load("autometta_repo_ticker", "repo-ticker-render.py")
_fleet = _load("autometta_fleet_ticker", "fleet-ticker-render.py")
# Loaded by path like its siblings above, not by `import`: render.py is
# exec'd straight from its file by the smoke and by any tool that wants the
# pure renderer, and a bare import needs this directory on sys.path, which
# such a caller has no reason to have arranged.
status_updates = _load("autometta_tui_status_updates",
                       os.path.join("tui", "status_updates.py"))

short_tokens = _repo.short_tokens


def tick_tokens(n):
    """Token counts in thousands, comma-grouped: 1,143k.

    short_tokens' 1.1M is the right unit for a total nobody watches change,
    but it is the wrong one for the run and status panels: a worker adding
    twenty thousand tokens between polls does not move the first decimal
    place, so the figure looks frozen and the loop looks dead. Thousands are
    fine-grained enough that every poll visibly moves the number.
    """
    n = int(n or 0)
    if n < 1000:
        return str(n)
    return "{:,}k".format(n // 1000)
short_secs = _repo.short_secs
parse_iso = _repo.parse_iso
build_warning = _repo.build_warning
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
    # Selection and focus highlight. A hard reverse-video block read as a
    # glare against the dark theme (UAT 2026-08-31); a pastel blue keeps the
    # row legible while clearly selected. 256-colour SGR: light steel blue
    # ground, near-black ink.
    REVERSE: "\x1b[48;5;153m\x1b[38;5;235m",
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
    value = (identity or "").strip().lower()
    address = re.search(r"<([^<>]+)>", value)
    slug = (address.group(1) if address else value).split("@", 1)[0].strip()
    if not slug:
        return "-"

    releases = ("sol", "terra", "luna", "fable")
    tokens = slug.split("-")
    for release in releases:
        if release in tokens:
            return release

    model = slug
    prefixes = ("anthropic-", "openai-", "google-", "claude-", "codex-")
    while True:
        prefix = next((item for item in prefixes if model.startswith(item)), None)
        if prefix is None:
            break
        model = model[len(prefix):]
    if model in ("claude", "codex", "gemini"):
        return model

    versioned = re.fullmatch(r"(gpt|opus|sonnet|haiku)-(\d+)(?:-(\d+))?", model)
    if versioned:
        name, major, minor = versioned.groups()
        return "%s-%s%s" % (name, major, "." + minor if minor else "")
    return model or slug


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


def current_run(payload):
    run = payload.get("current_run")
    return run if isinstance(run, dict) and run.get("id") else None


def current_run_stages(payload):
    run = current_run(payload)
    return (run.get("stages") or []) if run else []


def ordered_run_stages(payload):
    stages = current_run_stages(payload)
    # Pending stages have not run yet: keep their queue order after the live
    # edge, then show finished scheduled work newest first.
    active = [stage for stage in reversed(stages)
              if stage.get("status") not in ("completed", "pending", "superseded")]
    queued = [stage for stage in stages if stage.get("status") == "pending"]
    finished = [stage for stage in reversed(stages)
                if stage.get("status") in ("completed", "superseded")]
    return active + queued + finished


class TuiState:
    def __init__(self, interval=5.0):
        self.interval = float(interval)
        self.payload = {}
        self.focus = 2
        self.page = 1
        self.selection = {0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
        self.pinned_stage = None
        self.history_selection = 0
        self.pinned_history_card = None
        self.controller = {"journal": [], "conversation": []}
        self.status_updates = []
        self.journal_offset = 0
        self.composing = False
        self.compose_buffer = ""
        self.compose_notice = ""
        self.card_notice = ""
        self.card_body = []
        self.card_body_stage = None
        self.card_offset = 0
        self.history = {}
        self.now = int(time.time())
        self.monotonic_now = time.monotonic()
        self.data_started_at = None
        self.loading = True
        self.polling = False

    def update(self, payload, observed_at=None, data_started_at=None):
        self.payload = payload or {}
        self.now = int(self.payload.get("_now") or time.time())
        stamp = float(observed_at if observed_at is not None else time.monotonic())
        self.monotonic_now = time.monotonic()
        if data_started_at is not None:
            self.data_started_at = float(data_started_at)
        self.loading = False
        self.polling = False
        for stage in self.payload.get("stages") or []:
            stage_id = stage.get("id")
            if not stage_id:
                continue
            points = self.history.setdefault(stage_id, [])
            total = stage_total(self.payload, stage_id)
            if not points or points[-1][1] != total:
                points.append((stamp, total))
                del points[:-9]
        ids = [s.get("id") for s in ordered_run_stages(self.payload)]
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

    def poll_started(self, started_at):
        self.polling = True
        self.loading = not bool(self.payload)
        self.monotonic_now = float(started_at)

    def poll_failed(self, error):
        failed = dict(self.payload)
        failed["state_error"] = error
        self.payload = failed
        self.loading = False
        self.polling = False
        self.monotonic_now = time.monotonic()

    def observe_time(self, now):
        previous = int(self.monotonic_now)
        self.monotonic_now = float(now)
        return int(self.monotonic_now) != previous

    def update_status_updates(self, rows):
        self.status_updates = list(rows or [])

    def update_controller(self, controller):
        self.controller = controller or {"journal": [], "conversation": []}
        maximum = max(0, len(self.controller.get("journal") or []) - 1)
        self.journal_offset = min(self.journal_offset, maximum)

    def compose_done(self, notice):
        self.composing = False
        self.compose_buffer = ""
        self.compose_notice = notice

    def compose_failed(self, notice):
        self.compose_notice = "not queued: " + notice

    def _follow_selection(self, rows):
        """Point the detail pane at whatever the cursor is now on.

        Only the run list (focus 2) drives the card detail pane; the agents and
        escalations panels have their own selections that no pane reads, so
        moving in them must not repoint the card.
        """
        if self.focus != 2 or not rows:
            return
        selected = rows[self.selection[2]].get("id")
        if selected and selected != self.pinned_stage:
            self.pinned_stage = selected
            # A new card starts at its own first line, not at the offset the
            # reader had scrolled the previous one to.
            self.card_offset = 0

    def rows_for_focus(self):
        if self.focus == 2:
            return ordered_run_stages(self.payload)
        if self.focus == 3:
            return self.payload.get("agents") or []
        if self.focus == 4:
            return escalation_rows(self.payload)
        return [self.payload]

    def key(self, key):
        if self.composing:
            if key in ("ESC", "\x1b"):
                self.composing = False
                self.compose_buffer = ""
                self.compose_notice = "message cancelled"
            elif key in ("BACKSPACE", "\b", "\x7f"):
                self.compose_buffer = self.compose_buffer[:-1]
            elif key in ("ENTER", "\n", "\r"):
                if self.compose_buffer.strip():
                    return "submit", self.compose_buffer
                self.compose_notice = "not queued: message is empty"
            elif key and all(char.isprintable() for char in key):
                self.compose_buffer += key
            return None
        if key not in ("o", "O"):
            self.card_notice = ""
        if key in ("o", "O"):
            # The card is the prompt the worker was given, so "why did it do
            # that" is usually answered by reading it rather than by the detail
            # pane's summary of it. Resolution happens in the app layer, which
            # is the only part that knows about the terminal it is hosted in.
            #
            # o pages it read-only; O hands it to whatever the desktop opens .md
            # with, which may well be an editor. They are separate keys rather
            # than one, because a card a worker is mid-dispatch on must not
            # become editable by a keystroke meant to read it.
            stage = next((item for item in ordered_run_stages(self.payload)
                          if item.get("id") == self.pinned_stage), None)
            if not stage:
                self.card_notice = "no stage selected"
                return None
            path = stage.get("card") or "stage-cards/%s.md" % stage.get("id")
            return ("open_card" if key == "o" else "open_card_external"), path
        if key in ("m", "M"):
            self.page = 3
            self.composing = True
            self.compose_buffer = ""
            self.compose_notice = ""
            return None
        if key in ("0", "1", "2", "3", "4", "5"):
            # The number row means two things, and which one depends on what is
            # on screen. The run page draws panels labelled [0]-[4], so there a
            # number focuses a panel. The other pages draw no numbered panels,
            # and the footer's tab strip is the only thing the number row can
            # mean there -- so it switches page. It used to focus a panel on
            # every page and return, which on the messages page did nothing at
            # all: the tab strip advertised [1]run while pressing 1 left the
            # reader exactly where they were, with only [ ] or q to escape.
            if self.page == 1:
                self.focus = int(key)
            elif key in ("1", "2", "3"):
                self.page = int(key)
            return
        if key in ("ESC", "\x1b"):
            # A way out that does not require knowing which key paged you in.
            self.page = 1
            return
        # Letter shortcuts that mean the same page everywhere. On the run
        # page the number row focuses panels, so "[2]history" in the tab
        # strip reads as "press 2" and then 2 focuses the This-run box
        # instead (UAT 2026-08-31). h and r are unambiguous on every page.
        if key in ("h", "H"):
            self.page = 2
            return
        if key in ("r", "R"):
            self.page = 1
            return
        if key in ("TAB", "\t"):
            self.focus = self.focus % 5 + 1
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
                self.pinned_history_card = rows[self.history_selection].get("id")
            elif key in ("k", "UP") and rows:
                self.history_selection = max(0, self.history_selection - 1)
                self.pinned_history_card = rows[self.history_selection].get("id")
            elif key in ("ENTER", "\n", "\r") and rows:
                self.pinned_history_card = rows[self.history_selection].get("id")
            return
        if self.page == 3:
            journal = self.controller.get("journal") or []
            if key in ("j", "DOWN"):
                self.journal_offset = max(0, self.journal_offset - 1)
            elif key in ("k", "UP") and journal:
                self.journal_offset = min(len(journal) - 1, self.journal_offset + 1)
            elif key in ("ENTER", "\n", "\r"):
                self.composing = True
                self.compose_buffer = ""
                self.compose_notice = ""
            return None
        # The detail pane follows the cursor. It used to update only on enter,
        # so arrowing down the run list left the pane describing the card you
        # had moved away from: every intermediate row was rendered against the
        # wrong detail, and the reader had to press a key to find out what they
        # were already looking at.
        #
        # Enter still works and still does the one thing j/k cannot, which is
        # re-assert the pin after the poll above has re-derived it.
        if self.focus == 0:
            if key in ("j", "DOWN"):
                self.card_offset = min(max(0, len(self.card_body) - 1), self.card_offset + 1)
            elif key in ("k", "UP"):
                self.card_offset = max(0, self.card_offset - 1)
            return None
        rows = self.rows_for_focus()
        if key in ("j", "DOWN") and rows:
            self.selection[self.focus] = min(len(rows) - 1, self.selection[self.focus] + 1)
            self._follow_selection(rows)
        elif key in ("k", "UP") and rows:
            self.selection[self.focus] = max(0, self.selection[self.focus] - 1)
            self._follow_selection(rows)
        elif key in ("ENTER", "\n", "\r") and self.focus == 2 and rows:
            self.pinned_stage = rows[self.selection[2]].get("id")
            self.card_offset = 0
        elif key in ("ENTER", "\n", "\r") and self.focus == 4 and rows:
            # Escalations are the one panel where the answer is a conversation,
            # so enter opens the composer already carrying the stage and the
            # reason -- the controller inbox that m writes to, pre-addressed.
            stage_id, status, reason = rows[self.selection[4]]
            self.page = 3
            self.composing = True
            self.compose_buffer = "%s (%s: %s): " % (stage_id, status, reason)
            self.compose_notice = ""
            return None


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


def failure_reason(stage):
    """Why this stage needs a human, in the words the state file already uses.

    A status alone says a stage stopped, not what stopped it, and the operator's
    next move differs entirely between a verifier that read the work and failed
    it and a worker that exited without writing an envelope at all.
    """
    status = stage.get("status")
    if status == "stalled":
        return stage.get("stall_marker") or "exited without an envelope"
    if status == "verifier_failed":
        overall = stage.get("verifier_overall") or "FAIL"
        attempts = stage.get("verifier_attempts") or 0
        return "verifier %s on attempt %s" % (overall, attempts)
    return stage.get("stall_marker") or status or "unknown"


def escalation_rows(payload):
    """Rows for the escalations box: the current run's failures, and a halt.

    Scoped to the current run like every other panel on the page. Reading the
    flat stage list instead meant a failure from a run that finished days ago
    still sat in the box saying "needs you", in a repo with no current run at
    all -- the box was reporting history as though it were outstanding work.
    """
    rows = []
    if payload.get("halted"):
        rows.append(("HALTED", "halted", payload.get("halt_reason") or "budget"))
    for stage in current_run_stages(payload):
        if stage.get("status") in ("stalled", "verifier_failed", "failed"):
            rows.append((stage.get("id") or "?", stage.get("status"), failure_reason(stage)))
    return rows


def content_line(text, spans=None):
    return text, spans or []


def history_cards(payload):
    return (payload.get("history") or {}).get("cards") or []


def spend_error(payload):
    spend = payload.get("spend") or {}
    history = payload.get("history") or {}
    return spend.get("state_error") or history.get("state_error")


def spend_error_message(payload):
    error = spend_error(payload)
    if not error:
        return None
    if str(error).startswith("spend unavailable"):
        return error
    return "spend unavailable: %s" % error


def marked_tokens(value, marked=False):
    """History figures in thousands, matching the panels and the detail pane.

    short_tokens' 1.1M loses the resolution a reader needs to compare two
    stages: 1.1M against 1.4M hides three hundred thousand tokens, and beside
    a detail pane reading `in 159.5K cached 2.9M out 20.8K` the same line
    changed unit twice mid-sentence. One unit across the surface, and the
    reader can subtract in their head.
    """
    return tick_tokens(value or 0) + ("?" if marked else "")


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
    message = spend_error_message(state.payload)
    if message:
        return [content_line(message, [(0, len(message), ALERT)])]
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
    message = spend_error_message(state.payload)
    if message:
        return [content_line(message, [(0, len(message), ALERT)])]
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


SPINNER = "|/-\\"


def live_spend_suffix(payload, state):
    """The in-flight tail of the run spend line: which role is running, for how
    long, and what its transcript has cost so far. Empty when nothing is live.

    It shares the spend line rather than taking one of its own because the
    status panel is height-constrained and an extra row costs the run panel a
    stage."""
    parts = []
    for agent in payload.get("agents") or []:
        started = agent.get("started_at")
        epoch = parse_iso(started) if isinstance(started, str) else None
        if epoch is not None:
            ran = short_secs(max(0, state.now - epoch))
        elif isinstance(agent.get("elapsed_seconds"), (int, float)):
            ran = short_secs(max(0, int(agent["elapsed_seconds"])))
        else:
            ran = "?"
        live = agent.get("live_total_tokens")
        role = agent.get("role") or "agent"
        if live is None:
            # No transcript total read yet. Say so rather than printing a zero,
            # which would read as a role that is burning nothing.
            parts.append("%s %s live ?" % (role, ran))
        else:
            parts.append("%s %s +%s live" % (role, ran, tick_tokens(int(live))))
    if not parts:
        return ""
    # The turning bar is the liveness cue. observe_time already re-renders on
    # every whole second, so it moves once a second whether or not the figures
    # do: a number that has not changed in ten minutes and a loop that has died
    # look identical without it.
    return "  %s %s" % (SPINNER[int(state.monotonic_now) % len(SPINNER)], "  ".join(parts))


def status_lines(state):
    payload = state.payload
    agents = payload.get("agents") or []
    running = bool(agents)
    name = payload.get("name") or "repo"
    light = "RUNNING" if running else ("HALTED" if payload.get("halted") else "IDLE")
    run = current_run(payload)
    run_start = run.get("started_at") if run else None
    run_epoch = parse_iso(run_start) if isinstance(run_start, str) else None
    elapsed = short_secs(max(0, state.now - run_epoch)) if run_epoch is not None else None
    cap = payload.get("effective_token_cap") or payload.get("token_cap_total") or 0
    spent = payload.get("tokens_spent") or 0
    pct = int(spent * 100 / cap) if cap else 0
    lines = [
        content_line("● %s → dev  %s" % (name, light), [(0, 1, ACTIVE if running else DIM)]),
        content_line("last tick %s ago  tick #%s" % (relative_age(payload.get("last_tick_at"), state.now), payload.get("tick_count", 0))),
    ]
    warning = build_warning(payload)
    if warning:
        lines.append(content_line(warning, [(0, len(warning), ALERT)]))
    if state.loading:
        lines.append(content_line("first poll running...", [(0, 21, ACTIVE)]))
    elif payload.get("state_error"):
        message = "state error: %s" % payload["state_error"]
        lines.append(content_line(message, [(0, len("state error:"), ALERT)]))
    if run:
        # Two quantities that do not divide into one another used to share a
        # line: the run's own spend, then the repo's lifetime percentage of the
        # cap. Read left to right that invited "6.9M of 600.0M is 53%", which is
        # wrong by a factor of forty, and a figure that will not reconcile reads
        # as a budget rather than a measurement. They get a line each.
        error = spend_error(payload)
        if error:
            settled = "run spend unavailable"
        else:
            settled = "run spend %s  $%.2f actual" % (
                tick_tokens(run.get("tokens_total", 0)), run.get("cost_usd_est", 0) or 0)
        # An in-flight role is counted nowhere in that figure: the cost log gets
        # its row when the role exits, so on the CLI route the settled number
        # holds still for the length of a worker and reads as a static budget.
        # The transcript total the heartbeat already reads is the same
        # measurement arriving sooner, so it rides alongside rather than being
        # folded in: a role half-landed in the cost log and half in a live
        # transcript would otherwise be counted twice.
        suffix = live_spend_suffix(payload, state)
        spans = [] if error else [(len(settled) - 6, 6, DIM)]
        if suffix:
            spans.append((len(settled) + 2, 1, ACTIVE))
        lines.extend([
            content_line("run start %s  elapsed %s" % (run_start[-9:], elapsed)),
            content_line(settled + suffix, spans),
            content_line("repo %s of %s cap (%d%%)" % (
                tick_tokens(spent), tick_tokens(cap), pct)),
        ])
    else:
        lines.append(content_line("repo cap %s (%d%% lifetime used)" % (tick_tokens(cap), pct)))
    if state.focus == 1:
        lines[0][1].insert(0, (0, len(lines[0][0]), REVERSE))
    return lines


def status_update_lines(state, inner_width):
    """Panel 5: what the loop last said about this repo, newest at the bottom,
    with the refresh line beneath it.

    The refresh line used to live in the status panel, where it appeared and
    vanished with every poll and moved four lines under the reader's eye. It
    is the subject of this panel rather than an interruption in another one,
    so it can change as often as it likes."""
    lines = []
    rows = state.status_updates or []
    if not rows:
        lines.append(content_line("no tick log entries for this repo yet",
                                  [(0, 37, DIM)]))
    else:
        for clock, text in rows:
            prefix = ("%s  " % clock) if clock else ""
            body = (prefix + text)[:max(1, inner_width)]
            spans = [(0, len(prefix), DIM)] if prefix else []
            lines.append(content_line(body, spans))
    refresh = status_updates.age_line(
        state.data_started_at, state.monotonic_now, state.polling)
    lines.append(content_line(refresh, [(0, len(refresh), DIM)]))
    return lines


def run_lines(state, inner_width):
    payload = state.payload
    lines = []
    stages = ordered_run_stages(payload)
    if not stages:
        return [content_line("no current run · use the history tab", [(0, 14, DIM)])]

    rows = []
    for stage in stages:
        glyph, status, active_role = stage_state(payload, stage)
        worker = identity_alias(stage.get("worker"))
        verifier = identity_alias(stage.get("verifier"))
        pair = "%s→%s" % (worker, verifier)
        rows.append(({"glyph": glyph, "id": stage.get("id") or "?", "role": status,
                      "pair": pair, "tokens": tick_tokens(stage_total(payload, stage.get("id")))},
                     worker, verifier, active_role))

    gap = 2
    indent = 2
    widths = {
        "glyph": max(len(row[0]["glyph"]) for row in rows),
        "role": max(len(row[0]["role"]) for row in rows),
        "pair": max(len(row[0]["pair"]) for row in rows),
        "tokens": max(len(row[0]["tokens"]) for row in rows),
    }
    fixed = indent + sum(widths.values()) + gap * 4
    widths["id"] = max(1, inner_width - fixed)
    order = ["glyph", "id", "role", "pair", "tokens"]

    for index, (cells, worker, verifier, active_role) in enumerate(rows):
        selected = state.focus == 2 and state.selection[2] == index
        if len(cells["id"]) > widths["id"]:
            stage_id = cells["id"]
            first_prefix = "  %s  " % cells["glyph"]
            continuation_prefix = " " * len(first_prefix) + "│ "
            first_width = max(1, inner_width - len(first_prefix))
            continuation_width = max(1, inner_width - len(continuation_prefix))
            id_lines = [first_prefix + stage_id[:first_width]]
            remaining = stage_id[first_width:]
            while remaining:
                id_lines.append(continuation_prefix + remaining[:continuation_width])
                remaining = remaining[continuation_width:]
            for id_index, id_line in enumerate(id_lines):
                spans = [(0, len(id_line), REVERSE)] if selected else []
                if active_role and id_index == 0:
                    spans.append((2, 3, ACTIVE))
                lines.append(content_line(id_line, spans))
            cells = dict(cells, glyph="", id="└─")
        rendered = render_grouped_lines(
            cells, order, widths, {}, inner_width, indent="  ")[0].rstrip()
        spans = [(0, len(rendered), REVERSE)] if selected else []
        if active_role:
            alias = worker if active_role == "worker" else verifier
            start = rendered.find(alias, rendered.find(cells["pair"]))
            if start >= 0:
                spans.append((start, start + len(alias), ACTIVE))
        lines.append(content_line(rendered, spans))
    return lines


def agent_lines(state):
    lines = []
    agents = state.payload.get("agents") or []
    queue = state.payload.get("queue") or []
    for index, agent in enumerate(agents):
        alias = identity_alias(agent.get("identity"))
        elapsed = short_secs(agent.get("elapsed_seconds") or 0)
        budget = short_secs(agent.get("budget_seconds") or 0)
        role = agent.get("role") or "?"
        # A controller minds the whole queue rather than one stage, so it
        # registers no stage id. Printing the raw "-" reads as missing data.
        scope = agent.get("stage_id") or "?"
        if role == "controller" and scope in ("-", "?", ""):
            scope = "queue"
        live_usage = agent.get("live_usage")
        if isinstance(live_usage, dict):
            live_tokens = (int(live_usage.get("input_tokens") or 0)
                           + int(live_usage.get("output_tokens") or 0))
            burn = "LIVE %s%s" % (
                tick_tokens(live_tokens),
                " stale" if not live_usage.get("updated_at") else "",
            )
        else:
            burn = "n/a"
        text = "● %s %s  %s  %s  %s / %s" % (scope, role, alias, burn, elapsed, budget)
        spans = [(0, 1, ACTIVE)]
        burn_start = text.find(burn)
        if burn_start >= 0 and burn != "n/a":
            spans.append((burn_start, burn_start + len(burn), ACTIVE))
        if state.focus == 3 and state.selection[3] == index:
            spans.insert(0, (0, len(text), REVERSE))
        lines.append(content_line(text, spans))
    for stage in queue:
        text = "○ %s queued  %s / %s" % (
            stage.get("stage_id") or "?",
            identity_alias(stage.get("worker")),
            identity_alias(stage.get("verifier")),
        )
        lines.append(content_line(text, [(0, len(text), DIM)]))
    # A stage can be mid-flight with no process alive: one half has finished
    # and the loop has not dispatched the other yet, or the repo is paused
    # waiting out a provider window. "no live agents" was truthful but read
    # as broken while a card was visibly in progress (UAT 2026-08-31).
    if not agents:
        for stage in current_run_stages(state.payload):
            if stage.get("status") != "in_progress":
                continue
            paused_until = state.payload.get("paused_until")
            if paused_until:
                when = time.strftime("%H:%M", time.localtime(int(paused_until)))
                reason = state.payload.get("paused_reason") or ""
                cause = "rate limit" if ("429" in reason or "RateLimit" in reason) else "provider pause"
                text = "◌ %s waiting  next dispatch %s (%s)" % (
                    stage.get("id") or "?", when, cause)
            else:
                text = "◌ %s between dispatches  next tick resumes it" % (
                    stage.get("id") or "?")
            lines.append(content_line(text, [(0, len(text), DIM)]))
    return lines or [content_line("no live agents", [(0, 14, DIM)])]


def inbox_message_count(state):
    rows = (state.controller or {}).get("conversation") or []
    return len([row for row in rows if row.get("status") == "pending"])


def inbox_lines(state):
    rows = escalation_rows(state.payload)
    if not rows:
        return [content_line("no escalations or messages", [(0, 27, DIM)])]
    lines = []
    for index, (stage_id, status, reason) in enumerate(rows):
        heading = "✖ %s  needs you" % status
        spans = [(0, 1, ALERT)]
        if state.focus == 4 and state.selection[4] == index:
            spans.insert(0, (0, len(heading), REVERSE))
        lines.append(content_line(heading, spans))
        # The reason rides on the stage line rather than its own: the box is
        # sized in whole rows and an extra line per escalation overflowed it at
        # 80 columns. A long reason truncates horizontally instead.
        detail = "  %s · %s" % (stage_id, reason)
        lines.append(content_line(detail, [(len(stage_id) + 2, len(detail), DIM)]))
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


def stage_timing_line(stage, now):
    """When the run started, and when it stopped if it has.

    The pane showed elapsed-against-budget, which answers "how long has this
    been going" but not "when did it go" -- the question asked when reading a
    stage that finished hours ago, or matching a run against a log line.
    """
    started = parse_iso(stage.get("started_at")) if isinstance(stage.get("started_at"), str) else None
    ended = parse_iso(stage.get("completed_at")) if isinstance(stage.get("completed_at"), str) else None
    if started is None and ended is None:
        return "not started"
    if started is None:
        return "ended %s (%s ago)" % (time.strftime("%d %b %H:%M", time.localtime(ended)),
                                      short_secs(max(0, now - ended)))
    text = time.strftime("%d %b %H:%M", time.localtime(started))
    if ended is not None:
        text += " → %s  (ran %s)" % (time.strftime("%H:%M", time.localtime(ended)),
                                     short_secs(max(0, ended - started)))
    else:
        text += "  (%s ago)" % short_secs(max(0, now - started))
    return text


def stage_queue_line(payload, stage):
    """Where this stage sits in the queue the tick will actually dispatch from.

    Position comes from the queue array rather than from the stage's own id or
    its place in the table: the id is an authoring order and the table is
    sorted for reading, while the queue is the order work will really be taken
    in. A stage that is not in it is not waiting, and says what it is instead.
    """
    queue = [q.get("stage_id") for q in (payload.get("queue") or []) if isinstance(q, dict)]
    stage_id = stage.get("id")
    depth = len(queue)
    if stage_id in queue:
        position = queue.index(stage_id) + 1
        nxt = " — next up" if position == 1 else ""
        return "%d of %d waiting%s" % (position, depth, nxt)
    status = (stage.get("status") or "").replace("_", " ")
    if stage.get("status") == "in_progress":
        # Depth is worth saying only while something is running: it answers
        # "what happens when this finishes". On a stage that finished hours ago
        # it is a fact about the queue, not about the stage being read.
        return "running now (%d waiting behind)" % depth if depth else "running now (nothing waiting)"
    return "not queued — %s" % (status or "unknown")


def detail_lines(state, inner_width, inner_height=None):
    stages = ordered_run_stages(state.payload)
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
    live_usage = agent.get("live_usage")
    if isinstance(live_usage, dict):
        live_input = int(live_usage.get("input_tokens") or 0)
        live_output = int(live_usage.get("output_tokens") or 0)
        live_text = "LIVE in %s out %s%s" % (
            tick_tokens(live_input), tick_tokens(live_output),
            " stale" if not live_usage.get("updated_at") else "",
        )
    else:
        live_text = "n/a"
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
        # Both facts share a row on purpose. At 80 columns the detail pane's
        # line budget is spent by the stage card below it, and tui-smoke
        # asserts that card is never truncated there -- two rows here cost two
        # rows of the card and turned it into "and 2 more".
        content_line("queue     %s · %s" % (stage_queue_line(state.payload, stage),
                                            stage_timing_line(stage, state.now))),
        content_line("budget    %s / %s (%d%% used)" % (short_secs(elapsed), short_secs(budget), budget_pct)),
        content_line("card      %s" % (stage.get("card") or "stage-cards/%s.md" % stage.get("id"))),
        content_line(""),
        content_line("─ acceptance " + "─" * max(0, inner_width - 13)),
        content_line(stage.get("acceptance") or "see stage card"),
        content_line(""),
        content_line("tokens  in %s  cached %s  out %s  $%.2f" % (
            tick_tokens(usage.get("input_tokens", 0)), tick_tokens(usage.get("cached_input_tokens", 0)),
            tick_tokens(usage.get("output_tokens", 0)), usage.get("cost_usd_est", 0) or 0)),
        content_line("live      %s" % live_text,
                     [(10, 10 + len(live_text), ACTIVE)] if live_text != "n/a" else [(10, 13, DIM)]),
        # The burn rate stays on short_tokens. It is a per-minute figure in the
        # low thousands, so it never reaches the millions this change is about,
        # and 14.4K/min carries a decimal that 14k/min would floor away --
        # on the one number here whose movement is the point.
        content_line("%s  burn last 8 polls (%s/min)" % (spark, short_tokens(rate))),
    ])
    lines = wrap_content_lines(lines, inner_width)
    capacity = None if inner_height is None else max(0, inner_height - len(lines))
    lines.extend(card_body_lines(state, inner_width, capacity))
    return lines


def card_body_lines(state, inner_width, capacity=None):
    """The stage card itself, under the metadata that summarises it.

    The detail pane described the card; the question it was usually opened to
    answer was what the card actually said. It scrolls with focus 0 (j/k)
    because it is the one panel longer than its box; o still opens the whole
    card in a pager or its own tmux window.
    """
    body = state.card_body or []
    if not body:
        block = [content_line(""),
                 content_line("─ stage card " + "─" * max(0, inner_width - 13)),
                 content_line("card not read", [(0, 13, DIM)])]
    else:
        offset = min(max(0, state.card_offset), max(0, len(body) - 1))
        heading = "─ stage card %d/%d " % (offset + 1, len(body))
        block = [content_line(""),
                 content_line(heading + "─" * max(0, inner_width - len(heading)))]
        for raw in body[offset:]:
            block.append(content_line(raw.rstrip()))
    block = wrap_content_lines(block, inner_width)
    if capacity is None:
        return block
    if capacity <= 0:
        return []
    # The pane keeps its own overflow marker rather than letting draw_box
    # truncate it. A box that silently drops rows is a bug everywhere else on
    # this page; here the rows are meant to be off-screen, and the reader needs
    # to be told they scroll rather than that they went missing.
    if len(block) > capacity:
        keep = max(0, capacity - 1)
        hidden = len(block) - keep
        note = "── %d more line(s) · press 0 then j/k ──" % hidden
        block = block[:keep] + [content_line(note[:inner_width], [(0, len(note), DIM)])]
    return block


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


def _journal_window(state, capacity):
    rows = state.controller.get("journal") or []
    if not rows:
        return [content_line("no controller record yet", [(0, 24, DIM)]),
                content_line("the controller's first decision will populate this strip", [(0, 55, DIM)])]
    end = max(0, len(rows) - state.journal_offset)
    available = max(1, capacity)
    start = max(0, end - available)
    if start > 0:
        start = max(0, end - max(1, available - 1))
    visible = rows[start:end]
    lines = []
    if start > 0:
        label = "and %d earlier" % start
        lines.append(content_line(label, [(0, len(label), DIM)]))
    for row in visible:
        text = "%s  %-8s  %s" % (row.get("time") or "?", row.get("kind") or "decision",
                                  row.get("summary") or "recorded")
        kind_start = 7
        attr = ALERT if row.get("kind") == "refusal" else BOLD
        lines.append(content_line(text, [(kind_start, kind_start + len(row.get("kind") or "decision"), attr)]))
    return lines[-available:]


def _conversation_lines(state, capacity):
    rows = state.controller.get("conversation") or []
    if not rows:
        empty = [content_line("no operator messages or controller replies yet", [(0, 45, DIM)]),
                 content_line("press m to write; replies arrive after the controller's next pass", [(0, 63, DIM)])]
        return empty[:max(1, capacity)]
    lines = []
    for row in rows:
        status = row.get("status")
        marker = " [%s]" % status if status in ("pending", "refusal") else ""
        text = "%-4s  %s%s  %s" % (row.get("speaker") or "?", row.get("time") or "?", marker,
                                   row.get("text") or "")
        spans = []
        if status == "pending":
            start = text.find("[pending]")
            spans.append((start, start + 9, ACTIVE))
        elif status == "refusal":
            start = text.find("[refusal]")
            spans.append((start, start + 9, ALERT))
        lines.append(content_line(text, spans))
    if len(lines) > capacity:
        hidden = len(lines) - max(1, capacity - 1)
        label = "and %d earlier messages" % hidden
        lines = [content_line(label, [(0, len(label), DIM)])] + lines[-max(1, capacity - 1):]
    return lines[:capacity]


def render_messages(canvas, state, width, usable):
    inner_height = max(1, usable - 2)
    journal_capacity = min(8, max(2, (inner_height - 5) // 2))
    journal = _journal_window(state, journal_capacity)
    separator = "── inbox " + "─" * max(0, width - 15)
    input_separator = "── message " + "─" * max(0, width - 17)
    fixed = len(journal) + 4 + (1 if state.compose_notice else 0)
    conversation = _conversation_lines(state, max(1, inner_height - fixed))
    # Cursor only. The key hint used to be concatenated onto the input line
    # right after the cursor, unstyled, so it read as text the operator had
    # somehow typed into their own message. The footer already states the keys
    # for the whole time the composer is open, which is where a hint belongs.
    prompt = "> " + state.compose_buffer + ("_" if state.composing else "")
    if not state.composing:
        prompt = "> press m or enter to message the controller"
    lines = journal + [content_line(separator, [(0, 8, BOLD)])]
    lines += conversation + [content_line(input_separator, [(0, 10, BOLD)]), content_line(prompt)]
    if state.compose_notice:
        attr = ALERT if state.compose_notice.startswith("not queued") else DIM
        lines.append(content_line(state.compose_notice, [(0, len(state.compose_notice), attr)]))
    draw_box(canvas, (0, 0, width, usable), "[0]─Controller", lines, state.composing)


def footer(canvas, state):
    if state.composing:
        text = "message draft  enter send · esc cancel"
        canvas.put(0, canvas.height - 1, text[:canvas.width])
        for x in range(min(canvas.width, len(text))):
            canvas.attrs[canvas.height - 1][x] = ACTIVE
        return
    tabs = "[r]un [h]istory [m]essages"
    if state.page == 1:
        hints = ("  1-5 focus · 0 card · j/k select · enter detail · [ ] page"
                 " · o page card · O default viewer · q quit")
    else:
        hints = "  j/k scroll · enter reply · esc run page · q quit"
    text = tabs + hints
    if len(text) > canvas.width:
        # The narrow fallback still has to name a way off this page, which is
        # the thing a reader is stuck without.
        text = tabs + ("  1-5 focus · [ ] page · q quit" if state.page == 1
                       else "  esc run page · q quit")
    # A card-open result replaces the hint line until the next keypress. The
    # hints are always recoverable; a silent failure to open a card is not.
    if getattr(state, "card_notice", ""):
        notice = state.card_notice[:canvas.width]
        canvas.put(0, canvas.height - 1, notice)
        attr = ALERT if notice.startswith("could not") or notice.startswith("card not found") else DIM
        for x in range(min(canvas.width, len(notice))):
            canvas.attrs[canvas.height - 1][x] = attr
        return
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
        render_messages(canvas, state, width, height - 1)
        footer(canvas, state)
        return canvas

    usable = height - 1
    stacked = width <= 80
    stages = ordered_run_stages(state.payload)
    done = len([s for s in stages if s.get("status") == "completed"])
    run_title = "[2]─This run  %d of %d" % (done, len(stages))
    live_count = len(state.payload.get("agents") or [])
    queued_count = len(state.payload.get("queue") or [])
    if "queue" in state.payload:
        agents_title = "[3]─Agents  %d live, %d queued" % (live_count, queued_count)
    else:
        agents_title = "[3]─Agents  %d live" % live_count
    esc_count = len(escalation_rows(state.payload))
    msg_count = inbox_message_count(state)
    # Two lines per escalation, so a fixed four-line box showed one row and hid
    # the rest behind "and N more" -- including the reasons it exists to show.
    # It still yields first when the terminal is short; it just asks for enough.
    inbox_desired = max(4, min(12, 2 + 2 * esc_count))
    if not stacked:
        left_width = min(86, max(74, int(width * 0.52)))
        left_width = min(left_width, width - 45)
        right_x = left_width + 1
        right_width = width - right_x
        panel_total = usable - 4
        # Panel 5 shrinks first and to the smallest floor: it is the one panel
        # whose content is a tail, so losing rows costs the reader the oldest
        # lines rather than a whole subject.
        heights = fit_heights([8, 16, 6, inbox_desired, 8], [5, 5, 4, 3, 3],
                              panel_total, [4, 1, 2, 0, 3])
        status_h, run_h, agents_h, inbox_h, updates_h = heights
        y1 = 0
        y2 = y1 + status_h + 1
        y3 = y2 + run_h + 1
        y4 = y3 + agents_h + 1
        y5 = y4 + inbox_h + 1
        draw_box(canvas, (0, y1, left_width, status_h), "[1]─Status", status_lines(state), state.focus == 1)
        draw_box(canvas, (0, y2, left_width, run_h), run_title,
                 run_lines(state, left_width - 4), state.focus == 2)
        draw_box(canvas, (0, y3, left_width, agents_h), agents_title,
                 agent_lines(state), state.focus == 3)
        draw_box(canvas, (0, y4, left_width, inbox_h), "[4]─Escalations & inbox  %d · %d" % (esc_count, msg_count),
                 inbox_lines(state), state.focus == 4)
        draw_box(canvas, (0, y5, left_width, updates_h), "[5]─Status updates",
                 status_update_lines(state, left_width - 4), state.focus == 5)
        draw_box(canvas, (right_x, 0, right_width, usable), "[0]─Card detail",
                 detail_lines(state, right_width - 4, max(0, usable - 2)),
                 state.focus == 0)
    else:
        available = usable - 5
        heights = fit_heights([8, 18, 6, inbox_desired, 6, 18], [4, 5, 3, 3, 3, 6],
                              available, [4, 1, 5, 2, 0, 3])
        status_h, run_h, agents_h, inbox_h, updates_h, detail_h = heights
        rects = []
        cursor = 0
        for panel_height in heights:
            rects.append((0, cursor, width, panel_height))
            cursor += panel_height + 1
        draw_box(canvas, rects[0], "[1]─Status", status_lines(state), state.focus == 1)
        draw_box(canvas, rects[1], run_title, run_lines(state, width - 4), state.focus == 2)
        draw_box(canvas, rects[2], agents_title, agent_lines(state), state.focus == 3)
        draw_box(canvas, rects[3], "[4]─Escalations & inbox  %d · %d" % (esc_count, msg_count),
                 inbox_lines(state), state.focus == 4)
        draw_box(canvas, rects[4], "[5]─Status updates",
                 status_update_lines(state, width - 4), state.focus == 5)
        draw_box(canvas, rects[5], "[0]─Card detail",
                 detail_lines(state, width - 4, max(0, detail_h - 2)), state.focus == 0)
    footer(canvas, state)
    return canvas
