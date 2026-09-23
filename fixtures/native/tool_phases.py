"""Request-aware stable-presentation gateway. Synthetic loopback traffic only."""
import base64
import http.server
import json
import pathlib
import sys
import threading
import time

root = pathlib.Path(sys.argv[1])
lock = threading.Lock()


def message(text, ident):
    return {'type': 'message', 'id': ident, 'role': 'assistant', 'status': 'completed',
            'content': [{'type': 'output_text', 'text': text}]}


class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        recorded = bytearray()
        try:
            body = json.loads(raw)
            assert self.path == '/v1/responses'
            assert self.headers['Authorization'] == 'Bearer synthetic-phase-key'
            assert body['stream'] is True and body['model'] == 'phase-fixture'
            assert 'bash' in [tool['name'] for tool in body['tools']]
            pending, results = set(), []
            # Pi's system prompt leads the input; items without a type are messages.
            for item in body['input']:
                kind = item.get('type', 'message')
                if kind == 'function_call':
                    assert item['call_id'] not in pending
                    pending.add(item['call_id'])
                    assert json.loads(item['arguments'])['command'] == 'sleep 0.3; printf phase-tool-ok'
                elif kind == 'function_call_output':
                    assert item['call_id'] in pending
                    pending.remove(item['call_id']); results.append(item['output'])
            assert not pending and all('phase-tool-ok' in result for result in results)
            round_number = len(results)
            assert round_number <= 2
        except Exception as error:
            output = json.dumps({'error': {'message': 'Phase fixture contract: ' + str(error)}}).encode()
            self.send_response(422); self.send_header('Content-Length', str(len(output)))
            self.end_headers(); self.wfile.write(output)
            return
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
        self.send_header('x-litellm-response-cost', '0.000001')
        self.send_header('x-litellm-model-name', 'fixture-fixed'); self.end_headers()

        def emit(value):
            data = ('data: ' + json.dumps(value, ensure_ascii=False) + '\n\n').encode()
            recorded.extend(data)
            # Split UTF-8 and event boundaries independently of semantic events.
            for index in range(0, len(data), 17):
                self.wfile.write(data[index:index + 17]); self.wfile.flush()

        response = {'id': 'phase-' + str(round_number), 'model': 'phase-fixture',
                    'router_model_name': 'fixture-fixed', 'status': 'in_progress', 'output': []}
        try:
            emit({'type': 'response.created', 'response': response})
            time.sleep(.1)
            output = []
            if round_number == 0:
                output.append(message('Stable first prose 中文🙂', 'prose-0'))
                emit({'type': 'response.output_text.delta', 'output_index': 0, 'item_id': output[0]['id'], 'content_index': 0, 'delta': output[0]['content'][0]['text']})
                time.sleep(.1)
            elif round_number == 1:
                emit({'type': 'response.reasoning_summary_text.delta', 'output_index': 0, 'item_id': 'reasoning', 'summary_index': 0, 'delta': 'Checking another tool.'})
                output.append({'type': 'reasoning', 'id': 'reasoning', 'summary': [{'type': 'summary_text', 'text': 'Checking another tool.'}]})
            if round_number < 2:
                args = json.dumps({'command': 'sleep 0.3; printf phase-tool-ok'})
                call = {'type': 'function_call', 'id': 'tool-' + str(round_number), 'call_id': 'reused-call', 'name': 'bash', 'arguments': args}
                index = len(output)
                emit({'type': 'response.output_item.added', 'output_index': index, 'item': dict(call, arguments='')})
                for character in args:
                    emit({'type': 'response.function_call_arguments.delta', 'output_index': index, 'delta': character})
                    time.sleep(.003)
                output.append(call)
            else:
                output.append(message('Task finished after both actual tool results.', 'prose-final'))
                emit({'type': 'response.output_text.delta', 'output_index': 0, 'item_id': output[0]['id'], 'content_index': 0, 'delta': output[0]['content'][0]['text']})
            time.sleep(.1)
            emit({'type': 'response.completed', 'response': dict(response, status='completed', output=output,
                  usage={'input_tokens': 100, 'output_tokens': 40, 'total_tokens': 140,
                         'output_tokens_details': {'reasoning_tokens': 20}, 'input_tokens_details': {'cached_tokens': 10}})})
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with lock:
                with (root / 'records.jsonl').open('a') as file:
                    file.write(json.dumps({'round': round_number, 'request': base64.b64encode(raw).decode(),
                                           'response': base64.b64encode(recorded).decode()}) + '\n')


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_port}))
(root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
