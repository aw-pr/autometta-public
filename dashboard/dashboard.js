// dashboard.js — vanilla JS renderer for ~/.phat-controller/dashboard/.
// Fetches data.json (same-directory) and draws four Chart.js charts.

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
      div.className = "repo-card" + (r.halted ? " halted" : "");
      var pct = r.token_cap_total > 0 ? Math.round((r.tokens_spent / r.token_cap_total) * 100) : 0;
      div.innerHTML =
        '<div class="name">' + esc(r.name) + "</div>" +
        '<div class="path">' + esc(r.repo_path) + "</div>" +
        '<div class="row"><span>tokens spent</span><span>' + fmtInt(r.tokens_spent) + "</span></div>" +
        '<div class="row"><span>cap</span><span>' + fmtInt(r.token_cap_total) + " (" + pct + "%)</span></div>" +
        '<div class="row"><span>stages</span><span>' + r.stages.length + "</span></div>" +
        (r.halted ? '<div class="row"><span>halted</span><span>' + esc(r.halt_reason || "") + "</span></div>" : "");
      grid.appendChild(div);
    });
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
      "generated " + data.generated_at + " — " + data.repos.length + " repo(s)";
    renderReposGrid(data.repos);
    renderStagesTable(data.repos);
    drawReposChart(data.repos);
    drawStagesChart(data.repos);
    drawModelsChart(data.by_model || []);
    drawDaysChart(data.by_day || []);
  }

  fetch("data.json", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(render)
    .catch(function (err) {
      document.body.insertAdjacentHTML(
        "beforeend",
        '<pre style="color:#f85149;padding:2rem">Failed to load data.json: ' + esc(err.message) + "</pre>"
      );
    });
})();
