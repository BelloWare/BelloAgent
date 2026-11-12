"""A loopback gateway whose providers refuse each other's reasoning, as a
LiteLLM 1.108.0 gateway relays it: the OpenAI organization refusal over HTTP
400, or the Gemini bridge's `response.failed` inside an HTTP 200 stream.

    python3 reasoning_refusal_gateway.py ROOT MODE     (MODE: http, sse, always, strict)

It writes ROOT/ready.json with its port and logs every request body to
ROOT/requests.jsonl. The helper's ReasoningQuestionTests carry the same script
inline (`gatewayScript`); scripts/tests/test_reasoning_refusal_gateway.py
holds the two to the same text. The app's ReasoningContinueIntegrationTests
run it under the built app's real helper.
"""
import http.server, json, pathlib, sys
root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
ORG = "The encrypted content for item rs_fixture-model_1 could not be verified. Reason: Encrypted content organization_id did not match the target organization."
HELP = "\n\n This error occurs when load balancing Responses API across deployments with different API keys.\n   Encrypted content is tied to the organization that created it and cannot be decrypted by other organizations.\n\n   Solution: Enable 'encrypted_content_affinity' to route follow-up requests to the correct deployment"
count = {'n': 0}
def refusal(body):
    model, made = body['model'], set()
    if mode == 'always' and model != 'fixture-model': return ORG
    if mode == 'strict':
        # The first model's provider takes whatever comes; the other's takes no earlier reasoning at all, its own included.
        return ORG if model != 'fixture-model' and any(entry.get('type') == 'reasoning' for entry in body['input']) else None
    for entry in body['input']:
        kind = entry.get('type')
        if kind == 'reasoning':
            made.add(entry.get('id'))
            if entry.get('encrypted_content') != 'ENC-' + model: return ORG
        # OpenAI: a call that keeps its item id needs the reasoning item it came with.
        if kind == 'function_call' and entry.get('id', '').startswith('fc_') and 'rs_' + entry['id'][3:] not in made:
            return "Item '%s' of type 'function_call' was provided without its required 'reasoning' item: 'rs_%s'." % (entry['id'], entry['id'][3:])
    return None
def text_of(entry):
    content = entry.get('content')
    return content if isinstance(content, str) else ''.join(part.get('text', '') for part in content or [])
class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send(self, status, kind, payload):
        self.send_response(status); self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload); self.wfile.flush()
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        with (root / 'requests.jsonl').open('a') as log: log.write(json.dumps(body) + '\n')
        model, refused = body['model'], refusal(body)
        if refused and mode == 'sse':
            wrapped = "litellm.BadRequestError: Vertex_ai_betaException BadRequestError - b'{\"error\": {\"code\": 400, \"message\": \"Corrupted thought signature.\", \"status\": \"INVALID_ARGUMENT\"}}'"
            failed = {'type': 'response.failed', 'response': {'id': 'resp_f', 'created_at': 1, 'error': {'code': 'invalid_request_error', 'message': wrapped}, 'object': 'response', 'output': [], 'status': 'failed'}, 'sequence_number': 0}
            return self.send(200, 'text/event-stream', b'event: response.failed\ndata: ' + json.dumps(failed).encode() + b'\n\ndata: [DONE]\n\n')
        if refused:
            inner = json.dumps({'error': {'message': refused, 'type': 'invalid_request_error', 'param': None, 'code': 'invalid_encrypted_content'}})
            return self.send(400, 'application/json', json.dumps({'error': {'message': 'litellm.BadRequestError: OpenAIException - ' + inner + HELP, 'type': 'invalid_request_error', 'param': None, 'code': '400'}}).encode())
        count['n'] += 1; n = count['n']
        last = body['input'][-1]
        said = text_of(last) if last.get('role') == 'user' else ''
        tag = '%s_%d' % (model, n)
        reasoning = {'type': 'reasoning', 'id': 'rs_' + tag, 'summary': [], 'encrypted_content': 'ENC-' + model}
        if 'continuation checkpoint' in said:
            output = [{'type': 'message', 'id': 'msg_' + tag, 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'SUMMARY of the earlier work.', 'annotations': []}]}]
        elif 'tool' in said:
            output = [reasoning, {'type': 'function_call', 'id': 'fc_' + tag, 'call_id': 'call_' + tag, 'name': 'first', 'status': 'completed', 'arguments': '{}'}]
        else:
            output = [reasoning, {'type': 'message', 'id': 'msg_' + tag, 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'Answer %d.' % n, 'annotations': []}]}]
        size = len(json.dumps(body['input'])) // 4
        usage = {'input_tokens': size, 'output_tokens': 10, 'total_tokens': size + 10}
        frames = [{'type': 'response.created', 'response': {'id': 'r' + str(n), 'status': 'in_progress', 'output': []}}]
        for index, entry in enumerate(output):
            frames += [{'type': 'response.output_item.added', 'output_index': index, 'item': entry}, {'type': 'response.output_item.done', 'output_index': index, 'item': entry}]
        frames.append({'type': 'response.completed', 'response': {'id': 'r' + str(n), 'status': 'completed', 'model': model, 'output': output, 'usage': usage}})
        self.send(200, 'text/event-stream', b''.join(b'event: ' + f['type'].encode() + b'\ndata: ' + json.dumps(f).encode() + b'\n\n' for f in frames))
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'ready.tmp').write_text(json.dumps({'port': server.server_address[1]})); (root / 'ready.tmp').replace(root / 'ready.json')
server.serve_forever()
