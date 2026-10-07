#!/usr/bin/env python3
"""Replay checks over curated generated GUI evidence; no network or app launch."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence-root', type=Path, default=Path(__file__).resolve().parent)
ROOT = parser.parse_args().evidence_root.resolve(strict=True)
EXPECTED_BINARY = '19588b1d3652f622b3be5d8a73dc4c339b2ae95e81d63529cc3331738fdda586'
checks = []


def read(path):
    return json.loads((ROOT / path).read_text())


def check(name, value):
    if not value:
        raise AssertionError(name)
    checks.append(name)


def checkpoint(group, name):
    return read(f'{group}/checkpoints/{name}.json')


def request(group, number):
    return read(f'{group}/requests/request-{number:04d}.json')


def users(snapshot):
    return [row for row in snapshot['messages'] if row['role'] == 'user']


manifest = read('exact-build-manifest.json')
check('exact immutable binary attribution', manifest['binary_sha256'] == EXPECTED_BINARY)
check('exact source build attribution', manifest['source_id'] == 'a890af0a7797197ee5eee4a538098eabbed2a492+project-skills-candidate2-fresh')
check('source manifest identities are unique and hashed', len({row['path'] for row in manifest['source_files']}) == len(manifest['source_files']) and all(len(row['sha256']) == 64 for row in manifest['source_files']))
for item in read('FILES.json')['files']:
    path = ROOT / item['path']
    check('file hash ' + item['path'], hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'])
for image in read('screenshots.json'):
    check('screenshot attribution ' + image['path'], image['binary_sha256'] == EXPECTED_BINARY)
    check('original screenshot bytes ' + image['path'], hashlib.sha256((ROOT / image['path']).read_bytes()).hexdigest() == image['sha256'])

a = checkpoint('skills', '15-queued-alpha-v1')
b = checkpoint('skills', '17-alpha-v1-delivered-after-v2-source')
c = checkpoint('skills', '19-queued-alpha-v2-before-policy')
d = checkpoint('skills', '19-policy-paused')
z = checkpoint('skills', '22-empty-held-save')
u = checkpoint('skills', '24-beta-active-before-stop')
v = checkpoint('skills', '25-retried-deleted-beta')
check('accepted skill-only frozen Alpha V1', len(a['pending']) == 1 and a['pending'][0]['text'] == '' and 'SKILL_ALPHA_BODY_V1' in a['pending'][0]['frozen_skills'][0]['body'])
check('source-body mutation left metadata hash unchanged', a['pending'][0]['frozen_skills'][0]['metadataHash'] == c['pending'][0]['frozen_skills'][0]['metadataHash'])
check('source-body mutation changed content hash', a['pending'][0]['frozen_skills'][0]['contentHash'] != c['pending'][0]['frozen_skills'][0]['contentHash'])
check('queued delivery uses V1 only', 'SKILL_ALPHA_BODY_V1' in json.dumps(request('skills', 2)) and 'SKILL_ALPHA_BODY_V2' not in json.dumps(request('skills', 2)))
check('body-edit delivery drained queue', b['state'] == 'idle' and not b['pending'])
check('policy revocation paused same retained input', d['state'] == 'error' and d['queue_paused'] and d['pending'] == c['pending'])
check('empty queued edit preserves held input', z['edit'] is None and z['pending'] == d['pending'])
check('retry preserves original user rows without duplication', users(u) == users(v) and len(users(v)) == 4)
check('retry provider inputs byte-exact structurally', request('skills', 4)['input'] == request('skills', 5)['input'])
check('queue lifecycle final idle', v['state'] == 'idle' and not v['pending'] and v['active'] is None and v['retry'] is None)

a = checkpoint('compaction', '30-alpha-steering-accepted')
b = checkpoint('compaction', '31-before-compact')
c = checkpoint('compaction', '32-compacted')
d = checkpoint('compaction', '33-after-compaction-continuation')
carriers = users(b)
ids = [row['id'] for row in carriers]
check('Alpha accepted then promoted to steering', len(a['pending']) == 1 and a['pending'][0]['lane'] == 'steering')
check('original task root shared by both selected inputs', len(carriers) == 2 and all(row['task_root_id'] == ids[0] for row in carriers))
check('carrier order Beta then Alpha', carriers[0]['user_content']['skills'][0]['path'].endswith('/b-review/SKILL.md') and carriers[1]['user_content']['skills'][0]['path'].endswith('/a-review/SKILL.md'))
check('genuine ls output retained', any(row['role'] == 'toolResult' and '.agents/' in row['text'] for row in b['messages']))
check('large response generated', any(len(row['text']) == 36062 for row in b['messages']))
check('one completed compaction attempt', c['compaction']['phase'] == 'completed' and c['compaction']['http_attempts'] == 1)
summary = next(row for row in c['messages'] if row.get('compaction'))['compaction']
check('both exact original carriers protected in order', summary['kept_ids'] == ids and summary['protected_ids'] == ids)
check('token estimate reduction', summary['before_estimated_tokens'] == 9869 and summary['after_estimated_tokens'] == 965)
check('history skill rows unchanged by compaction', carriers == users(c))
q = request('compaction', 4)
texts = [block['text'] for item in q['input'] if item.get('role') == 'user' for block in item.get('content', []) if block.get('type') == 'input_text']
expected = [row['user_content']['blocks'][0]['text'] for row in carriers]
check('real continuation has exact carriers once in order', len(texts) == 4 and texts[1:3] == expected and all(texts.count(value) == 1 for value in expected))
check('summary precedes carriers and fresh plain input follows', texts[0].startswith('The conversation history before this point was compacted') and texts[-1] == 'continue')
check('large old output absent from continuation projection', 'Generated continuation evidence;' not in json.dumps(q))
check('compaction final idle', d['state'] == 'idle' and not d['pending'] and d['active'] is None)

for name, count in [('before-invoke', 0), ('after-invoke-before-reload', 1), ('after-reload', 1)]:
    rows = [json.loads(line) for line in (ROOT / 'mcp' / (name + '.jsonl')).read_text().splitlines()]
    check('MCP tools/call count ' + name, sum(row.get('kind') == 'mcp' and row.get('method') == 'tools/call' for row in rows) == count)
check('MCP Reload dispatched no request', (ROOT / 'mcp/after-invoke-before-reload.jsonl').read_bytes() == (ROOT / 'mcp/after-reload.jsonl').read_bytes())
latest = read('mcp/retained-mcp-latest-result.json')
check('MCP exact success durably retained', latest['tool'] == 'echo' and latest['result']['isError'] is False and latest['result']['content'][0]['text'] == 'MCP loopback fixture result: one invocation completed.')
check('MCP unknown pending empty', read('mcp/retained-mcp-outcome.json')['pending'] == {})
print(json.dumps({'passed': len(checks), 'binary_sha256': EXPECTED_BINARY, 'checks': checks}, indent=2))
