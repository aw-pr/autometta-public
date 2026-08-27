// dashboard.js: vanilla JS renderer for ~/.autometta/dashboard/.
// Reads the aggregator's data seam and draws the fleet and cost views.

(function () {
  "use strict";

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
        rows.push([r.name, "live", a.stage_id, a.role, a.identity || a.family, "-", elapsed]);
      });
      (r.queue || []).forEach(function (q) {
        rows.push([r.name, "next", q.stage_id, "queued", q.worker, q.verifier, "-"]);
      });
    });
    renderSimpleTable("agents-table-wrap",
      ["Repo", "Kind", "Stage", "Role", "Agent / worker", "Verifier", "Elapsed / budget"], rows);
  }

  function renderFailures(spend) {
    var failures = spend.failures || [];
    var rows = failures.map(function (f) {
      return [f.repo, f.stage_id, f.role, f.result, fmtInt(f.tokens_lost), f.ts];
    });
    rows.push(["TOTAL LOST", "-", "-", "non-pass",
      fmtInt(failures.reduce(function (n, f) { return n + Number(f.tokens_lost || 0); }, 0)), "7d"]);
    renderSimpleTable("failures-table-wrap",
      ["Repo", "Stage", "Role", "Result", "Tokens lost", "When"], rows);
  }

  function renderSpend(spend) {
    var rows = (spend.by_repo_role || []).map(function (r) {
      return [r.repo, r.role, fmtInt(r.input_tokens), fmtInt(r.cached_input_tokens),
        fmtInt(r.output_tokens), fmtInt(r.productive_tokens), fmtInt(r.lost_tokens),
        "$" + Number(r.cost_usd_est || 0).toFixed(2)];
    });
    renderSimpleTable("spend-table-wrap",
      ["Repo", "Role", "Input", "Cached", "Output", "Pass", "Lost", "Cost"], rows);
    document.getElementById("spend-total").textContent =
      "today " + fmtInt(spend.tokens_total || 0) + " tokens / $" +
      Number(spend.cost_usd_est || 0).toFixed(2);
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
    renderSimpleTable("quota-table-wrap",
      ["Repo", "Family", "Window", "Used", "Resets", "Source / reason"], rows);
  }

  function renderSimpleTable(id, headers, rows) {
    var wrap = document.getElementById(id);
    if (!rows.length) {
      wrap.innerHTML = '<p style="color:var(--muted)">(none)</p>';
      return;
    }
    var html = '<table class="stages"><thead><tr>' + headers.map(function (h) {
      return "<th>" + esc(h) + "</th>";
    }).join("") + "</tr></thead><tbody>";
    rows.forEach(function (row) {
      html += "<tr>" + row.map(function (cell) { return "<td>" + esc(cell) + "</td>"; }).join("") + "</tr>";
    });
    wrap.innerHTML = html + "</tbody></table>";
  }

  function renderStagesTable(repos) {
    var wrap = document.getElementById("stages-table-wrap");
    var rows = [];
    repos.forEach(function (r) {
      r.stages.forEach(function (s) {
        rows.push({ repo: r.name, stage: s });
      });
    });
    if (rows.length === 0) {
      wrap.innerHTML = '<p style="color:var(--muted)">No stages recorded yet.</p>';
      return;
    }
    var html =
      '<table class="stages"><thead><tr>' +
      "<th>Repo</th><th>Stage</th><th>Status</th>" +
      "<th>Worker</th><th>Verifier</th>" +
      '<th class="num">Worker tok</th><th class="num">Verifier tok</th><th class="num">Total tok</th>' +
      "<th>Completed</th></tr></thead><tbody>";
    rows.forEach(function (row) {
      var s = row.stage;
      html +=
        "<tr>" +
        "<td>" + esc(row.repo) + "</td>" +
        "<td>" + esc(s.id) + "</td>" +
        '<td><span class="status ' + esc(s.status) + '">' + esc(s.status) + "</span></td>" +
        "<td>" + esc(shortIdentity(s.worker)) + "</td>" +
        "<td>" + esc(shortIdentity(s.verifier)) + "</td>" +
        '<td class="num">' + fmtInt(s.worker_tokens) + "</td>" +
        '<td class="num">' + fmtInt(s.verifier_tokens) + "</td>" +
        '<td class="num">' + fmtInt(s.tokens) + "</td>" +
        "<td>" + esc(s.completed_at || "") + "</td>" +
        "</tr>";
    });
    html += "</tbody></table>";
    wrap.innerHTML = html;
  }

  function chartCommon(ctx) {
    return {
      maintainAspectRatio: false,
      responsive: true,
      plugins: {
        legend: { labels: { color: "#e6edf3" } }
      },
      scales: {
        x: { ticks: { color: "#8b949e" }, grid: { color: "#30363d" } },
        y: { ticks: { color: "#8b949e" }, grid: { color: "#30363d" }, beginAtZero: true }
      }
    };
  }

  function drawReposChart(repos) {
    var ctx = document.getElementById("chart-repos").getContext("2d");
    new Chart(ctx, {
      type: "bar",
      data: {
        labels: repos.map(function (r) { return r.name; }),
        datasets: [{
          label: "tokens spent",
          data: repos.map(function (r) { return r.tokens_spent; }),
          backgroundColor: "#58a6ff"
        }]
      },
      options: chartCommon()
    });
  }

  function drawStagesChart(repos) {
    var labels = [];
    var data = [];
    repos.forEach(function (r) {
      r.stages.forEach(function (s) {
        labels.push(r.name + " / " + s.id);
        data.push(s.tokens || 0);
      });
    });
    var ctx = document.getElementById("chart-stages").getContext("2d");
    new Chart(ctx, {
      type: "bar",
      data: {
        labels: labels,
        datasets: [{ label: "stage tokens", data: data, backgroundColor: "#2ea043" }]
      },
      options: chartCommon()
    });
  }

  function drawModelsChart(by_model) {
    var ctx = document.getElementById("chart-models").getContext("2d");
    new Chart(ctx, {
      type: "bar",
      data: {
        labels: by_model.map(function (m) { return shortIdentity(m.identity); }),
        datasets: [{
          label: "tokens",
          data: by_model.map(function (m) { return m.tokens; }),
          backgroundColor: "#d29922"
        }]
      },
      options: chartCommon()
    });
  }

  function drawDaysChart(by_day) {
    var ctx = document.getElementById("chart-days").getContext("2d");
    new Chart(ctx, {
      type: "line",
      data: {
        labels: by_day.map(function (d) { return d.date; }),
        datasets: [{
          label: "tokens per day",
          data: by_day.map(function (d) { return d.tokens; }),
          borderColor: "#58a6ff",
          backgroundColor: "rgba(88,166,255,0.2)",
          fill: true,
          tension: 0.2
        }]
      },
      options: chartCommon()
    });
  }

  function render(data) {
    document.getElementById("generated-at").textContent =
      "generated " + data.generated_at + " - " + data.repos.length + " repo(s)";
    if (data.drain && data.drain.active) {
      document.getElementById("drain-banner").textContent =
        "DRAIN cap " + fmtInt(data.drain.cap) + ", expires " + data.drain.expires_at;
    }
    renderReposGrid(data.repos);
    renderAgents(data.repos);
    renderFailures(data.spend || {});
    renderSpend(data.spend || {});
    renderQuota(data.repos);
    renderStagesTable(data.repos);
    drawReposChart(data.repos);
    drawStagesChart(data.repos);
    drawModelsChart(data.by_model || []);
    drawDaysChart(data.by_day || []);
  }

  var load = window.location.protocol === "file:" && window.AUTOMETTA_DATA
    ? Promise.resolve(window.AUTOMETTA_DATA)
    : fetch("data.json", { cache: "no-store" })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .catch(function (err) {
        if (window.AUTOMETTA_DATA) return window.AUTOMETTA_DATA;
        throw err;
      });

  load
    .then(render)
    .catch(function (err) {
      document.body.insertAdjacentHTML(
        "beforeend",
        '<pre style="color:#f85149;padding:2rem">Failed to load data.json: ' + esc(err.message) + "</pre>"
      );
    });
})();
