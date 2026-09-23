"""Independent request-aware fixture for native manual-compaction commands."""
import base64
import http.server
import json
import pathlib
import sys
import traceback

root = pathlib.Path(sys.argv[1])


class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        status = 200
        try:
            body = json.loads(raw)
            assert self.path == '/v1/responses'
            assert self.headers['Authorization'] == 'Bearer synthetic-manual-key'
            sid = self.headers['x-session-id']
            assert body['metadata']['session_id'] == sid
            assert body['stream'] is True and body['store'] is False
            summary = not body.get('tools')
            if summary:
                # Pi's cap: min(0.8 × the 16,384-token reserve, the model's output limit).
                expected = ('connection-default', 'low', 4096) if sid == 'default' else ('chosen-' + sid, 'high', 13107)
                assert body['model'] == expected[0], 'Compaction lost selected model: ' + body['model']
                assert body['reasoning']['effort'] == expected[1], 'Compaction lost effort'
                assert body['max_output_tokens'] == expected[2], 'Compaction lost model output ceiling'
                assert body['instructions'].startswith('You are a context summarization assistant.')
                assert len(body['input']) == 1 and body['input'][0]['content'][0]['text'].startswith('<conversation>\n')
                text = 'Preserve the original objective. Verified evidence was retained.'
            else:
                assert body['model'] == 'previous-model'
                assert body['reasoning']['effort'] == 'low'
                text = 'Verified evidence retained for this task. ' * 2000  # past pi's 20,000-token recent tail
            payload = {'id': 'response-' + sid, 'object': 'response', 'status': 'completed', 'model': body['model'],
                       'output': [{'type': 'message', 'id': 'msg-' + sid, 'role': 'assistant', 'status': 'completed',
                                   'content': [{'type': 'output_text', 'text': text}]}],
                       'usage': {'input_tokens': 100, 'output_tokens': 10, 'total_tokens': 110,
                                 'input_tokens_details': {'cached_tokens': 0}, 'output_tokens_details': {'reasoning_tokens': 5}}}
        except Exception as error:
            status = 422
            line = traceback.extract_tb(error.__traceback__)[-1].lineno
            payload = {'error': {'message': f'Fixture contract at line {line}: {error}'}}
        response = json.dumps(payload, separators=(',', ':')).encode()
        with (root / 'records.jsonl').open('a') as file:
            file.write(json.dumps({'status': status, 'session': self.headers.get('x-session-id'),
                                   'request': base64.b64encode(raw).decode(), 'response': base64.b64encode(response).decode()}) + '\n')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('x-litellm-response-cost', '0.000001')
        self.end_headers()
        self.wfile.write(response)


server = http.server.HTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_port}))
(root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
