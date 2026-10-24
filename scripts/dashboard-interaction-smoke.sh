#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=dashboard interaction regressions; no frozen stage card
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOMETTA_DASHBOARD_JS="$script_dir/../dashboard/dashboard.js" node <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const stored = new Map();
const instances = [];
const context = vm.createContext({
  window: { location: { protocol: 'http:' }, localStorage: {
    getItem: key => stored.get(key) || null,
    setItem: (key, value) => stored.set(key, value)
  } },
  document: { getElementById: () => ({ getContext: () => ({}) }) },
  Chart: function (_, config) {
    this.config = config;
    this.data = config.data;
    this.options = config.options;
    this.updates = [];
    this.update = mode => this.updates.push(mode);
    this.destroy = () => { this.destroyed = true; };
    instances.push(this);
  }
});
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS, 'utf8');
vm.runInContext(source.slice(0, source.lastIndexOf('  var first =')) + `
  window.test = { state, charts, draw, chartCommon, stageTokenCells,
    stageRowsByRecency, tableHtml };
  for (var name of ["sortRows", "sortsFor", "changeSort", "clearSort", "setTableHtml"]) {
    window.test[name] = eval("typeof " + name) === "function" ? eval(name) : null;
  }
})();`, context);
const api = context.window.test;
const config = tokens => ({type: 'bar', data: {labels: ['a'], datasets: [{data: [tokens]}]}, options: api.chartCommon()});
api.draw('chart', config(10));
const chart = api.charts.chart;
api.draw('chart', config(20));
assert.equal(api.charts.chart, chart, 'a changed poll must retain the chart instance');
assert.equal(chart.data.datasets[0].data[0], 20);
assert.deepEqual(chart.updates, ['none'], 'live updates must not animate');
api.draw('chart', config(20));
assert.equal(chart.updates.length, 1, 'unchanged charts must not redraw');
assert.equal(chart.options.animation, false);
api.draw('chart', {...config(20), type: 'line'});
assert.equal(chart.destroyed, true, 'a bar/line type change still replaces the chart');

const rows = [['z', 2], ['a', 10], ['a', 2], ['a', null]];
api.changeSort('test', 0, false);
api.changeSort('test', 1, true);
assert.equal(JSON.stringify(api.sortRows(rows, api.sortsFor('test'))),
  JSON.stringify([['a', 2], ['a', 10], ['a', null], ['z', 2]]));
api.changeSort('test', 1, true);
assert.equal(JSON.stringify(api.sortRows(rows, api.sortsFor('test'))),
  JSON.stringify([['a', 10], ['a', 2], ['a', null], ['z', 2]]));
api.changeSort('test', 1, true);
assert.equal(api.sortsFor('test').length, 1, 'third click removes a sort');
api.changeSort('test', 1, false);
assert.equal(api.sortsFor('test').length, 1, 'ordinary click replaces the chain');
delete api.state.sorts.test;
assert.equal(api.sortsFor('test')[0].col, 1, 'sort survives a reload');
stored.set('autometta.sort.bad', '{bad');
assert.equal(api.sortsFor('bad').length, 0, 'bad stored preferences must not break rendering');
api.state.stageOrder = 'repo';
api.clearSort('stages');
assert.equal(api.state.stageOrder, 'recent', 'clear restores newest first');
const recent = api.stageRowsByRecency([
  {name: 'a', stages: [{id: 'old', completed_at: '2026-01-01'}]},
  {name: 'b', stages: [{id: 'new', started_at: '2026-10-24'}]}
]);
assert.equal(recent[0].stage.id, 'new', 'default newest first spans repos');

const numeric = api.stageTokenCells({}, {tokens: 20, worker_tokens: 20, estimate: {worker: 9000000}})[0];
assert.equal(api.sortRows([[numeric], [{html: '100', sort: 100}]], [{col: 0, dir: 'asc'}])[0][0], numeric,
  'sort actual token counts, not predictions');
const markup = api.tableHtml(['Repo', 'Tokens'], [], null, [{col: 1, dir: 'desc'}]);
assert.match(markup, /data-sort-col="0"/);
assert.match(markup, /aria-sort="descending"/);

let writes = 0;
const oldCard = {scrollTop: 240, scrollLeft: 25, closest: () => ({getAttribute: () => 'repo/card'})};
const newCard = {scrollTop: 0, scrollLeft: 0, closest: oldCard.closest};
let card = oldCard;
const wrap = {querySelectorAll: selector => selector === "pre.card-text" ? [card] : [], set innerHTML(_) {writes++; card = newCard;}};
api.setTableHtml(wrap, '<table>changed</table>');
assert.equal(newCard.scrollTop, 240, 'refresh retains card reading position');
assert.equal(newCard.scrollLeft, 25);
assert.equal(api.setTableHtml(wrap, '<table>changed</table>'), false);
assert.equal(writes, 1, 'unchanged table must retain its DOM');
console.log('PASS: dashboard quiet refresh, card scroll, typed multi-sort and newest-first reset');
NODE
