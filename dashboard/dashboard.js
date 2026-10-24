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
    repoSelection: null,
    pageSize: Object.create(null),
    page: Object.create(null),
    rangeDays: null,
    // Which expander rows are open. This has to live in state rather than in
    // the DOM: a poll re-renders every table, and a reader mid-way through a
    // stage card should not have it collapse under them every few seconds.
    expanded: Object.create(null),
    // Per-table column filters, table key -> column index -> text. Held here
    // for the same reason as `expanded`: a poll must not wipe a search.
    filters: Object.create(null),
    sorts: Object.create(null),
    // Row keys in the order the paged table last drew them, after filtering.
    rowOrder: Object.create(null),
    stageOrder: null,
    lastGeneratedAt: null,
    pollFailures: 0
  };
  var charts = Object.create(null);
  var chartSignatures = Object.create(null);

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
  function activityAge(stamp) {
    var at = Date.parse(stamp);
    if (!isFinite(at)) return "";
    var seconds = Math.max(0, Math.floor((Date.now() - at) / 1000));
    if (seconds < 60) return seconds + "s ago";
    if (seconds < 3600) return Math.floor(seconds / 60) + "m ago";
    return Math.floor(seconds / 3600) + "h ago";
  }
  function activityText(activity) {
    if (!activity) return "";
    var parts = ["turn " + Number(activity.turns || 0)];
    if (activity.tool_calls != null) parts.push(Number(activity.tool_calls) + " calls");
    if (activity.last_tool) parts.push(activity.last_tool);
    var age = activityAge(activity.last_at);
    if (age) parts.push(age);
    if (activity.last_detail) parts.push(String(activity.last_detail).split(/\r?\n/, 1)[0]);
    return parts.join(" · ");
  }

  function compactTokens(value) {
    var n = Number(value);
    if (!isFinite(n)) return "-";
    if (Math.abs(n) >= 1000000) {
      return (n / 1000000).toFixed(Math.abs(n) % 1000000 ? 1 : 0).replace(/\.0$/, "") + "M";
    }
    if (Math.abs(n) >= 1000) {
      return (n / 1000).toFixed(Math.abs(n) % 1000 ? 1 : 0).replace(/\.0$/, "") + "k";
    }
    return fmtInt(Math.round(n));
  }

  function burnSparkline(points) {
    if (points.length < 2) return "";
    var first = points[0];
    var last = points[points.length - 1];
    var span = Math.max(1, Number(last.t) - Number(first.t));
    var values = points.map(function (point) { return Number(point.tokens); });
    var low = Math.min.apply(null, values);
    var high = Math.max.apply(null, values);
    var range = Math.max(1, high - low);
    var line = points.map(function (point) {
      var x = 2 + ((Number(point.t) - Number(first.t)) / span) * 92;
      var y = high === low ? 12 : 20 - ((Number(point.tokens) - low) / range) * 16;
      return x.toFixed(1) + "," + y.toFixed(1);
    }).join(" ");
    return '<svg class="burn-spark" viewBox="0 0 96 24" aria-hidden="true" focusable="false">' +
      '<polyline points="' + line + '"></polyline></svg>';
  }

  function burnCell(agent) {
    var usage = agent.live_usage;
    if (usage) {
      var live = "LIVE " + fmtInt(Number(usage.input_tokens || 0) + Number(usage.output_tokens || 0));
      if (!usage.updated_at) live += " (stale)";
      return live;
    }
    if (agent.stage_tokens_status === "waiting") return "waiting";
    if ((agent.stage_tokens_status !== "counted" || agent.stage_tokens == null) &&
        agent.live_total_tokens != null) {
      return '<span class="burn-total">' + compactTokens(agent.live_total_tokens) + " heartbeat</span>";
    }
    if (agent.stage_tokens_status !== "counted" || agent.stage_tokens == null) return "n/a";

    var parts = ['<span class="burn-total">' + compactTokens(agent.stage_tokens) + " transcript</span>"];
    var burn = agent.burn || {};
    var points = (burn.points || []).filter(function (point) {
      return point && isFinite(Number(point.t)) && isFinite(Number(point.tokens));
    }).slice().sort(function (a, b) { return Number(a.t) - Number(b.t); });
    if (points.length) {
      var newest = points[points.length - 1];
      if (points.length > 1) {
        var cutoff = Number(newest.t) - 300;
        var anchor = null;
        for (var i = points.length - 2; i >= 0; i--) {
          if (Number(points[i].t) <= cutoff) {
            anchor = points[i];
            break;
          }
        }
        if (!anchor) anchor = points[0];
        var minutes = (Number(newest.t) - Number(anchor.t)) / 60;
        if (minutes > 0) {
          parts.push('<span class="burn-meta">' +
            compactTokens((Number(newest.tokens) - Number(anchor.tokens)) / minutes) + "/min</span>");
        }
      }
      if (Number(newest.tokens) > 0 && isFinite(Number(newest.cached))) {
        parts.push('<span class="burn-meta">' +
          Math.round(Number(newest.cached) * 100 / Number(newest.tokens)) + "% cached</span>");
      }
      var sparkline = burnSparkline(points);
      if (sparkline) parts.push(sparkline);
    }
    return { html: '<div class="burn-cell">' + parts.join("") + "</div>", cls: "burn" };
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

  // Dispatch history includes failed attempts as well as the landed attempt.
  // Use it consistently for totals, cache shares and cost equivalents; older
  // snapshots without role history fall back to the ledger and legacy sums.
  function stageSpend(repo, stage) {
    var spend = repo.spend || {};
    // A spend query that could not run reports null figures and a state_error,
    // and the cost-log fallback below is empty because there was nothing to
    // fall back through. Coercing those nulls with `|| 0` would restate the
    // failure as a confident zero -- the one thing docs/dashboard.md forbids.
    // Absent is the other case and stays truthful: a repo with no cost log
    // really has spent nothing, carries no state_error, and still counts zero.
    if (spend.state_error) {
      return { worker: null, verifier: null, total: null, logged: false, unavailable: true };
    }
    var worker = Number(stage.worker_tokens || 0);
    var verifier = Number(stage.verifier_tokens || 0);
    var total = Number(stage.tokens || 0);
    var logged = 0;
    var roles = (spend.role_usage || []).filter(function (row) { return row.stage_id === stage.id; });
    if (roles.length) {
      worker = verifier = 0;
      var unknown = {worker: false, verifier: false};
      roles.forEach(function (row) {
        var n = row.total_tokens;
        if (n == null && row.input_tokens != null && row.cached_input_tokens != null && row.output_tokens != null)
          n = row.input_tokens + row.cached_input_tokens + row.output_tokens;
        if (n == null) unknown[row.role] = true;
        else if (row.role === "worker") worker += n;
        else if (row.role === "verifier") verifier += n;
      });
      return {worker: unknown.worker ? null : worker, verifier: unknown.verifier ? null : verifier,
        total: unknown.worker || unknown.verifier ? null : worker + verifier, logged: true};
    }
    if (total || worker || verifier) {
      return { worker: worker, verifier: verifier, total: total || worker + verifier, logged: false };
    }
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

  function liveAgentTokens(agent) {
    if (agent.live_usage) {
      var sdkTokens = Number(agent.live_usage.input_tokens || 0) +
        Number(agent.live_usage.output_tokens || 0);
      return isFinite(sdkTokens) ? sdkTokens : null;
    }
    if (agent.stage_tokens_status === "counted" && agent.stage_tokens != null) {
      var transcriptTokens = Number(agent.stage_tokens);
      return isFinite(transcriptTokens) ? transcriptTokens : null;
    }
    // The fleet page never reads transcripts (too costly across every repo
    // each cycle), so stage_tokens is absent there. The heartbeat's figure is
    // a tick behind at worst, but without it a running stage read as zero.
    if (agent.live_total_tokens != null) {
      var heartbeatTokens = Number(agent.live_total_tokens);
      return isFinite(heartbeatTokens) ? heartbeatTokens : null;
    }
    return null;
  }

  // The predicted figure sits in brackets after the actual one, so a queued
  // stage reads "0 (~1.2M)" and a finished one shows how far it strayed.
  function estimateSuffix(estimate, role) {
    if (!estimate || estimate[role] == null) return "";
    var basis = estimate.basis === "model"
      ? "median of this model's past dispatches in this repo"
      : "no history for this model here: median across models in the role";
    return ' <span class="est" title="predicted: ' + esc(basis) + '">(~' +
      compactTokens(estimate[role]) + ")</span>";
  }

  // One rate per model across the visible repos and both roles, weighted by
  // dispatch count. The heat compares cost per minute rather than tokens per
  // minute: a pricier model can spend fewer tokens and still drain the window
  // faster.
  function modelBurnRates(repos) {
    var acc = Object.create(null);
    repos.forEach(function (repo) {
      ((repo.spend || {}).model_rates || []).forEach(function (row) {
        var a = acc[row.identity] || (acc[row.identity] =
          { identity: row.identity, samples: 0, tokens: 0, tokenWeight: 0, cost: 0, costWeight: 0, medianTokens: 0 });
        var n = Number(row.samples || 0);
        a.samples += n;
        a.medianTokens += Number(row.median_tokens || 0) * n;
        if (row.tokens_per_min != null) { a.tokens += Number(row.tokens_per_min) * n; a.tokenWeight += n; }
        if (row.cost_usd_per_min != null) { a.cost += Number(row.cost_usd_per_min) * n; a.costWeight += n; }
      });
    });
    var rates = Object.keys(acc).map(function (k) {
      var a = acc[k];
      return {
        identity: a.identity, samples: a.samples,
        median_tokens: a.samples ? a.medianTokens / a.samples : null,
        tokens_per_min: a.tokenWeight ? a.tokens / a.tokenWeight : null,
        cost_usd_per_min: a.costWeight ? a.cost / a.costWeight : null
      };
    });
    var costs = rates.map(function (r) { return r.cost_usd_per_min; })
      .filter(function (c) { return c != null; }).sort(function (a, b) { return a - b; });
    var mid = costs.length ? costs[Math.floor(costs.length / 2)] : null;
    var byIdentity = Object.create(null);
    rates.forEach(function (r) {
      r.relative = (mid && r.cost_usd_per_min != null) ? r.cost_usd_per_min / mid : null;
      r.heat = r.relative == null ? "" : r.relative >= 1.5 ? "hot" : r.relative <= 0.67 ? "cool" : "warm";
      byIdentity[r.identity] = r;
    });
    return { list: rates, byIdentity: byIdentity };
  }

  function burnBadge(rate) {
    if (!rate || rate.tokens_per_min == null) return "";
    var title = shortIdentity(rate.identity) + ": " + fmtInt(Math.round(rate.tokens_per_min)) +
      " tokens/min" + (rate.cost_usd_per_min != null
        ? ", ~$" + rate.cost_usd_per_min.toFixed(2) + "/min" : "") +
      (rate.relative != null ? ", " + rate.relative.toFixed(1) + "x the median model's cost burn" : "") +
      " (" + rate.samples + " dispatches)";
    return ' <span class="burn-rate ' + esc(rate.heat) + '" title="' + esc(title) + '">' +
      compactTokens(rate.tokens_per_min) + "/min</span>";
  }

  function identityCell(identity, rates) {
    if (!identity) return shortIdentity(identity);
    return { html: esc(shortIdentity(identity)) + burnBadge(rates.byIdentity[identity]), sort: shortIdentity(identity) };
  }

  function stageTokenCells(repo, stage) {
    var spend = stageSpend(repo, stage);
    var liveByRole = { worker: 0, verifier: 0 };
    var hasLive = { worker: false, verifier: false };
    (repo.agents || []).forEach(function (agent) {
      if (agent.stage_id !== stage.id ||
          !Object.prototype.hasOwnProperty.call(liveByRole, agent.role)) return;
      var tokens = liveAgentTokens(agent);
      if (tokens == null) return;
      liveByRole[agent.role] += tokens;
      hasLive[agent.role] = true;
    });
    var liveTotal = liveByRole.worker + liveByRole.verifier;
    var mark = spend.logged ? "*" : "";
    var estimate = stage.estimate || null;
    var spendTitle = spend.unavailable
      ? ' title="' + esc((repo.spend || {}).state_error) + '"' :
        spend.logged ? ' title="Recorded dispatch totals, including earlier attempts and cached reads"' : "";
    return ["worker", "verifier", "total"].map(function (role) {
      var live = role === "total" ? hasLive.worker || hasLive.verifier : hasLive[role];
      var extra = role === "total" ? liveTotal : liveByRole[role];
      var value = spend[role];
      if (live) value = Number(value || 0) + extra;
      return {
        html: '<span' + (live ? ' class="live"' : "") + spendTitle + ">" +
          fmtInt(value) + mark + "</span>" + estimateSuffix(estimate, role),
        cls: "num", sort: value
      };
    });
  }

  // Standard-speed credit equivalents, not debits or included subscription usage.
  // https://learn.chatgpt.com/docs/pricing#token-rates (2026-10-24)
  function creditEquivalent(row) {
    if (row.auth_route !== "subscription" || row.input_tokens == null ||
        row.cached_input_tokens == null || row.output_tokens == null) return null;
    var model = String(row.model || row.identity || "").toLowerCase().replace(/[ .]/g, "-");
    var rates = [
      [/gpt-6-1-sol(?:-|$)/, [50, 2.5, 250]],
      [/gpt-6-astra(?:-|$)/, [250, 25, 1250]],
      [/gpt-6-sol(?:-|$)/, [50, 5, 250]],
      [/gpt-6-luna(?:-|$)/, [2.5, 0.25, 12.5]],
      [/gpt-5-6-sol(?:-|$)/, [100, 10, 500]],
      [/gpt-5-6-terra(?:-|$)/, [50, 5, 300]],
      [/gpt-5-6-luna(?:-|$)/, [5, 0.5, 30]]
    ];
    var found = rates.filter(function (entry) { return entry[0].test(model); })[0];
    return found ? (row.input_tokens * found[1][0] + row.cached_input_tokens * found[1][1] +
      row.output_tokens * found[1][2]) / 1e6 : null;
  }

  function roleUsage(repo, stage, role) {
    return ((repo.spend || {}).role_usage || []).filter(function (row) {
      return row.stage_id === stage.id && row.role === role;
    });
  }

  function subscriptionText(observation) {
    if (!observation || observation.status !== "observed") return "Subscription impact unavailable";
    return (observation.windows || []).map(function (w) {
      return w.label + " +" + Number(w.percentage_points).toFixed(1) + " pp";
    }).join(", ") + " during run (shared account)";
  }

  function roleTokenSplit(repo, stage, role) {
    var rows = roleUsage(repo, stage, role);
    var uncached = 0, cached = 0, live = false;
    var unknown = !!(repo.spend || {}).state_error;
    rows.forEach(function (r) {
      if (r.input_tokens == null || r.output_tokens == null || r.cached_input_tokens == null) unknown = true;
      else { uncached += r.input_tokens + r.output_tokens; cached += r.cached_input_tokens; }
    });
    var recorded = stageSpend(repo, stage);
    if (!rows.length && (recorded[role] !== 0 ||
        (recorded.total > 0 && !recorded.worker && !recorded.verifier))) unknown = true;
    (repo.agents || []).forEach(function (a) {
      if (a.stage_id !== stage.id || a.role !== role) return;
      live = true;
      // Both heartbeat fields describe the same sample. Mixing a newer
      // transcript total with an older uncached count invents cache reads.
      if (a.live_uncached_tokens == null || a.live_total_tokens == null ||
          a.live_uncached_tokens > a.live_total_tokens) unknown = true;
      else { uncached += a.live_uncached_tokens; cached += a.live_total_tokens - a.live_uncached_tokens; }
    });
    return {uncached: unknown ? null : uncached, cached: unknown ? null : cached, live: live};
  }

  function uncachedPrediction(repo, stage, role) {
    var rates = ((repo.spend || {}).model_rates || []).filter(function (r) {
      return r.role === role && r.median_uncached_tokens != null;
    });
    var match = rates.filter(function (r) { return r.identity === stage[role]; })[0];
    if (match) return match.median_uncached_tokens;
    var values = rates.map(function (r) { return r.median_uncached_tokens; }).sort(function (a, b) { return a - b; });
    return values.length ? values[Math.floor(values.length / 2)] : null;
  }

  function usageTokenMarkup(split, prediction) {
    var actual = split.uncached == null ? "?" : compactTokens(split.uncached);
    var title = "Uncached input plus output; includes cache writes. ";
    title += split.uncached == null ? "Breakdown unavailable." : fmtInt(split.uncached) + " uncached tokens.";
    var html = '<span' + (split.live ? ' class="live"' : '') + ' title="' + esc(title) + '">' + actual + '</span>';
    if (prediction != null) html += '<span class="usage-muted" title="Predicted uncached tokens: historical median per dispatch, not subscription consumption">/ ~' + compactTokens(prediction) + '</span>';
    if (split.cached != null && split.cached > 0) html += '<span class="usage-muted" title="Cached input reads; discounted but not free">+' + compactTokens(split.cached) + ' cache</span>';
    return html;
  }

  function stageUsageTotal(repo, stage) {
    var w = roleTokenSplit(repo, stage, "worker"), v = roleTokenSplit(repo, stage, "verifier");
    var wp = uncachedPrediction(repo, stage, "worker"), vp = uncachedPrediction(repo, stage, "verifier");
    var total = w.uncached == null || v.uncached == null ? null : w.uncached + v.uncached;
    return {html: '<div class="role-usage">' + usageTokenMarkup({uncached: total,
      cached: w.cached == null || v.cached == null ? null : w.cached + v.cached, live: w.live || v.live},
      wp == null || vp == null ? null : wp + vp) + '</div>', sort: total};
  }

  function stageRoleCell(repo, stage, role, tokenCell) {
    var rows = roleUsage(repo, stage, role);
    var complete = rows.length && rows.every(function (r) {
      return r.input_tokens != null && r.cached_input_tokens != null && r.output_tokens != null;
    });
    var lines = ['<strong class="role-model">' + esc(shortIdentity(stage[role])) + '</strong>'];
    var split = roleTokenSplit(repo, stage, role);
    var count = split.uncached, live = split.live;
    lines.push(usageTokenMarkup(split, uncachedPrediction(repo, stage, role)));
    if (complete) {
      var credits = rows.map(creditEquivalent);
      if (credits.every(function (n) { return n != null; })) {
        lines.push('<span class="usage-muted" title="Current published Standard-speed credit equivalent. Not credits charged or weekly subscription consumption.">~' +
          credits.reduce(function (a, b) { return a + b; }, 0).toFixed(1) + ' credits eq.' + (live ? ' (settled)' : '') + '</span>');
      } else if (rows.every(function (r) { return r.cost_usd_est != null; })) {
        lines.push('<span class="usage-muted" title="Estimated API-equivalent cost from the cost log, not a subscription charge; cache-write premiums may be excluded.">~$' +
          rows.reduce(function (n, r) { return n + r.cost_usd_est; }, 0).toFixed(2) + ' API eq.' + (live ? ' (settled)' : '') + '</span>');
      }
    }
    var observed = rows.filter(function (r) { return r.subscription_usage && r.subscription_usage.status === "observed"; });
    if (observed.length) lines.push('<span class="usage-muted" title="See dispatch readings below. Overlapping account movements are never added together.">' +
      esc(subscriptionText(observed[observed.length - 1].subscription_usage)) + '</span>');
    return {html: '<div class="role-usage">' + lines.join('') + '</div>', sort: count, cls: "role-cell"};
  }

  function stageUsageDetails(repo, stage) {
    var rows = ((repo.spend || {}).role_usage || []).filter(function (r) { return r.stage_id === stage.id; });
    if (!rows.length) return '<p class="usage-muted">No settled dispatch breakdown recorded.</p>';
    return '<div class="usage-details"><h3>Settled dispatches</h3><p class="usage-muted">Quota movement includes other chats and jobs on the account. Readings may lag; overlapping movements are not additive. pp = percentage points.</p>' +
      rows.map(function (r) {
        var writes = r.cache_creation_input_tokens;
        var input = writes != null && r.input_tokens != null ? r.input_tokens - writes : r.input_tokens;
        var detail = r.role + ': ' + shortIdentity(r.identity) + ' | ' + (r.ts || '') + ' | ' + (r.auth_route || 'route unknown');
        var tokens = fmtInt(input) + (writes == null ? ' input (writes included)' : ' fresh input; ' + fmtInt(writes) + ' cache writes') +
          '; ' + fmtInt(r.cached_input_tokens) + ' cached reads; ' + fmtInt(r.output_tokens) + ' output';
        var full = r.total_tokens;
        if (full == null && r.input_tokens != null && r.cached_input_tokens != null && r.output_tokens != null)
          full = r.input_tokens + r.cached_input_tokens + r.output_tokens;
        tokens += '; ' + fmtInt(full) + ' processed in total';
        var obs = r.subscription_usage;
        var times = obs && obs.start && obs.end ? ' Readings: ' + (obs.start.fetched_at || '?') + ' to ' + (obs.end.fetched_at || '?') + '.' : '';
        return '<p><strong>' + esc(detail) + '</strong><br>' + esc(tokens) + '<br>' +
          esc(r.auth_route === "subscription" ? subscriptionText(obs) + times : "Subscription impact: not applicable") + '</p>';
      }).join('') + '</div>';
  }

  function runTotals(repo) {
    var run = repo.current_run;
    if (!run) return "";
    var stages = run.stages || [];
    var stageIds = Object.create(null);
    var completed = 0;
    stages.forEach(function (stage) {
      stageIds[stage.id] = true;
      if (stage.status === "completed") completed += 1;
    });
    var tokens = Number(run.tokens_total || 0);
    var live = false;
    (repo.agents || []).forEach(function (agent) {
      if (!stageIds[agent.stage_id]) return;
      var agentTokens = liveAgentTokens(agent);
      if (agentTokens == null) return;
      tokens += agentTokens;
      live = true;
    });
    var cost = Number(run.cost_usd_est || 0);
    if (!isFinite(cost)) cost = 0;
    return '<div class="run-total' + (live ? " live" : "") + '">' +
      '<span class="run-repo">' + esc(repo.name || "repo") + "</span>" +
      '<span class="run-id">' + esc(run.id || "current run") + "</span>" +
      '<span>' + completed + " of " + stages.length + " stages done</span>" +
      '<span class="run-tokens">' + fmtInt(tokens) + " processed tokens</span>" +
      '<span>$' + cost.toFixed(2) + " settled</span></div>";
  }

  function renderRunTotals(repos) {
    var lines = [];
    repos.forEach(function (repo) {
      var line = runTotals(repo);
      if (line) lines.push(line);
    });
    document.getElementById("run-totals").innerHTML = lines.join("");
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

  // --- run scope (per-stage chart) -----------------------------------------
  //
  // The per-stage chart used to plot every stage that had spent anything,
  // ordered by spend. That answers "which stage cost most", which is a
  // question about history. The question an operator asks while a run is
  // going is "how is this run burning, card by card", so the chart is
  // ordered by the queue instead and scoped to a number of recent runs.
  // Queued cards stay in at zero: a run's shape includes what it has not
  // started yet.

  function runsScope() {
    if (state.runsScope != null) return state.runsScope;
    var stored = parseInt(storeGet("autometta.runsScope"), 10);
    state.runsScope = isFinite(stored) && stored >= 1 ? stored : 1;
    return state.runsScope;
  }

  // Runs newest first. A stage with no run_id predates run tracking; those
  // are grouped under one bucket so they can still be reached by widening
  // the slider rather than vanishing.
  function orderedRuns(rows) {
    var byRun = Object.create(null);
    rows.forEach(function (row) {
      var key = row.stage.run_id || "(no run)";
      var when = Date.parse(stageWhen(row.stage) || "") || 0;
      if (!byRun[key]) byRun[key] = { id: key, latest: when, rows: [] };
      if (when > byRun[key].latest) byRun[key].latest = when;
      byRun[key].rows.push(row);
    });
    return Object.keys(byRun).map(function (k) { return byRun[k]; })
      .sort(function (a, b) { return b.latest - a.latest; });
  }

  function renderRunsFilter(rows) {
    var wrap = document.getElementById("runs-filter");
    if (!wrap) return;
    var runs = orderedRuns(rows);
    var max = Math.max(1, runs.length);
    var value = Math.min(runsScope(), max);
    var noun = value === 1 ? "run" : "runs";
    wrap.innerHTML =
      '<span class="filter-label">stages over</span>' +
      '<input type="range" id="runs-scope" min="1" max="' + max + '" value="' + value + '">' +
      '<span class="filter-label" id="runs-scope-label">' + value + " " + noun +
      (value === 1 ? " (this run)" : "") + "</span>";
    var input = document.getElementById("runs-scope");
    if (!input) return;
    input.addEventListener("input", function () {
      var n = parseInt(input.value, 10);
      if (!isFinite(n) || n < 1) return;
      state.runsScope = n;
      storeSet("autometta.runsScope", String(n));
      renderAll();
    });
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

  function initialiseRepoSelection(data) {
    if (data.scope !== "fleet") return;
    if (state.repoSelection == null) {
      var saved;
      try { saved = JSON.parse(storeGet("autometta.selectedRepos")); } catch (e) { saved = null; }
      state.repoSelection = Object.create(null);
      if (Array.isArray(saved)) saved.forEach(function (name) {
        if (typeof name === "string") state.repoSelection[name] = true;
      });
    }
    (data.repos || []).forEach(function (repo) { state.hidden[repo.name] = !state.repoSelection[repo.name]; });
  }

  function saveRepoSelection() {
    state.repoSelection = Object.create(null);
    visibleRepos().forEach(function (repo) { state.repoSelection[repo.name] = true; });
    storeSet("autometta.selectedRepos", JSON.stringify(Object.keys(state.repoSelection)));
  }

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
    if (state.data.scope !== "fleet") {
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
        saveRepoSelection();
        resetPages();
        renderAll();
      });
    });
    wrap.querySelectorAll("button[data-filter-all]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var on = btn.getAttribute("data-filter-all") === "on";
        state.hidden = Object.create(null);
        if (!on) repos.forEach(function (r) { state.hidden[r.name] = true; });
        saveRepoSelection();
        resetPages();
        renderAll();
      });
    });
  }

  function resetPages() {
    state.page = Object.create(null);
  }

  // --- tables --------------------------------------------------------------

  function tableHtml(headers, rows, filters, sorts) {
    var html = '<table class="stages"><thead><tr>' + headers.map(function (h, i) {
      var label = h.label != null ? h.label : h;
      if (!sorts) return "<th>" + esc(label) + "</th>";
      var priority = sorts.findIndex(function (s) { return s.col === i; });
      var sort = sorts[priority];
      var direction = sort && sort.dir === "desc" ? "descending" : "ascending";
      return '<th scope="col"' + (priority >= 0 ? ' aria-sort="' + (priority ? "other" : direction) + '"' : "") +
        '><button type="button" class="sort-header" data-sort-col="' + i +
        '" title="Click to sort; Shift-click to add a column" aria-label="' + esc(label) +
        (sort ? ", " + direction + ", priority " + (priority + 1) : ", sort") + '">' + esc(label) +
        '<span class="sort-indicator" aria-hidden="true">' +
        (sort ? (sort.dir === "desc" ? "▼" : "▲") + (priority + 1) : "↕") + "</span></button></th>";
    }).join("") + "</tr>";
    if (filters) {
      html += '<tr class="filter-row">' + headers.map(function (h, i) {
        return '<th><input type="search" data-filter-col="' + i + '" placeholder="filter" value="' +
          esc(filters[i] || "") + '" /></th>';
      }).join("") + "</tr>";
    }
    html += "</thead><tbody>";
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
      row.onclick = function () {
        if (!target) return;
        target.hidden = !target.hidden;
        row.classList.toggle("open", !target.hidden);
        if (target.hidden) delete state.expanded[stateKey];
        else state.expanded[stateKey] = true;
      };
    });
  }

  function renderSimpleTable(id, headers, rows) {
    var wrap = document.getElementById(id);
    if (!rows.length) {
      setTableHtml(wrap, '<p class="empty">(none)</p>');
      return;
    }
    var sorts = sortsFor(id);
    setTableHtml(wrap, sortControls(headers, sorts) + tableHtml(headers, sortRows(rows, sorts), null, sorts));
    bindSorters(wrap, id, function () { renderSimpleTable(id, headers, rows); });
  }

  // A changing token cell must not send the reader back to line one of a card.
  function setTableHtml(wrap, html) {
    if (wrap.dashboardHtml === html) return false;
    var positions = Object.create(null);
    wrap.querySelectorAll("pre.card-text").forEach(function (card) {
      positions[card.closest("tr").getAttribute("data-expand-for")] = [card.scrollTop, card.scrollLeft];
    });
    wrap.innerHTML = html;
    wrap.dashboardHtml = html;
    // Unhide before restoring offsets: hidden elements have no scroll range.
    bindExpanders(wrap);
    wrap.querySelectorAll("pre.card-text").forEach(function (card) {
      var pos = positions[card.closest("tr").getAttribute("data-expand-for")];
      if (pos) { card.scrollTop = pos[0]; card.scrollLeft = pos[1]; }
    });
    return true;
  }

  function sortsFor(key) {
    if (!state.sorts[key]) {
      var saved;
      try { saved = JSON.parse(storeGet("autometta.sort." + (key === "stages" ? "stages.usage-v2" : key))); } catch (e) { saved = null; }
      var seen = Object.create(null);
      state.sorts[key] = Array.isArray(saved) ? saved.filter(function (s) {
        if (!s || !Number.isInteger(s.col) || s.col < 0 || seen[s.col] ||
            (s.dir !== "asc" && s.dir !== "desc")) return false;
        seen[s.col] = true;
        return true;
      }) : [];
    }
    return state.sorts[key];
  }

  function saveSort(key, sorts) {
    state.sorts[key] = sorts;
    state.page[key] = 0;
    storeSet("autometta.sort." + (key === "stages" ? "stages.usage-v2" : key), JSON.stringify(sorts));
  }

  function changeSort(key, col, additive) {
    var sorts = sortsFor(key).slice();
    var index = sorts.findIndex(function (s) { return s.col === col; });
    var current = sorts[index];
    var next = !current ? { col: col, dir: "asc" }
      : current.dir === "asc" ? { col: col, dir: "desc" } : null;
    if (!additive) sorts = next ? [next] : [];
    else if (index < 0) sorts.push(next);
    else if (next) sorts[index] = next;
    else sorts.splice(index, 1);
    saveSort(key, sorts);
  }

  function clearSort(key) {
    saveSort(key, []);
    if (key === "stages") {
      state.stageOrder = "recent";
      storeSet("autometta.stageOrder", "recent");
    }
  }

  function sortValue(cell) {
    if (cell && typeof cell === "object" && Object.prototype.hasOwnProperty.call(cell, "sort")) {
      return typeof cell.sort === "number" && !isFinite(cell.sort) ? null : cell.sort;
    }
    if (typeof cell === "number" || cell == null) return cell;
    var text = cellText(cell).trim();
    if (!text || text === "-" || text === "unknown" || text === "n/a") return null;
    if (/^\d{4}-\d{2}-\d{2}T/.test(text) && isFinite(Date.parse(text))) return Date.parse(text);
    // Plain numbers, currency, percentages and compact rates sort by magnitude.
    var number = text.replace(/,/g, "").match(/^\$?(-?\d+(?:\.\d+)?)([kM])?(?:%|x|s|\/min)?$/);
    if (number) return Number(number[1]) * (number[2] === "M" ? 1000000 : number[2] === "k" ? 1000 : 1);
    return text;
  }

  function sortRows(rows, sorts) {
    if (!sorts.length) return rows;
    return rows.slice().sort(function (a, b) {
      for (var i = 0; i < sorts.length; i++) {
        var s = sorts[i], av = sortValue(rowCells(a)[s.col]), bv = sortValue(rowCells(b)[s.col]);
        // Unknown figures stay last in either direction.
        if (av == null || bv == null) {
          if ((av == null) !== (bv == null)) return av == null ? 1 : -1;
          continue;
        }
        var cmp = typeof av === "number" && typeof bv === "number" ? av - bv
          : String(av).localeCompare(String(bv), undefined, { numeric: true, sensitivity: "base" });
        if (cmp) return s.dir === "desc" ? -cmp : cmp;
      }
      return 0;
    });
  }

  function sortControls(headers, sorts) {
    if (!sorts.length) return "";
    return '<div class="sort-controls">' +
      '<span class="sort-summary">' + esc(sorts.map(function (s, i) {
        var header = headers[s.col];
        return (i + 1) + ". " + (header && header.label != null ? header.label : header || "") +
          (s.dir === "desc" ? " ▼" : " ▲");
      }).join(" · ")) + '</span><button type="button" data-clear-sort' +
      (!sorts.length ? " disabled" : "") + '>Clear sort</button></div>';
  }

  function bindSorters(wrap, key, redraw) {
    wrap.querySelectorAll("button[data-sort-col]").forEach(function (button) {
      button.onclick = function (event) {
        changeSort(key, Number(button.getAttribute("data-sort-col")), event.shiftKey);
        redraw();
        if (key === "stages") renderStageOrder();
        wrap.querySelector('button[data-sort-col="' + button.getAttribute("data-sort-col") + '"]').focus({ preventScroll: true });
      };
    });
    var clear = wrap.querySelector("button[data-clear-sort]");
    if (clear) clear.onclick = function () {
      clearSort(key);
      if (key === "stages") renderAll();
      else redraw();
    };
  }

  function rowCells(row) {
    return row && !Array.isArray(row) && row.cells ? row.cells : row;
  }

  // What a filter matches against: the text a reader sees, not the markup.
  function cellText(cell) {
    if (cell && typeof cell === "object" && cell.html != null) {
      return String(cell.html).replace(/<[^>]*>/g, "").replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
    }
    return cell == null ? "" : String(cell);
  }

  // Every filled column must contain its text, case-insensitively.
  function filterRows(rows, filters) {
    var active = Object.keys(filters).filter(function (i) { return filters[i]; });
    if (!active.length) return rows;
    return rows.filter(function (row) {
      var cells = rowCells(row);
      return active.every(function (i) {
        return cellText(cells[i]).toLowerCase().indexOf(filters[i].toLowerCase()) >= 0;
      });
    });
  }

  // Paged sibling of renderSimpleTable. `key` names the table for the stored
  // page size; `footer` is a row pinned below every page (a totals line), which
  // must not be paginated away and is never filtered.
  function renderPagedTable(id, headers, allRows, key, footer) {
    var wrap = document.getElementById(id);
    if (!allRows.length) {
      setTableHtml(wrap, '<p class="empty">(none)</p>');
      state.rowOrder[key] = [];
      return;
    }
    var filters = state.filters[key] || (state.filters[key] = Object.create(null));
    var sorts = sortsFor(key);
    var rows = sortRows(filterRows(allRows, filters), sorts);
    state.rowOrder[key] = rows.map(function (row) { return row && row.key; });

    // Redrawing replaces the inputs, so a poll landing mid-keystroke would
    // otherwise drop the caret out of the box being typed in.
    var focused = document.activeElement;
    var focusCol = focused && wrap.contains(focused) ? focused.getAttribute("data-filter-col") : null;
    var caret = focusCol != null ? focused.selectionStart : null;

    var size = pageSizeFor(key);
    var pages = size > 0 ? Math.max(1, Math.ceil(rows.length / size)) : 1;
    if (key === "stages" && size > 0 && state.readingCard) {
      var readingIndex = state.rowOrder[key].indexOf(state.readingCard.key);
      if (readingIndex >= 0) state.page[key] = Math.floor(readingIndex / size);
    }
    var page = Math.min(Math.max(state.page[key] || 0, 0), pages - 1);
    state.page[key] = page;

    var start = size > 0 ? page * size : 0;
    var shown = size > 0 ? rows.slice(start, start + size) : rows;
    if (footer) shown = shown.concat([footer]);

    var range = !rows.length ? "0" : size > 0
      ? fmtInt(start + 1) + "-" + fmtInt(start + shown.length - (footer ? 1 : 0))
      : "all";
    var controls =
      '<div class="pager">' +
      '<label>show <select data-pagesize>' +
      PAGE_SIZE_CHOICES.map(function (n) {
        return '<option value="' + n + '"' + (n === size ? " selected" : "") + ">" +
          (n === 0 ? "all" : n) + "</option>";
      }).join("") +
      "</select> of " + fmtInt(rows.length) +
      (rows.length !== allRows.length ? " matching (" + fmtInt(allRows.length) + " total)" : "") +
      "</label>" +
      '<span class="pager-range">' + range + "</span>" +
      '<button type="button" data-page="prev"' + (page === 0 ? " disabled" : "") + ">prev</button>" +
      '<span class="pager-page">' + (page + 1) + " / " + pages + "</span>" +
      '<button type="button" data-page="next"' + (page >= pages - 1 ? " disabled" : "") + ">next</button>" +
      "</div>";

    var changed = setTableHtml(wrap, sortControls(headers, sorts) + tableHtml(headers, shown, filters, sorts) +
      (rows.length ? "" : '<p class="empty">(no rows match the filters)</p>') + controls);
    bindSorters(wrap, key, function () { renderPagedTable(id, headers, allRows, key, footer); });

    wrap.querySelectorAll("input[data-filter-col]").forEach(function (input) {
      var col = input.getAttribute("data-filter-col");
      if (changed && col === focusCol) {
        input.focus({ preventScroll: true });
        if (caret != null) input.setSelectionRange(caret, caret);
      }
      input.oninput = function () {
        filters[col] = input.value;
        state.page[key] = 0;
        renderPagedTable(id, headers, allRows, key, footer);
      };
    });

    wrap.querySelector("select[data-pagesize]").onchange = function (ev) {
      setPageSize(key, parseInt(ev.target.value, 10) || 0);
      renderPagedTable(id, headers, allRows, key, footer);
    };
    wrap.querySelectorAll("button[data-page]").forEach(function (btn) {
      btn.onclick = function () {
        state.page[key] = page + (btn.getAttribute("data-page") === "next" ? 1 : -1);
        renderPagedTable(id, headers, allRows, key, footer);
      };
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
    var index = (state.rowOrder.stages || []).indexOf(key);
    if (index < 0 && state.filters.stages) {
      // The filters are hiding the stage that was asked for; showing it wins.
      state.filters.stages = Object.create(null);
      renderAll();
      index = (state.rowOrder.stages || []).indexOf(key);
    }
    var size = pageSizeFor("stages");
    if (index >= 0 && size > 0) state.page.stages = Math.floor(index / size);
    renderAll();
    var wrap = document.getElementById("stages-table-wrap");
    var row = wrap.querySelector('tr[data-expand="' + key + '"]');
    var target = wrap.querySelector('tr.expand-row[data-expand-for="' + key + '"]');
    if (!row || !target) return;
    target.hidden = false;
    row.classList.add("open");
    state.expanded[wrap.id + "\u0000" + key] = true;
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
        var burn = burnCell(a);
        var burnHtml = burn && typeof burn === "object" ? burn.html : burn;
        rows.push([r.name, "live", a.stage_id, a.role, a.identity || a.family, "-",
          activityText(a.activity), { html: burnHtml, sort: liveAgentTokens(a) },
          { html: esc(elapsed), sort: a.elapsed_seconds || 0 }]);
      });
      (r.queue || []).forEach(function (q) {
        rows.push([r.name, "next", q.stage_id, "queued", q.worker, q.verifier, "", "-", "-"]);
      });
    });
    renderSimpleTable("agents-table-wrap",
      ["Repo", "Kind", "Stage", "Role", "Agent / worker", "Verifier", "Activity", "Live burn", "Elapsed / budget"], rows);
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
    var summary = document.getElementById("quota-summary");
    if (summary) summary.innerHTML = ["claude", "codex"].map(function (family) {
      var readings = repos.map(function (repo) { return ((repo.quota || {}).families || {})[family]; })
        .filter(function (r) { return r && r.status === "known" && isFinite(Date.parse(r.fetched_at)); })
        .sort(function (a, b) { return Date.parse(b.fetched_at) - Date.parse(a.fetched_at); });
      var reading = readings[0];
      var label = family === "claude" ? "Claude" : "Codex";
      if (!reading) return '<div><strong>' + label + '</strong><p class="usage-muted">Allowance unavailable</p></div>';
      var age = Math.max(0, (Date.now() - Date.parse(reading.fetched_at)) / 1000);
      return '<div><strong>' + label + '</strong>' + (reading.windows || []).map(function (w) {
        var stale = age > 600 || !w.resets_at || Date.parse(w.resets_at) <= Date.now();
        return '<p>' + esc(w.label) + ': <strong>' + Number(w.utilization).toFixed(1) + '% used</strong>' +
          '<span class="usage-muted">' + (stale ? ' (stale; remaining unknown)' :
          ', ' + Math.max(0, 100 - Number(w.utilization)).toFixed(1) + '% remaining') +
          '<br>Resets ' + esc(w.resets_at ? new Date(w.resets_at).toLocaleString() : "unknown") + '</span></p>';
      }).join('') + '<span class="usage-muted" title="' + esc(reading.fetched_at) + '">Latest reading ' +
        Math.floor(age / 60) + 'm ago</span></div>';
    }).join('');
    repos.forEach(function (repo) {
      ["claude", "codex"].forEach(function (family) {
        var reading = ((repo.quota || {}).families || {})[family] || {
          status: "unknown", reason: "no tick reading", windows: []
        };
        if (reading.status !== "known") {
          rows.push([repo.name, family, "unknown", "-", "-", "-", "-", reading.reason || "unknown"]);
          return;
        }
        (reading.windows || []).forEach(function (window) {
          var age = reading.fetched_at ? Math.max(0, (Date.now() - Date.parse(reading.fetched_at)) / 1000) : null;
          var stale = age == null || !isFinite(age) || age > 600 ||
            (window.resets_at && Date.parse(window.resets_at) <= Date.now());
          var freshness = age == null || !isFinite(age) ? "Age unknown" : Math.floor(age / 60) + "m ago";
          rows.push([repo.name, family, window.label,
            {html: esc(Number(window.utilization).toFixed(1) + "%" + (stale ? " (stale)" : "")), sort: Number(window.utilization)},
            stale ? "Unknown" : Math.max(0, 100 - Number(window.utilization)).toFixed(1) + "%",
            window.resets_at || "unknown",
            {html: '<span title="' + esc(reading.fetched_at || "unknown") + '">' + esc(freshness) + '</span>', sort: age},
            reading.source || "unknown"]);
        });
      });
    });
    renderPagedTable("quota-table-wrap",
      ["Observed in", "Family", "Window", "Used", "Remaining", "Resets", "Reading age", "Source / reason"], rows, "quota", null);
  }

  var STAGE_ORDERS = [
    { id: "recent", label: "newest first" },
    { id: "repo", label: "by repo" }
  ];

  function stageOrder() {
    if (state.stageOrder == null) {
      state.stageOrder = storeGet("autometta.stageOrder") === "repo" ? "repo" : "recent";
    }
    return state.stageOrder;
  }

  function renderStageOrder() {
    var wrap = document.getElementById("stage-order");
    if (!wrap) return;
    var current = stageOrder();
    wrap.innerHTML = '<span class="filter-label">order</span>' +
      STAGE_ORDERS.map(function (choice) {
        return '<button type="button" data-order="' + choice.id + '"' +
          (choice.id === current && !sortsFor("stages").length ? ' class="on"' : "") + ">" + choice.label + "</button>";
      }).join("");
    wrap.querySelectorAll("button[data-order]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        state.stageOrder = btn.getAttribute("data-order");
        saveSort("stages", []);
        storeSet("autometta.stageOrder", state.stageOrder);
        state.page.stages = 0;
        renderAll();
      });
    });
  }

  // A stage's last movement: finished if it has, else when it started.
  function stageActivity(stage) {
    return stage.completed_at || stage.started_at || "";
  }

  // Queue position, last first. The queue array is the order the tick will
  // actually dispatch in, so it is the only thing that knows a stage's place
  // in the run; a timestamp cannot, because a stage waiting to run has none.
  // Reading "no timestamp" as "queued" put every never-dispatched terminal
  // stage -- a failed card from May with both dates null -- at the top of the
  // table, where the next stage to run belongs.
  function queuePositions(repo) {
    var queuePos = Object.create(null);
    (repo.queue || []).forEach(function (q, i) { queuePos[q.stage_id] = i + 1; });
    return queuePos;
  }

  // Grouped by repo: within each, still queued (descending position, so the
  // last-queued card leads), then everything with a clock on it (newest
  // first, which lands the in-flight stage directly under the queue on its
  // own merit rather than by pinning it), then the undated remainder --
  // terminal stages that never ran, which belong at the bottom.
  function stageRowsByRepo(repos) {
    var rows = [];
    repos.forEach(function (r) {
      var group = r.stages.map(function (s) { return { repo: r.name, stage: s }; });
      var queuePos = queuePositions(r);
      function band(s) { return queuePos[s.id] ? 0 : (s.started_at || s.completed_at) ? 1 : 2; }
      group.sort(function (a, b) {
        var ab = band(a.stage), bb = band(b.stage);
        if (ab !== bb) return ab - bb;
        if (ab === 0) return queuePos[b.stage.id] - queuePos[a.stage.id];
        if (ab === 2) return 0;
        var at = a.stage.started_at || a.stage.completed_at;
        var bt = b.stage.started_at || b.stage.completed_at;
        return at < bt ? 1 : at > bt ? -1 : 0;
      });
      group.forEach(function (row, i) { row.groupStart = i === 0; rows.push(row); });
    });
    return rows;
  }

  // Fleet-wide, by last movement, so page one is what just happened anywhere.
  // Stages with no clock on them follow: the queued ones in the order they
  // will run, then terminal stages that never ran.
  function stageRowsByRecency(repos) {
    var dated = [], queued = [], undated = [];
    repos.forEach(function (r) {
      var queuePos = queuePositions(r);
      r.stages.forEach(function (s) {
        var row = { repo: r.name, stage: s, queuePos: queuePos[s.id] };
        if (stageActivity(s)) dated.push(row);
        else if (row.queuePos) queued.push(row);
        else undated.push(row);
      });
    });
    dated.sort(function (a, b) {
      var at = stageActivity(a.stage), bt = stageActivity(b.stage);
      return at < bt ? 1 : at > bt ? -1 : 0;
    });
    queued.sort(function (a, b) { return a.queuePos - b.queuePos; });
    return dated.concat(queued, undated);
  }

  function renderStagesTable(repos) {
    renderStageOrder();
    var rows = stageOrder() === "repo" ? stageRowsByRepo(repos) : stageRowsByRecency(repos);
    var byName = Object.create(null);
    repos.forEach(function (r) { byName[r.name] = r; });
    var cells = rows.map(function (row) {
      var s = row.stage;
      var tokenCells = stageTokenCells(byName[row.repo] || {}, s);
      var cardPath = s.card || ("stage-cards/" + s.id + ".md");
      // The same answer the TUI's detail pane gives: the card is the prompt the
      // worker was handed, so "why did it do that" is usually read from it
      // rather than inferred from the row above.
      var expand =
        '<div class="card-path">' + esc(cardPath) + "</div>" +
        stageUsageDetails(byName[row.repo] || {}, s) +
        '<pre class="card-text">' + esc(s.card_text || "card not read") + "</pre>";
      return { cls: row.groupStart ? "group-start" : "", expand: expand,
               key: stageKey(row.repo, s.id), cells: [
        row.repo,
        { html: '<span class="caret">\u25b8</span> ' + esc(s.id), sort: s.id },
        { html: '<span class="status ' + esc(s.status) + " " + esc(s.phase || "") + '">' + esc(s.phase || s.status) + "</span>" },
        stageRoleCell(byName[row.repo] || {}, s, "worker", tokenCells[0]),
        stageRoleCell(byName[row.repo] || {}, s, "verifier", tokenCells[1]),
        stageUsageTotal(byName[row.repo] || {}, s),
        s.started_at || "",
        s.completed_at || ""
      ] };
    });
    renderPagedTable("stages-table-wrap",
      ["Repo", "Stage", "Status", "Worker", "Verifier",
       "Total tokens", "Queued", "Completed"],
      cells, "stages", null);
  }

  // --- charts --------------------------------------------------------------

  function chartCommon() {
    return {
      animation: false,
      maintainAspectRatio: false,
      responsive: true,
      plugins: { legend: { labels: { color: "#e6edf3" } } },
      scales: {
        x: { ticks: { color: "#8b949e" }, grid: { color: "#30363d" } },
        y: { ticks: { color: "#8b949e" }, grid: { color: "#30363d" }, beginAtZero: true }
      }
    };
  }

  function draw(id, config) {
    var chart = charts[id];
    var signature = JSON.stringify(config);
    // Callbacks close over the current stages, even when their plotted values
    // happen to match the previous reading.
    if (chart && chart.config.type === config.type) {
      chart.options.onClick = config.options.onClick;
      if (config.options.plugins.tooltip) chart.options.plugins.tooltip = config.options.plugins.tooltip;
      if (chartSignatures[id] === signature) return;
      chart.data = config.data;
      chart.options = config.options;
      chart.update("none");
    } else {
      if (chart) chart.destroy();
      charts[id] = new Chart(document.getElementById(id).getContext("2d"), config);
    }
    chartSignatures[id] = signature;
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
    // Ordered by the queue, newest card first, and scoped to the most recent
    // runs the slider asks for. Nothing is filtered out for having spent
    // nothing: a queued card is a real part of the run's shape and sits at
    // zero until its worker starts, then climbs on each poll as it burns.
    var runs = orderedRuns(stages);
    var wanted = Math.min(runsScope(), Math.max(1, runs.length));
    var plotted = [];
    runs.slice(0, wanted).forEach(function (run) {
      // rows arrive in queue order; newest card first means reversing it.
      plotted = plotted.concat(run.rows.slice().reverse());
    });

    var options = chartCommon();
    options.onClick = function (event, elements) {
      if (!elements || !elements.length) return;
      var row = plotted[elements[0].index];
      if (row) openStageCard(row.repo, row.stage.id);
    };
    options.plugins = options.plugins || {};
    options.plugins.tooltip = { callbacks: {
      afterLabel: function (item) {
        var row = plotted[item.dataIndex];
        var phase = row && row.stage ? (row.stage.status || "") : "";
        return (phase ? phase + " - " : "") + "click to read the card";
      }
    } };
    draw("chart-stages", {
      type: "bar",
      data: {
        labels: plotted.map(function (row) { return row.repo + " / " + row.stage.id; }),
        datasets: [{
          label: "stage tokens (" + wanted + (wanted === 1 ? " run" : " runs") + ")",
          data: plotted.map(function (row) { return row.spend.total; }),
          // A running card is the one the operator is watching, so it is the
          // one that must be findable at a glance among a hundred green bars.
          backgroundColor: plotted.map(function (row) {
            var s = row.stage.status;
            if (s === "in_progress") return "#d29922";
            if (s === "pending") return "#484f58";
            if (s === "failed" || s === "stalled" || s === "verifier_failed") return "#f85149";
            return "#2ea043";
          })
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

  function renderBurnTable(repos) {
    var rates = modelBurnRates(repos).list.sort(function (a, b) {
      return (b.cost_usd_per_min || 0) - (a.cost_usd_per_min || 0);
    });
    var rows = rates.map(function (r) {
      return [
        { html: esc(shortIdentity(r.identity)) + burnBadge(r), sort: shortIdentity(r.identity) },
        { html: fmtInt(r.samples), cls: "num", sort: r.samples },
        { html: compactTokens(r.median_tokens), cls: "num", sort: r.median_tokens },
        { html: r.tokens_per_min == null ? "-" : compactTokens(r.tokens_per_min), cls: "num", sort: r.tokens_per_min },
        { html: r.cost_usd_per_min == null ? "-" : "$" + r.cost_usd_per_min.toFixed(2), cls: "num", sort: r.cost_usd_per_min },
        { html: r.relative == null ? "-" : r.relative.toFixed(1) + "x", cls: "num", sort: r.relative }
      ];
    });
    renderSimpleTable("burn-table-wrap",
      ["Model", "Dispatches", "Median tok/dispatch", "Tok/min", "Cost/min", "vs median"], rows);
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

  function formatClock(stamp) {
    if (!stamp) return "unknown";
    var date = new Date(stamp);
    return isNaN(date.getTime()) ? String(stamp) : date.toLocaleTimeString();
  }

  function renderAll() {
    var data = state.data;
    var repos = visibleRepos();
    var names = visibleNames();
    var stages = visibleStages();

    document.getElementById("generated-at").textContent =
      "generated " + formatClock(data.generated_at) + " - " + repos.length +
      " of " + (data.repos || []).length + " repo(s)";
    document.getElementById("generated-at").title = data.generated_at
      ? "UTC: " + data.generated_at
      : "Generation time unavailable";

    // Both controls are rebuilt from state on every pass. Mutating state
    // without redrawing them left the all/none buttons filtering the data
    // while every checkbox stayed as the reader had last clicked it.
    renderRepoFilter();
    renderRangeFilter();
    renderRunsFilter(stages);

    renderReposGrid(repos);
    renderAgents(repos);
    renderFailures(data.spend || {}, names);
    renderSpend(data.spend || {}, names);
    renderQuota(data.repos || []);
    renderRunTotals(repos);
    renderStagesTable(repos);
    renderBurnTable(repos);
    drawReposChart(repos, stages);
    drawStagesChart(stages);
    drawModelsChart(stages);
    drawDaysChart(stages);
  }

  function render(data) {
    state.data = data;
    initialiseRepoSelection(data);
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
    var reading = null;
    document.querySelectorAll("tr.expand-row:not([hidden]) pre.card-text").forEach(function (card) {
      var rect = card.getBoundingClientRect();
      if (!reading && rect.bottom > 0 && rect.top < window.innerHeight) {
        reading = { key: card.closest("tr").getAttribute("data-expand-for"), top: rect.top };
      }
    });
    state.readingCard = reading;
    var scrollX = window.scrollX, scrollY = window.scrollY;
    state.lastGeneratedAt = stamp || null;
    render(data);
    if (reading) {
      document.querySelectorAll("tr.expand-row:not([hidden])").forEach(function (row) {
        if (row.getAttribute("data-expand-for") === reading.key) {
          var card = row.querySelector("pre.card-text");
          if (card) scrollY += card.getBoundingClientRect().top - reading.top;
        }
      });
    }
    window.scrollTo({ left: scrollX, top: scrollY, behavior: "instant" });
    state.readingCard = null;
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
