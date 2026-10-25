#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=subscription observation and compact role display regressions
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$script_dir" python3 <<'PY'
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
spec = importlib.util.spec_from_file_location('usage', Path(os.environ['SCRIPT_DIR']) / 'lib/subscription-usage.py')
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)
q = u.quota_reader()
now = int(time.time())
def reading(used, at):
    return {'status': 'known', 'fetched_at': q.iso(at), 'windows': [
        {'key':'weekly', 'label':'Weekly', 'utilization':used, 'resets_at':q.iso(now+86400)}]}
a, b = reading(20, now-30), reading(22, now)
assert u.movement(a,b)['windows'][0]['percentage_points'] == 2
assert u.movement(a,b)['attribution'] == 'shared_account'
assert u.movement(a,a)['status'] == 'unavailable'
assert u.movement(None,b)['status'] == 'unavailable'
assert u.movement(b,a)['status'] == 'unavailable'
c = copy.deepcopy(b); c['windows'][0]['resets_at'] = q.iso(now+2*86400)
assert u.movement(a,c)['status'] == 'unavailable'
c = copy.deepcopy(b); c['windows'][0]['utilization'] = 19
assert u.movement(a,c)['status'] == 'unavailable'
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp); quota = root/'quota'; quota.mkdir()
    repo = root/'repo'; repo.mkdir()
    os.environ['AI_QUOTA_DIR'] = str(quota)
    os.environ['AUTOMETTA_CODEX_SESSIONS'] = str(root/'no-sessions')
    for family in ['claude','codex']:
        (quota/f'{family}.json').write_text(json.dumps({**a,'source':'fixture'}))
        reg = {'agent_id':family, 'family':family,'role':'worker','started_at':q.iso(now), 'log_path':str(root/f'{family}.log')}
        u.capture(reg,str(repo))
        assert reg['subscription_start']['status'] == 'known'
        (quota/f'{family}.json').write_text(json.dumps({**b,'source':'fixture'}))
        result = u.finish(str(repo),reg['log_path'],'worker',family,now)
        assert result['status'] == 'observed', result
        assert u.finish(str(repo),reg['log_path'],'worker',family,now+600)['status'] == 'unavailable'
        assert u.finish(str(repo),reg['log_path'],'verifier',family,now)['status'] == 'unavailable'
    # Exercise the actual registration and cost-log wiring, including a reaped registry.
    log = root/'test.log'
    log.write_text('{"usage":{"input_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":900,"output_tokens":20}}\n')
    (quota/'claude.json').write_text(json.dumps({**a,'source':'fixture'}))
    subprocess.run(['bash',str(Path(os.environ['SCRIPT_DIR'])/'register-agent.sh'),str(repo),'123','worker','claude','Claude Sonnet 5.5','stage-cards/test.md',str(log)],check=True,stdout=subprocess.DEVNULL)
    (repo/'state/active-agents/123.json').unlink()
    (quota/'claude.json').write_text(json.dumps({**b,'source':'fixture'}))
    subprocess.run(['bash','-c','source "$1/cost-log.sh"; costlog_append "$2" test worker "Claude Sonnet 5.5" "$3" 30 pass "" "$4"','test',os.environ['SCRIPT_DIR'],str(repo),str(log),str(now)],check=True)
    row = json.loads((repo/'state/cost-log.jsonl').read_text())
    assert row['cache_creation_input_tokens'] == 50, row
    assert row['input_tokens'] == 150 and row['total_tokens'] == 1070
    assert row['subscription_usage']['status'] == 'observed',row
print('PASS subscription snapshots for both families, resets, retries, shared attribution and cache writes')
PY
AUTOMETTA_DASHBOARD_JS="$script_dir/../dashboard/dashboard.js" node <<'JS'
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const context = vm.createContext({window:{location:{protocol:'http:'}}, document:{}});
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS,'utf8');
vm.runInContext(source.slice(0,source.lastIndexOf('  var first =')) + '\nwindow.test = {creditEquivalent, stageRoleCell, stageTokenCells, stageUsageDetails, subscriptionText, roleTokenSplit, stageUsageTotal, roleEffortLabel};})();',context);
const api = context.window.test;
const effortCard = {card_text:'- **Worker effort:** high\n- **Verifier effort:** medium'};
assert.match(api.roleEffortLabel(effortCard,'worker'),/\(high\)/);
assert.match(api.roleEffortLabel(effortCard,'verifier'),/\(medium\)/);
assert.match(api.roleEffortLabel({card_text:'# Legacy card'},'worker'),/\(default\)/);
assert.match(api.roleEffortLabel({},'worker'),/\(\?\)/);
assert.match(api.roleEffortLabel({card_text:'could not read card'},'worker'),/\(\?\)/);

const row = {stage_id:'test',role:'worker',identity:'GPT-6.1 Sol',auth_route:'subscription',input_tokens:1000000,cached_input_tokens:10000000,output_tokens:1000000,total_tokens:12000000};
assert.equal(api.creditEquivalent(row),325);
assert.equal(api.creditEquivalent({...row,identity:'unknown'}),null);
assert.equal(api.creditEquivalent({...row,auth_route:'api'}),null);
assert.equal(api.creditEquivalent({...row,output_tokens:null}),null);
const repo = {spend:{role_usage:[row],model_rates:[{identity:row.identity,role:'worker',median_uncached_tokens:2500000}]}};
const stage = {id:'test',worker:row.identity,worker_tokens:1000,tokens:1000,estimate:{worker:5000000}};
let cells = api.stageTokenCells(repo,stage);
const html = api.stageRoleCell(repo,stage,'worker',cells[0]).html;
assert.match(html,/>2M</);
assert.match(html,/~2.5M/);
assert.match(html,/\+10M cache/);
assert.match(html,/325.0 credits eq/);
assert.match(api.stageUsageDetails(repo,stage),/Subscription impact unavailable/);
assert.doesNotMatch(api.stageUsageDetails(repo,stage),/0 pp/);
assert.equal(api.stageRoleCell(repo,stage,'worker',cells[0]).sort,2000000);
const unknown = {spend:{role_usage:[{...row,input_tokens:null,cached_input_tokens:null,output_tokens:null,total_tokens:null}]}};
cells = api.stageTokenCells(unknown,stage);
assert.equal(cells[0].sort,null);
assert.match(api.stageRoleCell(unknown,stage,'worker',cells[0]).html,/Breakdown unavailable/);
const live = {...repo,agents:[{stage_id:'test',role:'worker',live_total_tokens:5000000,live_uncached_tokens:100000}]};
assert.equal(api.roleTokenSplit(live,stage,'worker').uncached,2100000);
assert.equal(api.roleTokenSplit(live,stage,'worker').cached,14900000);
assert.equal(api.stageUsageTotal(live,stage).sort,2100000);
assert.equal(api.roleTokenSplit({...repo,agents:[{stage_id:'test',role:'worker',live_total_tokens:5000000}]},stage,'worker').uncached,null);
assert.doesNotMatch(api.stageRoleCell({spend:{role_usage:[row]}},stage,'worker',cells[0]).html,/~5M/,
  'a total-token prediction must never appear beside uncached actuals');
console.log('PASS cache-aware credit equivalents, unknown history, compact role rendering and numeric sorting');
JS
