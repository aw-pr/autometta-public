// dashboard.js: vanilla JS renderer for ~/.autometta/dashboard/.
// Reads the aggregator's data seam and draws the fleet and cost views.
//
// One renderer serves both scopes. A per-repo page is this same document over a
// data.json whose repos[] holds a single entry, narrowed by the aggregator's
// --only, so nothing here branches on scope beyond hiding a filter that would
// have one checkbox in it.

(function () {
  "use strict";

  var FALLBACK_PAGE_SIZE = 10;
  var PAGE_SIZE_CHOICES = [10, 25, 50, 0]; // 0 means every row

  // Ranges slice the token charts by stage completion date. 0 means no cutoff.
  var RANGE_CHOICES = [
    { days: 1, label: "24h" },
    { days: 7, label: "7d" },
    { days: 30, label: "30d" },
    { days: 0, label: "all" }
  ];

  var state = {
    data: null,
    hidden: Object.create(null), // repo name -> true once deselected
    pageSize: Object.create(null),
    page: Object.create(null),
    rangeDays: null,
    // Which expander rows are open. This has to live in state rather than in
    // the DOM: a poll re-renders every table, and a reader mid-way through a
    // stage card should not have it collapse under them every few seconds.
    expanded: Object.create(null),
    lastGeneratedAt: null,
    pollFailures: 0
  };
  var charts = Object.create(null);

  function fmtInt(n) {
    if (n == null) return "-";
    return Number(n).toLocaleString("en-US");
  }
  function esc(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, function (c) {
      return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c];
    });
  }
  function shortIdentity(s) {
    if (!s) return "unknown";
    var idx = s.indexOf("<");
    return idx > 0 ? s.slice(0, idx).trim() : s;
  }

  // A page opened from file:// in a browser set to block site data throws on
  // the accessor itself, so every read and write is guarded and the page falls
  // back to the generated default.
  function storeGet(key) {
    try { return window.localStorage.getItem(key); } catch (e) { return null; }
  }
  function storeSet(key, value) {
    try { window.localStorage.setItem(key, value); } catch (e) { /* not fatal */ }
  }

  function defaultPageSize() {
    var n = Number(state.data && state.data.page_size_default);
    return isFinite(n) && n >= 0 ? n : FALLBACK_PAGE_SIZE;
  }

  function pageSizeFor(key) {
    if (state.pageSize[key] != null) return state.pageSize[key];
    var stored = parseInt(storeGet("autometta.pageSize." + key), 10);
    state.pageSize[key] = isFinite(stored) && stored >= 0 ? stored : defaultPageSize();
    return state.pageSize[key];
  }

  function setPageSize(key, size) {
    state.pageSize[key] = size;
    state.page[key] = 0;
    storeSet("autometta.pageSize." + key, String(size));
  }

  // --- per-stage spend -----------------------------------------------------

  // Tokens are written onto a stage row when it completes. A stage that
  // stalled never gets that write, so its row reads 0 while the cost log knows
  // it burned over a million -- which is why a repo whose whole run stalled
  // drew empty charts. Fall back to the cost log, which carries the same
  // figures per stage and per role.
  function stageSpend(repo, stage) {
    var worker = Number(stage.worker_tokens || 0);
    var verifier = Number(stage.verifier_tokens || 0);
    var total = Number(stage.tokens || 0);
    if (total || worker || verifier) {
      return { worker: worker, verifier: verifier, total: total || worker + verifier, logged: false };
    }
    var spend = repo.spend || {};
    var logged = 0;
    (spend.by_stage || []).forEach(function (row) {
      if (row.stage_id === stage.id) logged += Number(row.tokens || 0);
    });
    (spend.failures || []).forEach(function (row) {
      if (row.stage_id !== stage.id) return;
      var lost = Number(row.tokens_lost || 0);
      if (row.role === "verifier") verifier += lost;
      else worker += lost;
    });
    total = logged || worker + verifier;
    return { worker: worker, verifier: verifier, total: total, logged: total > 0 };
  }

  // A stage that never completed still happened, and dating it by when it was
  // dispatched is what puts a stalled run on the per-day chart at all.
  function stageWhen(stage) {
    return stage.completed_at || stage.started_at || null;
  }

  // --- time range ----------------------------------------------------------

  function rangeDays() {
    if (state.rangeDays != null) return state.rangeDays;
    var stored = parseInt(storeGet("autometta.rangeDays"), 10);
    state.rangeDays = isFinite(stored) && stored >= 0 ? stored : 0;
    return state.rangeDays;
  }

  function rangeLabel() {
    var days = rangeDays();
    for (var i = 0; i < RANGE_CHOICES.length; i++) {
      if (RANGE_CHOICES[i].days === days) return RANGE_CHOICES[i].label;
    }
    return "all";
  }

  // Work that has not completed has no date to test, and excluding it would
  // hide the live run from every chart. It is current by definition, so it
  // stays in whatever range is selected.
  function stageInRange(stage) {
    var days = rangeDays();
    if (!days) return true;
    var when = stageWhen(stage);
    if (!when) return true;
    var t = Date.parse(when);
    return !isFinite(t) || t >= Date.now() - days * 86400000;
  }

  // The charts all read the same seam: visible repos, stages within range.
  function visibleStages() {
    var out = [];
    visibleRepos().forEach(function (r) {
      (r.stages || []).forEach(function (s) {
        if (stageInRange(s)) out.push({ repo: r.name, stage: s, spend: stageSpend(r, s) });
      });
    });
    return out;
  }

  function renderRangeFilter() {
    var wrap = document.getElementById("range-filter");
    if (!wrap) return;
    var days = rangeDays();
    wrap.innerHTML = '<span class="filter-label">tokens over</span>' +
      RANGE_CHOICES.map(function (choice) {
        return '<button type="button" data-range="' + choice.days + '"' +
          (choice.days === days ? ' class="on"' : "") + ">" + choice.label + "</button>";
      }).join("");
    wrap.querySelectorAll("button[data-range]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        state.rangeDays = parseInt(btn.getAttribute("data-range"), 10) || 0;
        storeSet("autometta.rangeDays", String(state.rangeDays));
        renderAll();
      });
    });
  }

  // --- repo filter ---------------------------------------------------------

  function visibleRepos() {
    return (state.data.repos || []).filter(function (r) { return !state.hidden[r.name]; });
  }

  function visibleNames() {
    var names = Object.create(null);
    visibleRepos().forEach(function (r) { names[r.name] = true; });
    return names;
  }

  function renderRepoFilter() {
    var wrap = document.getElementById("repo-filter");
    if (!wrap) return;
    var repos = state.data.repos || [];
    // A narrowed page has exactly one repo and nothing to choose between.
    if (state.data.scope !== "fleet" || repos.length < 2) {
      wrap.innerHTML = "";
      return;
    }
    var html = '<span class="filter-label">repos</span>';
    repos.forEach(function (r) {
      html +=
        '<label class="filter-chip' + (state.hidden[r.name] ? " off" : "") + '">' +
        '<input type="checkbox" data-repo="' + esc(r.name) + '"' +
        (state.hidden[r.name] ? "" : " checked") + " /> " +
        '<span class="status ' + esc(r.light) + '"></span>' + esc(r.name) +
        "</label>";
    });
    html +=
      '<button type="button" data-filter-all="on">all</button>' +
      '<button type="button" data-filter-all="off">none</button>';
    wrap.innerHTML = html;

    wrap.querySelectorAll("input[data-repo]").forEach(function (box) {
      box.addEventListener("change", function () {
        var name = box.getAttribute("data-repo");
        if (box.checked) delete state.hidden[name];
        else state.hidden[name] = true;
        resetPages();
        renderAll();
      });
    });
    wrap.querySelectorAll("button[data-filter-all]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var on = btn.getAttribute("data-filter-all") === "on";
        state.hidden = Object.create(null);
        if (!on) repos.forEach(function (r) { state.hidden[r.name] = true; });
        resetPages();
        renderAll();
      });
    });
  }

  function resetPages() {
    state.page = Object.create(null);
  }

  // --- tables --------------------------------------------------------------

  function tableHtml(headers, rows) {
    var html = '<table class="stages"><thead><tr>' + headers.map(function (h) {
      return "<th>" + esc(h.label != null ? h.label : h) + "</th>";
    }).join("") + "</tr></thead><tbody>";
    rows.forEach(function (row, index) {
      var cells = row;
      var rowCls = "";
      var expand = null;
      if (row && !Array.isArray(row) && row.cells) {
        cells = row.cells;
        rowCls = row.cls || "";
        expand = row.expand || null;
      }
      var attrs = "";
      var key = (row && row.key != null) ? row.key : index;
      if (expand) {
        rowCls = (rowCls + " clickable").trim();
        attrs = ' data-expand="' + esc(key) + '"';
      }
      html += "<tr" + (rowCls ? ' class="' + esc(rowCls) + '"' : "") + attrs + ">" +
        cells.map(function (cell) {
          if (cell && typeof cell === "object" && cell.html != null) {
            return '<td class="' + esc(cell.cls || "") + '">' + cell.html + "</td>";
          }
          return "<td>" + esc(cell) + "</td>";
        }).join("") + "</tr>";
      if (expand) {
        html += '<tr class="expand-row" data-expand-for="' + esc(key) + '" hidden>' +
          '<td colspan="' + headers.length + '">' + expand + "</td></tr>";
      }
    });
    return html + "</tbody></table>";
  }

  // A row carrying an expand payload gets a hidden sibling row beneath it and
  // toggles it on click. Open rows are recorded in state.expanded and restored
  // on the next render, so polling does not shut a card the reader has open.
  // The key is scoped by wrapper id: two tables may both carry a row keyed on
  // the same stage id.
  function bindExpanders(wrap) {
    var scope = (wrap.id || "") + "\u0000";
    wrap.querySelectorAll("tr[data-expand]").forEach(function (row) {
      var key = row.getAttribute("data-expand");
      var stateKey = scope + key;
      var target = wrap.querySelector('tr.expand-row[data-expand-for="' + key + '"]');
      if (target && state.expanded[stateKey]) {
        target.hidden = false;
        row.classList.add("open");
      }
      row.addEventListener("click", function () {
        if (!target) return;
        target.hidden = !target.hidden;
        row.classList.toggle("open", !target.hidden);
        if (target.hidden) delete state.expanded[stateKey];
        else state.expanded[stateKey] = true;
      });
    });
  }

  function renderSimpleTable(id, headers, rows) {
    var wrap = document.getElementById(id);
    if (!rows.length) {
      wrap.innerHTML = '<p class="empty">(none)</p>';
      return;
    }
    wrap.innerHTML = tableHtml(headers, rows);
    bindExpanders(wrap);
  }

  // Paged sibling of renderSimpleTable. `key` names the table for the stored
  // page size; `footer` is a row pinned below every page (a totals line), which
  // must not be paginated away.
  function renderPagedTable(id, headers, rows, key, footer) {
    var wrap = document.getElementById(id);
    if (!rows.length) {
      wrap.innerHTML = '<p class="empty">(none)</p>';
      return;
    }
    var size = pageSizeFor(key);
    var pages = size > 0 ? Math.max(1, Math.ceil(rows.length / size)) : 1;
    var page = Math.min(Math.max(state.page[key] || 0, 0), pages - 1);
    state.page[key] = page;

    var start = size > 0 ? page * size : 0;
    var shown = size > 0 ? rows.slice(start, start + size) : rows;
    if (footer) shown = shown.concat([footer]);

    var range = size > 0
      ? fmtInt(start + 1) + "-" + fmtInt(start + shown.length - (footer ? 1 : 0))
      : "all";
    var controls =
      '<div class="pager">' +
      '<label>show <select data-pagesize>' +
      PAGE_SIZE_CHOICES.map(function (n) {
        return '<option value="' + n + '"' + (n === size ? " selected" : "") + ">" +
          (n === 0 ? "all" : n) + "</option>";
      }).join("") +
      "</select> of " + fmtInt(rows.length) + "</label>" +
      '<span class="pager-range">' + range + "</span>" +
      '<button type="button" data-page="prev"' + (page === 0 ? " disabled" : "") + ">prev</button>" +
      '<span class="pager-page">' + (page + 1) + " / " + pages + "</span>" +
      '<button type="button" data-page="next"' + (page >= pages - 1 ? " disabled" : "") + ">next</button>" +
      "</div>";

    wrap.innerHTML = tableHtml(headers, shown) + controls;
    bindExpanders(wrap);

    wrap.querySelector("select[data-pagesize]").addEventListener("change", function (ev) {
      setPageSize(key, parseInt(ev.target.value, 10) || 0);
      renderAll();
    });
    wrap.querySelectorAll("button[data-page]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        state.page[key] = page + (btn.getAttribute("data-page") === "next" ? 1 : -1);
        renderAll();
      });
    });
  }

  function stageKey(repo, stageId) {
    return repo + "/" + stageId;
  }

  // Reveal one stage's card in the table, from wherever the reader clicked.
  // The table is paged, so a stage the chart names may not be on the page
  // currently shown; page to it first, then expand and scroll to it.
  function openStageCard(repo, stageId) {
    var key = stageKey(repo, stageId);
    var order = state.stageRowOrder || [];
    var index = order.indexOf(key);
    var size = pageSizeFor("stages");
    if (index >= 0 && size > 0) state.page.stages = Math.floor(index / size);
    renderAll();
    var wrap = document.getElementById("stages-table-wrap");
    var row = wrap.querySelector('tr[data-expand="' + key + '"]');
    var target = wrap.querySelector('tr.expand-row[data-expand-for="' + key + '"]');
    if (!row || !target) return;
    target.hidden = false;
    row.classList.add("open");
    row.scrollIntoView({ block: "center", behavior: "smooth" });
  }

  // --- panels --------------------------------------------------------------

  function renderReposGrid(repos) {
    var grid = document.getElementById("repos-grid");
    grid.innerHTML = "";
    repos.forEach(function (r) {
      var div = document.createElement("div");
      div.className = "repo-card" + (r.light === "red" ? " halted" : "");
      var pct = r.token_cap_total > 0 ? Math.round((r.tokens_spent / r.token_cap_total) * 100) : 0;
      div.innerHTML =
        '<div class="name"><span class="status ' + esc(r.light) + '">' +
          esc(({ green: "ok", amber: "WARN", red: "FAIL" })[r.light] || "?") +
          "</span> " + esc(r.name) + "</div>" +
        '<div class="path">' + esc(r.repo_path) + "</div>" +
        '<div class="row"><span>rule</span><span>' + esc(r.light_reason) + "</span></div>" +
        '<div class="row"><span>tokens spent</span><span>' + fmtInt(r.tokens_spent) + "</span></div>" +
        '<div class="row"><span>cap</span><span>' + fmtInt(r.token_cap_total) + " (" + pct + "%)</span></div>" +
        '<div class="row"><span>stages</span><span>' + r.stages.length + "</span></div>" +
        (r.halted ? '<div class="row"><span>halted</span><span>' + esc(r.halt_reason || "") + "</span></div>" : "");
      grid.appendChild(div);
    });
  }

  function renderAgents(repos) {
    var rows = [];
    repos.forEach(function (r) {
      (r.agents || []).forEach(function (a) {
        var elapsed = fmtInt(a.elapsed_seconds || 0) + "s";
        if (a.budget_seconds) elapsed += " / " + fmtInt(a.budget_seconds) + "s";
        var usage = a.live_usage;
        var burn = "n/a";
        if (usage) {
          burn = "LIVE " + fmtInt(Number(usage.input_tokens || 0) + Number(usage.output_tokens || 0));
          if (!usage.updated_at) burn += " (stale)";
        }
        rows.push([r.name, "live", a.stage_id, a.role, a.identity || a.family, "-", burn, elapsed]);
      });
      (r.queue || []).forEach(function (q) {
        rows.push([r.name, "next", q.stage_id, "queued", q.worker, q.verifier, "-", "-"]);
      });
    });
    renderSimpleTable("agents-table-wrap",
      ["Repo", "Kind", "Stage", "Role", "Agent / worker", "Verifier", "Live burn", "Elapsed / budget"], rows);
  }

  function renderFailures(spend, names) {
    // The aggregator sorts failures newest first, so page one is the most
    // recent N without a second sort here.
    var failures = (spend.failures || []).filter(function (f) { return names[f.repo]; });
    var rows = failures.map(function (f) {
      return [f.repo, f.stage_id, f.role, f.result, fmtInt(f.tokens_lost), f.ts];
    });
    var footer = ["TOTAL LOST", "-", "-", "non-pass",
      fmtInt(failures.reduce(function (n, f) { return n + Number(f.tokens_lost || 0); }, 0)), "7d"];
    renderPagedTable("failures-table-wrap",
      ["Repo", "Stage", "Role", "Result", "Tokens lost", "When"], rows, "failures", footer);
  }

  function renderSpend(spend, names) {
    var byRepoRole = (spend.by_repo_role || []).filter(function (r) { return names[r.repo]; });
    var rows = byRepoRole.map(function (r) {
      return [r.repo, r.role, fmtInt(r.input_tokens), fmtInt(r.cached_input_tokens),
        fmtInt(r.output_tokens), fmtInt(r.productive_tokens), fmtInt(r.lost_tokens),
        "$" + Number(r.cost_usd_est || 0).toFixed(2)];
    });
    // This table is today's cost log, so a repo that last ran yesterday
    // contributes no rows and used to vanish from it entirely -- which reads as
    // "never spent anything" for a repo sitting on a 240M-token window. An
    // explicit zero row says "nothing today" instead of saying nothing at all.
    var seen = Object.create(null);
    byRepoRole.forEach(function (r) { seen[r.repo] = true; });
    visibleRepos().forEach(function (r) {
      if (seen[r.name]) return;
      rows.push([r.name, "-", "0", "0", "0", "0", "0", "$0.00"]);
    });
    rows.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
    renderSimpleTable("spend-table-wrap",
      ["Repo", "Role", "Input", "Cached", "Output", "Pass", "Lost", "Cost"], rows);
    // Totals follow the filter, so a narrowed view reports its own spend
    // rather than the fleet's. The window figure sits beside the daily one
    // because the two differ by orders of magnitude and only one is labelled.
    var repos = visibleRepos();
    var tokens = repos.reduce(function (n, r) { return n + Number((r.spend || {}).tokens_total || 0); }, 0);
    var cost = repos.reduce(function (n, r) { return n + Number((r.spend || {}).cost_usd_est || 0); }, 0);
    var window_ = repos.reduce(function (n, r) { return n + Number(r.tokens_spent || 0); }, 0);
    document.getElementById("spend-total").textContent =
      "today (UTC) " + fmtInt(tokens) + " tokens / $" + cost.toFixed(2) +
      "  -  budget window " + fmtInt(window_) + " tokens";
  }

  function renderQuota(repos) {
    var rows = [];
    repos.forEach(function (repo) {
      ["claude", "codex"].forEach(function (family) {
        var reading = ((repo.quota || {}).families || {})[family] || {
          status: "unknown", reason: "no tick reading", windows: []
        };
        if (reading.status !== "known") {
          rows.push([repo.name, family, "unknown", "-", "-", reading.reason || "unknown"]);
          return;
        }
        (reading.windows || []).forEach(function (window) {
          rows.push([repo.name, family, window.label,
            Number(window.utilization).toFixed(1) + "%", window.resets_at || "unknown",
            reading.source || "unknown"]);
        });
      });
    });
    renderPagedTable("quota-table-wrap",
      ["Repo", "Family", "Window", "Used", "Resets", "Source / reason"], rows, "quota", null);
  }

  function renderStagesTable(repos) {
    var rows = [];
    repos.forEach(function (r) {
      // Grouped by repo, because a fleet view interleaved by time reads as
      // noise; the filter narrows which repos appear, the grouping keeps each
      // one's run legible once several are showing.
      var group = r.stages.map(function (s) { return { repo: r.name, stage: s }; });
      // Newest queue time at the top, with stages not yet dispatched above the
      // dated ones: page one is then the live end of the run, not its oldest card.
      group.sort(function (a, b) {
        var at = a.stage.started_at || a.stage.completed_at;
        var bt = b.stage.started_at || b.stage.completed_at;
        if (!at && !bt) return 0;
        if (!at) return -1;
        if (!bt) return 1;
        return at < bt ? 1 : at > bt ? -1 : 0;
      });
      group.forEach(function (row, i) { row.groupStart = i === 0; rows.push(row); });
    });
    // The chart addresses table rows by key, and needs the row order to work
    // out which page a stage has landed on.
    state.stageRowOrder = rows.map(function (row) { return stageKey(row.repo, row.stage.id); });
    var byName = Object.create(null);
    repos.forEach(function (r) { byName[r.name] = r; });
    var cells = rows.map(function (row) {
      var s = row.stage;
      var spend = stageSpend(byName[row.repo] || {}, s);
      // A figure recovered from the cost log is marked, because it is a
      // different measurement from one the stage recorded on completion.
      var mark = spend.logged ? "*" : "";
      var cardPath = s.card || ("stage-cards/" + s.id + ".md");
      // The same answer the TUI's detail pane gives: the card is the prompt the
      // worker was handed, so "why did it do that" is usually read from it
      // rather than inferred from the row above.
      var expand =
        '<div class="card-path">' + esc(cardPath) + "</div>" +
        '<pre class="card-text">' + esc(s.card_text || "card not read") + "</pre>";
      return { cls: row.groupStart ? "group-start" : "", expand: expand,
               key: stageKey(row.repo, s.id), cells: [
        row.repo,
        { html: '<span class="caret">\u25b8</span> ' + esc(s.id) },
        { html: '<span class="status ' + esc(s.status) + " " + esc(s.phase || "") + '">' + esc(s.phase || s.status) + "</span>" },
        shortIdentity(s.worker),
        shortIdentity(s.verifier),
        { html: fmtInt(spend.worker) + mark, cls: "num" },
        { html: fmtInt(spend.verifier) + mark, cls: "num" },
        { html: fmtInt(spend.total) + mark, cls: "num" },
        s.started_at || "",
        s.completed_at || ""
      ] };
    });
    renderPagedTable("stages-table-wrap",
      ["Repo", "Stage", "Status", "Worker", "Verifier",
       "Worker tok", "Verifier tok", "Total tok", "Queued", "Completed"],
      cells, "stages", null);
  }

  // --- charts --------------------------------------------------------------

  function chartCommon() {
    return {
      maintainAspectRatio: false,
      responsive: true,
      plugins: { legend: { labels: { color: "#e6edf3" } } },
      scales: {
        x: { ticks: { color: "#8b949e" }, grid: { color: "#30363d" } },
        y: { ticks: { color: "#8b949e" }, grid: { color: "#30363d" }, beginAtZero: true }
      }
    };
  }

  // Re-rendering on a filter change would stack a second Chart on the same
  // canvas, so each one replaces its predecessor by id.
  function draw(id, config) {
    if (charts[id]) charts[id].destroy();
    charts[id] = new Chart(document.getElementById(id).getContext("2d"), config);
  }

  // Every token chart is drawn from stage rows so all four obey the range
  // control. The repo cards still carry the budget-window counter, which has no
  // timestamp on it and so cannot be sliced by time at all.
  function drawReposChart(repos, stages) {
    var totals = Object.create(null);
    repos.forEach(function (r) { totals[r.name] = 0; });
    stages.forEach(function (row) {
      totals[row.repo] = (totals[row.repo] || 0) + row.spend.total;
    });
    var names = repos.map(function (r) { return r.name; });
    draw("chart-repos", {
      type: "bar",
      data: {
        labels: names,
        datasets: [{
          label: "stage tokens (" + rangeLabel() + ")",
          data: names.map(function (n) { return totals[n] || 0; }),
          backgroundColor: "#58a6ff"
        }]
      },
      options: chartCommon()
    });
  }

  function drawStagesChart(stages) {
    // Biggest first, and nothing that spent nothing. Plotting every stage in
    // run order gave a chart whose x-axis was mostly zero-height bars and
    // unreadable labels; the question this chart answers is which stages cost
    // the most, so it is ordered by that.
    var plotted = stages.filter(function (row) { return row.spend.total > 0; })
      .sort(function (a, b) { return b.spend.total - a.spend.total; });
    var options = chartCommon();
    options.onClick = function (event, elements) {
      if (!elements || !elements.length) return;
      var row = plotted[elements[0].index];
      if (row) openStageCard(row.repo, row.stage.id);
    };
    options.plugins = options.plugins || {};
    options.plugins.tooltip = { callbacks: { afterLabel: function () { return "click to read the card"; } } };
    draw("chart-stages", {
      type: "bar",
      data: {
        labels: plotted.map(function (row) { return row.repo + " / " + row.stage.id; }),
        datasets: [{
          label: "stage tokens (" + rangeLabel() + ")",
          data: plotted.map(function (row) { return row.spend.total; }),
          backgroundColor: "#2ea043"
        }]
      },
      options: options
    });
  }

  // by_model and by_day are fleet rollups the aggregator already flattened, so
  // the filter is reapplied here over the visible repos' own stages.
  function drawModelsChart(stages) {
    var totals = Object.create(null);
    stages.forEach(function (row) {
      var s = row.stage;
      if (s.worker) totals[s.worker] = (totals[s.worker] || 0) + row.spend.worker;
      if (s.verifier) totals[s.verifier] = (totals[s.verifier] || 0) + row.spend.verifier;
    });
    var entries = Object.keys(totals).map(function (k) { return { identity: k, tokens: totals[k] }; })
      .sort(function (a, b) { return b.tokens - a.tokens || (a.identity < b.identity ? -1 : 1); });
    draw("chart-models", {
      type: "bar",
      data: {
        labels: entries.map(function (m) { return shortIdentity(m.identity); }),
        datasets: [{ label: "tokens (" + rangeLabel() + ")", data: entries.map(function (m) { return m.tokens; }), backgroundColor: "#d29922" }]
      },
      options: chartCommon()
    });
  }

  function drawDaysChart(stages) {
    var totals = Object.create(null);
    stages.forEach(function (row) {
      var when = stageWhen(row.stage);
      if (!when || !(row.spend.total > 0)) return;
      var day = when.slice(0, 10);
      totals[day] = (totals[day] || 0) + row.spend.total;
    });
    var days = Object.keys(totals).sort();
    // A line needs two points to be a line. A repo whose activity all falls on
    // one day -- a single run, or a filter narrowed to one repo -- produced a
    // one-point series, which Chart.js draws as an empty grid and a dot the
    // size of a full stop: the panel read as broken rather than as a day with
    // 1.1M tokens in it. One bucket is a bar.
    var single = days.length < 2;
    draw("chart-days", {
      type: single ? "bar" : "line",
      data: {
        labels: days,
        datasets: [{
          label: "tokens per day",
          data: days.map(function (d) { return totals[d]; }),
          borderColor: "#58a6ff",
          backgroundColor: single ? "#58a6ff" : "rgba(88,166,255,0.2)",
          fill: !single,
          tension: 0.2,
          // Sparse series are common once the repo filter narrows things, so
          // the points stay visible rather than hiding in the line.
          pointRadius: 4,
          pointHoverRadius: 6
        }]
      },
      options: chartCommon()
    });
  }

  // --- entry ---------------------------------------------------------------

  function renderAll() {
    var data = state.data;
    var repos = visibleRepos();
    var names = visibleNames();
    var stages = visibleStages();

    document.getElementById("generated-at").textContent =
      "generated " + data.generated_at + " - " + repos.length +
      " of " + (data.repos || []).length + " repo(s)";

    // Both controls are rebuilt from state on every pass. Mutating state
    // without redrawing them left the all/none buttons filtering the data
    // while every checkbox stayed as the reader had last clicked it.
    renderRepoFilter();
    renderRangeFilter();

    renderReposGrid(repos);
    renderAgents(repos);
    renderFailures(data.spend || {}, names);
    renderSpend(data.spend || {}, names);
    renderQuota(repos);
    renderStagesTable(repos);
    drawReposChart(repos, stages);
    drawStagesChart(stages);
    drawModelsChart(stages);
    drawDaysChart(stages);
  }

  function render(data) {
    state.data = data;
    var scoped = data.scope && data.scope !== "fleet";
    document.title = scoped
      ? "autometta - " + data.scope
      : "autometta cost dashboard";
    document.getElementById("page-title").textContent = scoped
      ? "autometta - " + data.scope
      : "autometta cost dashboard";
    if (data.drain && data.drain.active) {
      document.getElementById("drain-banner").textContent =
        "DRAIN cap " + fmtInt(data.drain.cap) + ", expires " + data.drain.expires_at;
    }
    renderAll();
  }

  // ---------------------------------------------------------------- polling
  //
  // Two transports, because the page is opened both ways. Served over http
  // (autometta dashboard --serve) data.json is fetched directly. Opened as a
  // file:// URL, fetch is blocked by the opaque file origin, so the data
  // arrives the only way that origin allows: a <script> tag. index.html loads
  // data.js at first paint; a poll re-injects it with a cache-busting query so
  // the browser re-reads it from disk rather than serving the parsed copy.
  //
  // Either way the page only re-renders when the aggregator has actually
  // rewritten the file, keyed on generated_at. A poll that finds the same
  // stamp costs one read and nothing else, which is what makes a 5s interval
  // reasonable against a file the tick rewrites every few minutes.

  var POLL_MS = 5000;
  var isFile = window.location.protocol === "file:";

  function loadViaFetch() {
    return fetch("data.json", { cache: "no-store" }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    });
  }

  function loadViaScript() {
    return new Promise(function (resolve, reject) {
      var el = document.createElement("script");
      el.src = "data.js?t=" + Date.now();
      el.onload = function () {
        el.parentNode.removeChild(el);
        if (window.AUTOMETTA_DATA) resolve(window.AUTOMETTA_DATA);
        else reject(new Error("data.js defined no window.AUTOMETTA_DATA"));
      };
      el.onerror = function () {
        el.parentNode.removeChild(el);
        reject(new Error("could not read data.js"));
      };
      document.head.appendChild(el);
    });
  }

  function loadData(allowEmbedded) {
    if (isFile) {
      // No fetch on a file:// origin, and no http fallback to try.
      return loadViaScript();
    }
    return loadViaFetch().catch(function (err) {
      // The snapshot index.html embedded at page load is a first-paint
      // courtesy, not a standing fallback. Returning it on every failed poll
      // resolved the promise, so the poll took its success path, reset the
      // failure counter, found generated_at unchanged and reported
      // "live - unchanged" -- forever, against a server that had died. A dead
      // server read exactly like an idle run, which is the one thing this
      // status line exists to tell apart. Observed 2026-09-01: a page sat on
      // an 08:39Z snapshot until 11:10 still calling itself live.
      if (allowEmbedded && window.AUTOMETTA_DATA) return window.AUTOMETTA_DATA;
      throw err;
    });
  }

  // The freshness line sits beside the generated-at stamp. It says when this
  // page last saw new data, which is not the same question as when the
  // aggregator last ran: a dashboard nobody is regenerating goes stale in
  // silence otherwise, which is exactly how a snapshot gets misread as live.
  // Naming the transport is not decoration. On a file:// origin the poll
  // depends on the browser honouring a cache-busting query on a file URL; if
  // it serves the parsed copy instead, generated_at never moves and the page
  // reads "unchanged" forever, which is indistinguishable from an idle run.
  // Saying which transport is in play is what lets a reader tell those apart.
  function transportNote() {
    return isFile ? " (file://, serve for a reliable poll)" : "";
  }

  function setLiveStatus(text, cls) {
    var el = document.getElementById("live-status");
    if (!el) return;
    el.textContent = text;
    el.className = "live-status" + (cls ? " " + cls : "");
  }

  function applyData(data) {
    var stamp = data && data.generated_at;
    if (stamp && stamp === state.lastGeneratedAt) return false;
    state.lastGeneratedAt = stamp || null;
    render(data);
    return true;
  }

  function poll() {
    loadData(false)
      .then(function (data) {
        state.pollFailures = 0;
        var fresh = applyData(data);
        setLiveStatus(
          "live" + transportNote() + " - " +
          (fresh ? "updated " : "unchanged at ") +
          new Date().toLocaleTimeString(),
          "ok");
      })
      .catch(function (err) {
        state.pollFailures += 1;
        // One missed read is a half-written file the aggregator is mid-way
        // through replacing; the mv is atomic but the read can still lose the
        // race on some filesystems. Only say something once it persists.
        if (state.pollFailures >= 3) {
          // Name the age, not just the error. "Cannot reach the server" says
          // the poll failed; the age says how far what is on screen has
          // drifted from the run, which is the number a reader acts on.
          var shown = state.lastGeneratedAt
            ? " - showing data generated " + state.lastGeneratedAt
            : "";
          setLiveStatus("NOT LIVE" + transportNote() + " - " + err.message + shown, "warn");
        }
      });
  }

  // index.html already loaded data.js, so the first paint on a file:// origin
  // uses what is in hand rather than re-reading it.
  var first = isFile && window.AUTOMETTA_DATA
    ? Promise.resolve(window.AUTOMETTA_DATA)
    : loadData(true);

  first
    .then(function (data) {
      applyData(data);
      setLiveStatus(
        "live" + transportNote() + " - polling every " + (POLL_MS / 1000) + "s", "ok");
      setInterval(poll, POLL_MS);
    })
    .catch(function (err) {
      document.body.insertAdjacentHTML(
        "beforeend",
        '<pre style="color:#f85149;padding:2rem">Failed to load data: ' + esc(err.message) + "</pre>"
      );
    });
})();
