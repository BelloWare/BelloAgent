"""Independent request-aware historical edit fixture; loopback only, no upstream."""
import base64
import http.server
import json
import pathlib
import sys
import threading

root = pathlib.Path(sys.argv[1])
native_tools = '--native-tools' in sys.argv[2:]
(root / 'future-evidence.txt').write_text('FUTURE_TOOL_RESULT\n')
lock = threading.Lock()


def message(text):
    return [{'type': 'message', 'id': 'result', 'role': 'assistant', 'status': 'completed',
             'content': [{'type': 'output_text', 'text': text}]}]


class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        status = 200
        try:
            body = json.loads(raw)
            assert self.path == '/v1/responses'
            assert self.headers['Authorization'] == 'Bearer synthetic-edit-key'
            assert body['model'] == 'fixture-model' and body['stream'] is True
            pending, results, texts = set(), [], []
            for item in body['input']:
                if item['type'] == 'function_call':
                    assert item['call_id'] not in pending
                    pending.add(item['call_id'])
                elif item['type'] == 'function_call_output':
                    assert item['call_id'] in pending
                    pending.remove(item['call_id']); results.append(item['output'])
                elif item['type'] == 'message':
                    texts += [p['text'] for p in item['content'] if p['type'] in ('input_text', 'output_text')]
            assert not pending
            joined = '\n'.join(texts)
            if not body.get('tools'):
                assert body['instructions'].startswith('You are a context summarization assistant.') and texts[0].startswith('<conversation>\n')
                output = message('UNSAFE_SUMMARY ORIGINAL_TARGET FUTURE_SECOND')
            elif 'EDITED_REPLACEMENT' in joined:
                assert 'SAFE_FIRST' in joined and 'SKILL_CURRENT_SELECTION' in joined
                if native_tools:
                    assert len(results) == 1, results
                    assert (root / 'mutation.txt').read_text() == 'MUTATED_ONCE\n'
                else:
                    assert results == ['MUTATED_ONCE'], results
                for forbidden in ('ORIGINAL_TARGET', 'FUTURE_SECOND', 'FUTURE_THIRD', 'FUTURE_TOOL_RESULT', 'future-evidence', 'UNSAFE_SUMMARY', 'future-opaque'):
                    assert forbidden not in json.dumps(body), forbidden
                output = message('EDIT_ACCEPTED_SAFE_PREFIX')
            elif 'FUTURE_THIRD' in joined:
                assert 'future-opaque' in json.dumps(body), 'Fixture must exercise opaque replay before rollback'
                output = message('FUTURE_THIRD_ANSWER')
            elif 'ORIGINAL_TARGET' in joined:
                if len(results) < 2:
                    output = [{'type': 'function_call', 'id': 'item-future', 'call_id': 'call-future',
                               'name': 'read' if native_tools else 'futureEvidence',
                               'arguments': json.dumps({'path': str(root / 'future-evidence.txt')}) if native_tools else '{}'}]
                else:
                    output = [{'type': 'reasoning', 'id': 'future-reasoning', 'summary': [], 'encrypted_content': 'future-opaque'}] + message('FUTURE_SECOND ' * 6000)
            elif results:
                output = message('SAFE_FIRST_ANSWER ' * 500)
            else:
                assert joined == 'SAFE_FIRST'
                output = [{'type': 'function_call', 'id': 'item-first', 'call_id': 'call-first',
                           'name': 'write' if native_tools else 'first',
                           'arguments': json.dumps({'path': str(root / 'mutation.txt'), 'content': 'MUTATED_ONCE\n'}) if native_tools else '{"value":0}'}]
            payload = {'id': 'edit-response', 'object': 'response', 'model': 'fixture-model', 'router_model_name': 'fixture-fixed', 'status': 'completed',
                       'output': output, 'usage': {'input_tokens': 100, 'output_tokens': 20}}
        except Exception as error:
            status = 422
            payload = {'error': {'message': 'Edit fixture contract: ' + str(error)}}
        response = (('event: response.completed\ndata: ' + json.dumps({'type': 'response.completed', 'response': payload}) + '\n\n').encode()
                    if status == 200 else json.dumps(payload).encode())
        with lock:
            with (root / 'records.jsonl').open('a') as file:
                file.write(json.dumps({'session': self.headers.get('x-session-id'), 'status': status,
                                       'request': base64.b64encode(raw).decode(), 'response': base64.b64encode(response).decode()}) + '\n')
        self.send_response(status)
        self.send_header('Content-Type', 'text/event-stream' if status == 200 else 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('x-litellm-response-cost', '0.000001')
        self.end_headers(); self.wfile.write(response)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_port}))
(root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
