#!/usr/bin/env python3
"""Actual helper, generated journals and loopback only. No provider credentials.

PI_BUILD_ROOT must be this stream's private build root. Build the helper there,
then pass --binary and an unused --label. Every received HTTP body is retained;
measurements are byte/4 estimates, never claims about a provider's cache hits.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import threading
import time
import traceback

from native_host_client import HostPeer


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def projection(body):
    # Length-independent item framing: appending a new input must not replace
    # the old JSON array's closing bracket. Include full tools and full items,
    # including roles, IDs, schemas, opaque reasoning and image data.
    return b'\n'.join([encode({'tools': body.get('tools', []),
                             'instructions': body.get('instructions')})] +
                      [encode(item) for item in body['input']]) + b'\n'


def lcp(a, b):
    return next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))


def difference(a, b, path='$'):
    if type(a) != type(b):
        return path
    if isinstance(a, dict):
        for key in sorted(a.keys() | b.keys()):
            if key not in a or key not in b:
                return path + '.' + key
            if a[key] != b[key]:
                return difference(a[key], b[key], path + '.' + key)
    elif isinstance(a, list):
        for i, (x, y) in enumerate(zip(a, b)):
            if x != y:
                return difference(x, y, f'{path}[{i}]')
        if len(a) != len(b):
            return f'{path}[{min(len(a), len(b))}] (append)' if len(b) > len(a) else path + ' (removed)'
    elif a != b:
        return path
    return None


def window(data, offset):
    return data[max(0, offset-50):offset+100].decode(errors='replace')


def events(body):
    result = []
    for item in body['input']:
        for block in item.get('content', []) if isinstance(item.get('content'), list) else []:
            try:
                value = json.loads(block.get('text', ''))
                if isinstance(value, dict) and value.get('kind') == 'agent_events':
                    result.extend(value['events'])
            except (ValueError, TypeError):
                pass
    return result


def measure(requests, destination):
    previous, rows, breaks = {}, [], []
    for request in requests:
        body, raw, conversation = request['body'], request['raw'], request['conversation']
        prompt = projection(body)
        old = previous.get(conversation)
        raw_prefix = prompt_prefix = 0
        cause, prompt_path, raw_path = 'cold conversation', None, None
        settings_changes = []
        if old:
            raw_prefix, prompt_prefix = lcp(old['raw'], raw), lcp(projection(old['body']), prompt)
            old_body = old['body']
            prompt_path = difference(old_body.get('tools'), body.get('tools'), '$.tools')
            if not prompt_path:
                prompt_path = difference(old_body['input'], body['input'], '$.input')
            raw_path = difference(old_body, body)
            settings_changes = [key for key in sorted(old_body.keys() | body.keys())
                                if key != 'input' and key != 'tools' and old_body.get(key) != body.get(key)]
            append_only = (body.get('tools') == old_body.get('tools') and
                           body['input'][:len(old_body['input'])] == old_body['input'])
            cause = 'append tail' if append_only else prompt_path
            if append_only and body['input'] == old_body['input']:
                cause = 'identical replay after relaunch'
            if not append_only:
                breaks.append(f"{conversation} #{request['number']}: {prompt_path}")
            for key in ('prompt_cache_key', 'metadata', 'model'):
                assert body.get(key) == old_body.get(key), f'{conversation}: changed {key}'
        row = dict(conversation=conversation, request=request['number'], total_tokens_est=(len(prompt)+3)//4,
                   stable_tokens_est=prompt_prefix//4, reusable_percent=round(100*prompt_prefix/len(prompt), 2),
                   raw_bytes=len(raw), raw_lcp=raw_prefix, prompt_bytes=len(prompt), prompt_lcp=prompt_prefix,
                   old_prompt_bytes=len(projection(old['body'])) if old else 0,
                   cause=cause, first_prompt_difference=prompt_path, first_raw_difference=raw_path,
                   settings_changes=settings_changes,
                   raw_before=window(old['raw'], raw_prefix) if old else '', raw_after=window(raw, raw_prefix),
                   prompt_before=window(projection(old['body']), prompt_prefix) if old else '',
                   prompt_after=window(prompt, prompt_prefix))
        rows.append(row)
        previous[conversation] = request
    (destination/'measurements.json').write_text(json.dumps(rows, indent=2) + '\n')
    table = ['| Request | Conversation | Total est. | Stable est. | Reusable | Raw LCP bytes | Cause / settings changes |',
             '|---:|---|---:|---:|---:|---:|---|']
    for row in rows:
        settings = '; ' + ', '.join(row['settings_changes']) if row['settings_changes'] else ''
        table.append(f"| {row['request']} | {row['conversation']} | {row['total_tokens_est']} | {row['stable_tokens_est']} | {row['reusable_percent']}% | {row['raw_lcp']} | {row['cause']}{settings} |")
    (destination/'measurements.md').write_text('\n'.join(table) + '\n')
    total = sum(row['prompt_bytes'] for row in rows)
    stable = sum(row['prompt_lcp'] for row in rows)
    old_total = sum(row['old_prompt_bytes'] for row in rows)
    # An effort change can alter provider-hidden instructions even with a
    # perfect visible prefix. Do not count those requests as cache proof.
    compatible = [row for row in rows if not row['settings_changes'] and row['old_prompt_bytes']]
    summary = dict(requests=len(rows), comparisons=len(rows)-len(previous), breaks=breaks,
                   total_tokens_est=(total+3)//4, stable_tokens_est=stable//4,
                   reusable_percent=round(100*stable/total, 2),
                   previous_prefix_retained_percent=round(100*stable/old_total, 2),
                   settings_change_requests=[f"{row['conversation']} #{row['request']}" for row in rows if row['settings_changes']],
                   unchanged_settings_prefix_retained_percent=round(100*sum(row['prompt_lcp'] for row in compatible)/sum(row['old_prompt_bytes'] for row in compatible), 2))
    (destination/'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)
    assert not breaks, 'Non-append prompt changes: ' + '; '.join(breaks)


def run(binary, destination):
    root = destination/'fixture'; root.mkdir()
    (root/'.git').mkdir()  # stop resource discovery at this generated root
    sessions = root/'sessions'; sessions.mkdir()
    # Explicit generated resources; no real prefs, skills or user instructions.
    (root/'codex').mkdir()
    skill = root/'codex/skills/cache-fixture'; skill.mkdir(parents=True)
    (skill/'SKILL.md').write_text('---\nname: cache-fixture\ndescription: Inspect generated cache fixtures.\n---\nOnly inspect generated fixture data.\n')
    isolated_home = root/'home'; isolated_home.mkdir()
    (root/'AGENTS.md').write_text('Generated cache audit policy. Preserve fixture files.\n' * 80)
    requests, errors, counts, roles, peers = [], [], {}, {}, []
    lock = threading.Lock()
    paused_request, release_paused = threading.Event(), threading.Event()
    children = {}

    def wait(predicate, timeout=30):
        deadline = time.monotonic()+timeout
        while not predicate():
            assert not errors, errors
            assert time.monotonic() < deadline, ('Fixture deadline', counts)
            time.sleep(.005)

    def call(name, identity, arguments):
        return dict(type='function_call', id='fc_'+identity, call_id=identity,
                    name=name, arguments=encode(arguments).decode())

    def answer(text, identity):
        return dict(type='message', id='msg_'+identity, role='assistant',
                    content=[dict(type='output_text', text=text)])

    def hold(label):
        return f'while [ ! -f {label} ]; do sleep 0.02; done'

    def terminals():
        data = (sessions/'parent.jsonl').read_bytes()
        return [json.loads(line)['data'] for line in data[:data.rfind(b'\n')+1].splitlines()
                if json.loads(line).get('customType') == 'pi-app.subagent-turn-terminal.v1']

    class Gateway(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            try:
                raw = self.rfile.read(int(self.headers['Content-Length']))
                body = json.loads(raw)
                session = self.headers['x-session-id']
                assert self.path == '/v1/responses'
                with lock:
                    number = counts.get(session, 0)+1; counts[session] = number
                    if session == 'parent':
                        role = 'parent'
                    else:
                        role = next(label for label in 'ABC' if f'TASK-{label}' in json.dumps(body['input']))
                        roles[session] = role; children[role] = session
                    record = dict(body=body, raw=raw, conversation=role, number=number)
                    requests.append(record)
                    (destination/f'{role}-{number:02}.json').write_bytes(raw)
                    (destination/f'{role}-{number:02}.headers.json').write_bytes(encode({
                        key: self.headers.get(key) for key in ('x-session-id', 'x-turn-id', 'session_id', 'x-client-request-id')}))
                assert body['metadata']['session_id'] == session
                assert body['prompt_cache_key'] == session
                assert self.headers['session_id'] == self.headers['x-client-request-id'] == session
                identity = f'{role}-{number}'
                if role == 'parent':
                    if number == 1:
                        output = [call('subagent_start', 'start-'+label, dict(task=f'TASK-{label}: inspect generated fixtures and return FINDING-{label}.',
                                      description='Fixture '+label, mode='background', effort='low')) for label in 'ABC']
                    elif number == 2:
                        wait(lambda: len(children) == 3)
                        output = [call('subagent_send', 'steer-A', dict(child_id=children['A'], message='STEER-A: check the sentinel too', expected_turn=1)),
                                  call('bash', 'release-A', dict(command='touch release-A'))]
                    elif number == 3:
                        output = [call('subagent_wait', 'wait-report', dict(mode='all', timeout_ms=60000))]
                    elif number == 4:
                        assert any(e['text'] == 'REPORT-A: sentinel verified' for e in events(body)), 'Report did not wake wait'
                        output = [call('bash', 'finish-A', dict(command='touch finish-A')),
                                  call('subagent_wait', 'wait-A', dict(mode='one', targets=[dict(child_id=children['A'], turn=1)], timeout_ms=60000))]
                    elif number == 5:
                        assert any(e['kind'] == 'result' and e['child_id'] == children['A'] for e in events(body))
                        output = [call('subagent_send', 'follow-A', dict(child_id=children['A'], message='FOLLOW-A: refine your saved finding', expected_turn=1, effort='default')),
                                  call('bash', 'release-BC', dict(command='touch release-B release-C'))]
                    elif number == 6:
                        wait(lambda: len(terminals()) == 4)
                        output = [call('subagent_wait', 'wait-family', dict(mode='all', timeout_ms=60000))]
                    elif number == 7:
                        assert len([e for e in events(body) if e['kind'] == 'result']) == 4
                        output = [answer('Family findings collected.', identity)]
                    elif 8 <= number <= 12:
                        output = [answer(f'Continued turn {number-7}: the saved findings remain available.', identity)]
                    elif number == 13:
                        paused_request.set()
                        assert release_paused.wait(30)
                        return  # killed helper: no response can enter the journal
                    elif number == 14:
                        output = [call('subagent_send', 'cold-follow-A', dict(child_id=children['A'], message='COLD-FOLLOW-A: verify after relaunch', expected_turn=2, effort='high'))]
                    elif number == 15:
                        wait(lambda: len(terminals()) == 5)
                        output = [call('subagent_wait', 'cold-wait', dict(mode='all', timeout_ms=60000))]
                    elif number == 16:
                        output = [answer('Resumed family complete.', identity)]
                    else:
                        raise AssertionError(('Unexpected parent request', number))
                else:
                    assert not any(t['name'] in ('subagent_start', 'subagent_send') for t in body['tools'])
                    if number == 1:
                        output = [call('bash', 'hold-'+role, dict(command=hold('release-'+role)))]
                    elif role != 'A':
                        assert number == 2
                        output = [answer('FINDING-'+role+': generated fixture checked.', identity)]
                    elif number == 2:
                        assert 'STEER-A: check the sentinel too' in json.dumps(body['input'])
                        wait(lambda: counts.get('parent', 0) >= 3)
                        output = [call('subagent_report', 'report-A', dict(kind='note', message='REPORT-A: sentinel verified'))]
                    elif number == 3:
                        output = [call('bash', 'hold-final-A', dict(command=hold('finish-A')))]
                    elif number in (4, 5, 6):
                        output = [answer(f'FINDING-A-{number}: generated fixture checked.', identity)]
                    else:
                        raise AssertionError(('Unexpected child request', number))
                # Pinned opaque replay is exercised, not just plain text. This
                # is synthetic ciphertext; it has no provider-side meaning.
                output.insert(0, dict(type='reasoning', id='rs_'+identity, summary=[], encrypted_content='fixture-opaque-'+identity))
                response = dict(id='response-'+identity, model='cache-upstream', status='completed', output=output,
                                usage=dict(input_tokens=200, output_tokens=20, total_tokens=220, cost=0))
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                self.wfile.write(b'data: '+encode(dict(type='response.completed', response=response))+b'\n\n')
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            except BaseException:
                errors.append(traceback.format_exc())

    gateway = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
    threading.Thread(target=gateway.serve_forever, daemon=True).start()
    profile = dict(id='fixture', revision='1', providerId='litellm', modelId='fixture-model', api='openai-responses',
                   baseUrl=f'http://127.0.0.1:{gateway.server_port}/v1', contextWindow=100000, maxOutputTokens=4096,
                   reasoning=True, thinkingLevel='high', routing=dict(replayPolicy='pinned', expectedModel='cache-upstream', replayContract='synthetic fixed loopback route'))
    grants = [dict(model=model, reasoning=['low', 'high']) for model in ('z-model', 'fixture-model', 'a-model')]

    def command(peer, method, params=None, session='parent'):
        identity = peer.post(method, params, session)
        while True:
            frame = peer.next_frame(30)
            if frame.get('commandId') == identity:
                assert frame['ok'], frame
                return frame['result']

    def opened(resume=False):
        # Foundation's intended home override isolates implicit ~/.agents
        # discovery too; the codexHome resource option covers only ~/.codex.
        env = dict(os.environ, CFFIXED_USER_HOME=str(isolated_home))
        peer = HostPeer(binary, root, env=env); peers.append(peer)
        peer.epoch = peer.hello(10)['hostEpoch']
        command(peer, 'workspace.open', dict(cwd=str(root), directory=str(sessions), captureProtocol=1,
                resources=dict(codexHome=str(root/'codex'))), None)
        params = dict(profile=profile, apiKey='synthetic-loopback-key', toolMode='editing', subagentModels=grants)
        if resume:
            params['path'] = str(sessions/'parent.jsonl')
        command(peer, 'session.open', params)
        command(peer, 'debug.mode', dict(mode='persist'))
        return peer

    try:
        peer = opened()
        command(peer, 'turn.submit', dict(clientTurnId='initial', text='Start three sub-agents to inspect the generated fixtures.'))
        wait(lambda: command(peer, 'session.status')['state'] == 'idle')
        assert counts['parent'] == 7, counts
        for number in range(5):
            # A refreshed catalog can return the identical grant set in another
            # order. Its order must not rewrite the tools in earlier prefixes.
            command(peer, 'turn.submit', dict(clientTurnId=f'continue-{number}', text=f'Continue fixture check {number+1}.',
                    subagentModels=grants[::-1] if number % 2 == 0 else grants))
            wait(lambda: command(peer, 'session.status')['state'] == 'idle')
        command(peer, 'turn.submit', dict(clientTurnId='pause', text='Verify again, including the saved child after relaunch.', subagentModels=grants))
        wait(paused_request.is_set)
        peer.process.kill(); peer.process.wait(timeout=10); peer.close(); peers.remove(peer)
        release_paused.set()
        before = len(requests)
        peer = opened(resume=True)
        assert len(requests) == before, 'Opening must not dispatch work'
        command(peer, 'run.continue', dict(subagentModels=grants))
        wait(lambda: command(peer, 'session.status')['state'] == 'idle')
        assert counts['parent'] == 16, counts
        assert sorted(counts[s] for s in roles) == [2, 2, 6], counts
        assert not errors, errors
        final = next(r['body'] for r in requests if r['conversation'] == 'parent' and r['number'] == 16)
        delivered = events(final)
        assert len(delivered) == len({e['event_id'] for e in delivered}) == 6, 'Report/results duplicated or lost'
        outputs = [item['output'] for item in final['input'] if item.get('type') == 'function_call_output']
        assert not any('FINDING-' in output or 'REPORT-A:' in output for output in outputs), 'Receipt copied an automatic result/report'
        for output in outputs:
            assert 'TASK-' not in output, 'Status/wait repeated the full task'
        assert any(item.get('type') == 'reasoning' for item in final['input']), 'Pinned replay not exercised'
        peer.send(dict(v=1, kind='shutdown', hostEpoch=peer.epoch)); peer.process.wait(timeout=10)
        assert peer.process.returncode == 0
        peer.close(); peers.remove(peer)
        measure(requests, destination)
    finally:
        release_paused.set()
        for label in ('release-A', 'release-B', 'release-C', 'finish-A'):
            (root/label).touch()
        for peer in peers:
            peer.close()
        gateway.shutdown(); gateway.server_close()
        if errors:
            (destination/'errors.txt').write_text('\n'.join(errors))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--label', required=True)
    args = parser.parse_args()
    assert args.label.replace('-', '').isalnum(), 'Use a simple artifact label'
    build = Path(os.environ['PI_BUILD_ROOT']).resolve()
    binary = args.binary.resolve()
    assert binary.is_relative_to(build), 'Use only your own build root'
    destination = build/('cache-'+args.label)
    destination.mkdir()  # never overwrite earlier evidence
    run(binary, destination)
