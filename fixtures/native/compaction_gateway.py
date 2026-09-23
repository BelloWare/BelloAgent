"""Request-dependent Responses fixture. No upstream network or real credentials.

Generation routes compacted history through a deliberately smaller capacity:
the serialized replay input must be <=1,500 bytes. This is an independent
gateway acceptance contract, not the application's estimate.
"""
import base64
import http.server
import json
import pathlib
import sys
import threading

root = pathlib.Path(sys.argv[1])
lock = threading.Lock()


class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        status = 200
        try:
            body = json.loads(raw)
            assert self.path == '/v1/responses'
            assert self.headers['Authorization'] == 'Bearer synthetic-compaction-key'
            sid = self.headers['x-session-id']
            assert body['model'] == 'fixture-model'
            assert body['metadata']['session_id'] == sid
            assert body['stream'] is True and body['store'] is False
            pending, results, texts = {}, [], []
            for item in body['input']:
                if item['type'] == 'function_call':
                    assert item['call_id'] not in pending
                    pending[item['call_id']] = item
                elif item['type'] == 'function_call_output':
                    assert item['call_id'] in pending
                    pending.pop(item['call_id'])
                    results.append(item['output'])
                elif item['type'] == 'message':
                    assert item['role'] in ('user', 'assistant')
                    texts.extend(part['text'] for part in item['content'] if part['type'] in ('input_text', 'output_text'))
            assert not pending, 'orphan call/result in replay'
            joined = '\n'.join(texts)
            summary = not body.get('tools')
            incomplete = False
            if summary:
                # Pi's summary request: its system prompt, one message of
                # <conversation> text, and pi's summarization prompt last.
                assert len(body['input']) == 1 and len(texts) == 1
                assert body['instructions'].startswith('You are a context summarization assistant.')
                prompt = texts[0]
                assert prompt.startswith('<conversation>\n') and '\n</conversation>\n\n' in prompt
                assert 0 < body['max_output_tokens'] <= (6400 if sid.startswith('compaction-budget') else 512)
                if sid.startswith('compaction-budget'):
                    assert body['reasoning']['effort'] == 'high'
                    assert body['max_output_tokens'] == 6400
                    # Pi's estimate of the request, characters over four, leaves the cap's room.
                    assert (len(prompt) + len(body['instructions'])) / 4 + body['max_output_tokens'] < 16000
                    incomplete = sid == 'compaction-budget-exhausted'
                    text = 'Observed evidence retained. Continue the original objective.'
                elif '<previous-summary>' in prompt:
                    assert 'The messages above are NEW conversation messages' in prompt
                    assert '[Tool result]: READ_STAGE_COMPLETE part 3' in prompt
                    text = 'COUNTER_APPENDED_ONCE READ_STAGE_COMPLETE PART_3_READ. Do not rerun the mutation.'
                else:
                    assert '[Assistant tool calls]: write(' in prompt and 'read(part=1)' in prompt
                    assert 'READ_STAGE_COMPLETE' in prompt and 'COUNTER_APPENDED_ONCE' in prompt
                    assert '[history_read: history:' in prompt
                    text = 'COUNTER_APPENDED_ONCE READ_STAGE_COMPLETE. Do not rerun the mutation.'
                output = message(text)
            elif sid == 'compaction-sibling':
                assert joined == 'sibling independent'
                output = message('Sibling unaffected')
            else:
                assert 'ORIGINAL GOLDEN OBJECTIVE' in joined
                assert {t['name'] for t in body['tools']} == {'write', 'read', 'history_read'}
                if any(t.startswith('Conversation summary') for t in texts):
                    if len(json.dumps(body['input'], ensure_ascii=False, separators=(',', ':')).encode()) > 1500:
                        status = 400
                        output = None
                    elif 'PART_3_READ' in joined:
                        assert 'COUNTER_APPENDED_ONCE' in joined and 'READ_STAGE_COMPLETE' in joined
                        output = message('Golden complete without repeated effects')
                    else:
                        output = [call('read-c', 'read', {'part': 3})]
                elif any('COUNTER_APPENDED_ONCE' in r for r in results):
                    assert len(results) == 1, 'oversized raw results were blindly dispatched'
                    output = [call('read-a', 'read', {'part': 1}), call('read-b', 'read', {'part': 2})]
                else:
                    assert not results
                    output = [call('mutate', 'write', {'path': 'counter.txt', 'content': 'once\n'})]
            if status == 400:
                payload = {'error': {'type': 'invalid_request_error', 'code': 'context_length_exceeded', 'message': 'Routed input contract exceeds 1500 UTF-8 bytes'}}
            else:
                payload = {'id': 'resp-' + sid, 'object': 'response', 'model': body['model'], 'router_model_name': 'fixture-resolved', 'status': 'completed', 'output': output,
                           'usage': {'input_tokens': 200, 'input_tokens_details': {'cached_tokens': 80}, 'output_tokens': 480 if summary else 30, 'output_tokens_details': {'reasoning_tokens': 0}}}
                if incomplete:
                    payload.update(status='incomplete', incomplete_details={'reason': 'max_output_tokens'}, output=[{'type': 'reasoning', 'summary': []}])
                    payload['usage']['output_tokens'] = body['max_output_tokens']
                    payload['usage']['output_tokens_details']['reasoning_tokens'] = body['max_output_tokens']
        except Exception as error:
            status = 422
            payload = {'error': {'message': 'Fixture contract: ' + str(error)}}
        streaming = self.headers.get('x-session-id', '').startswith('compaction-budget') and status == 200
        if streaming:
            terminal = 'response.incomplete' if payload['status'] == 'incomplete' else 'response.completed'
            response = ('event: ' + terminal + '\ndata: ' + json.dumps({'type': terminal, 'response': payload}, separators=(',', ':')) + '\n\n').encode()
        else:
            response = json.dumps(payload, separators=(',', ':')).encode()
        with lock:
            with (root / 'records.jsonl').open('a') as file:
                file.write(json.dumps({'session': self.headers.get('x-session-id'), 'status': status, 'request': base64.b64encode(raw).decode(), 'response': base64.b64encode(response).decode()}) + '\n')
        self.send_response(status)
        self.send_header('Content-Type', 'text/event-stream' if streaming else 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('x-litellm-response-cost', '0.0001')
        self.end_headers()
        self.wfile.write(response)


def message(text):
    return [{'type': 'message', 'id': 'msg-result', 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': text}]}]


def call(identity, name, arguments):
    return {'type': 'function_call', 'id': 'item-' + identity, 'call_id': identity, 'name': name, 'arguments': json.dumps(arguments)}


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_port}))
(root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
