#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  printf 'usage: %s <repo_root> [--json] [--since <n>]\n' "$(basename "$0")" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

repo_root="$1"
shift
json_out=false
since=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      [[ "$json_out" == false ]] || { usage; exit 2; }
      json_out=true
      shift
      ;;
    --since)
      [[ -z "$since" && $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage; exit 2; }
      since="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'first-attempt-history: %s is not a git repository\n' "$repo_root" >&2
  exit 1
fi

python3 -I - "$repo_root" "$json_out" "$since" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

repo, json_out, since = sys.argv[1:]
record_format = '%H%x1f%ct%x1f%s%x1f%B%x1e'
result = subprocess.run(
    ['git', '-C', repo, 'log', '--all', '--reverse', '--date-order',
     f'--format={record_format}'],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
if result.returncode:
    sys.stderr.write(result.stderr)
    sys.exit(result.returncode)

stage_subject = re.compile(r'^([0-9]+[a-z]?-[a-z0-9-]+): ')
wip_subject = re.compile(r'^wip\(([0-9]+[a-z]?-[a-z0-9-]+)\): attempt ([0-9]+)')
worker_trailer = re.compile(r'^Autometta-Worker:', re.MULTILINE)
landings = {}
wip_attempts = {}
controller_rebriefs = {}

for record in result.stdout.split('\x1e'):
    record = record.lstrip('\n')
    if not record:
        continue
    sha, timestamp, subject, body = record.rstrip('\n').split('\x1f', 3)
    match = stage_subject.match(subject)
    if match:
        stage_id = match.group(1)
        if subject.startswith(f'{stage_id}: phat-controller re-brief'):
            controller_rebriefs[stage_id] = controller_rebriefs.get(stage_id, 0) + 1
        elif worker_trailer.search(body) and stage_id not in landings:
            landings[stage_id] = {'sha': sha, 'timestamp': int(timestamp)}
    match = wip_subject.match(subject)
    if match:
        wip_attempts.setdefault(match.group(1), set()).add(match.group(2))

def card_rebriefs(stage_id):
    for relative in (Path('stage-cards') / f'{stage_id}.md',
                     Path('docs/stages') / f'{stage_id}.md'):
        path = Path(repo) / relative
        if path.is_file():
            return sum(line.startswith('## Re-brief') for line in path.read_text().splitlines())
    return 0

stages = []
for stage_id, landing in landings.items():
    leading_number = int(re.match(r'^[0-9]+', stage_id).group())
    if since and leading_number < int(since):
        continue
    attempts = len(wip_attempts.get(stage_id, set()))
    rebriefs = card_rebriefs(stage_id)
    controller_rebriefs_count = controller_rebriefs.get(stage_id, 0)
    clean = attempts == 0 and rebriefs == 0 and controller_rebriefs_count == 0
    stages.append({
        'stage_id': stage_id,
        'landed_commit': landing['sha'],
        'wip_attempts': attempts,
        'rebriefs': rebriefs,
        'controller_rebriefs': controller_rebriefs_count,
        'first_attempt_clean': clean,
        '_timestamp': landing['timestamp'],
    })

stages.sort(key=lambda stage: stage['_timestamp'])
for stage in stages:
    del stage['_timestamp']

clean = sum(stage['first_attempt_clean'] for stage in stages)
landed = len(stages)
if json_out == 'true':
    print(json.dumps({
        'landed': landed,
        'clean': clean,
        'rate': clean / landed if landed else None,
        'stages': stages,
    }, separators=(',', ':')))
    sys.exit(0)

print('stage_id\tlanded_commit\twip_attempts\trebriefs\tcontroller_rebriefs\tfirst_attempt_clean')
for stage in stages:
    print('\t'.join((
        stage['stage_id'],
        stage['landed_commit'],
        str(stage['wip_attempts']),
        str(stage['rebriefs']),
        str(stage['controller_rebriefs']),
        'yes' if stage['first_attempt_clean'] else 'no',
    )))
rate = 'n/a' if not landed else f'{round(100 * clean / landed):.0f}%'
print(f'first-attempt clean: {clean} of {landed} landed stages ({rate})')
PY
