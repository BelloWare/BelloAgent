#!/usr/bin/env python3
"""Black-box Responses-only helper tests using local deterministic HTTP/MCP fixtures.

The shared fixture retains historical Messages response shapes for standalone
oracle tests; production helpers must reject that API before any HTTP request.
Run after swift build: python3 scripts/test-native-host.py /path/to/pi-native-host
"""
import base64
import hashlib
import http.server
import http.client
import importlib.util
import json
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
BINARY = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else ROOT / 'packages/swift-host/.build/debug/pi-native-host').resolve()
CONTRACT_SPEC = importlib.util.spec_from_file_location('litellm_contract', ROOT / 'fixtures/native/litellm_contract.py')
CONTRACT = importlib.util.module_from_spec(CONTRACT_SPEC)
CONTRACT_SPEC.loader.exec_module(CONTRACT)

def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()

class Fixture(http.server.BaseHTTPRequestHandler):
    requests = []
    lock = threading.Lock()
    strict_calls = {}
    strict_cache = set()
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path != '/captures':
            self.send_error(404); return
        with self.lock:
            body = encoded([{'request': base64.b64encode(r['body']).decode(), 'response': base64.b64encode(r['response']).decode(), 'path': r['path']} for r in self.requests])
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        with self.lock:
            record = {'body': data, 'response': b'', 'path': self.path, 'headers': dict(self.headers)}
            self.requests.append(record)
        try:
            body = json.loads(data)
        except (ValueError, TypeError):
            self.reject(record, 'request is not valid JSON'); return
        if self.path == '/mcp':
            method = body['method']
            if 'id' not in body:
                self.send_response(202); self.end_headers(); return
            if method == 'initialize':
                result = {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}}}
            elif method == 'tools/list':
                result = {'tools': [{'name': 'echo', 'description': 'Echo', 'inputSchema': {'type': 'object', 'properties': {'text': {'type': 'string'}}}}]}
            else:
                result = {'content': [{'type': 'text', 'text': body['params']['arguments']['text']}]}
            mode = self.headers.get('X-Fixture-MCP-Mode')
            if mode and method == 'tools/list':
                result['tools'][0]['description'] = 'large schema description ' * 6000
            output = encoded({'jsonrpc': '2.0', 'id': body['id'], 'result': result})
            if mode == 'sse':
                output = b': ' + b'padding ' * 12000 + b'\n\nevent: message\ndata: ' + output + b'\n\n'
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream' if mode == 'sse' else 'application/json'); self.send_header('Mcp-Session-Id', 'fixture-session'); self.end_headers(); self.wfile.write(output); return
        try:
            # limited-tool submits with a 2,048 ceiling; other profiles may carry their catalog ceiling or no limit at all.
            expected_output = 2048 if isinstance(body, dict) and body.get('model') == 'limited-tool' else None
            semantic = CONTRACT.validate_request('POST', self.path, dict(self.headers), body,
                                                 api_key='fixture-secret', max_output_tokens=expected_output)
            record['validated'] = True
        except CONTRACT.FixtureContractError as error:
            self.reject(record, str(error)); return
        model = body['model']
        if model == 'auto-router' or semantic['latest_text'].startswith(('fixture: owner-sample','fixture: owner-billing')):
            try:
                self.owner_sample_response(record, body, semantic)
            except CONTRACT.FixtureContractError as error:
                self.reject(record, str(error))
            return
        if model.startswith('strict-'):
            try:
                self.strict_response(record, body, semantic)
            except CONTRACT.FixtureContractError as error:
                self.reject(record, str(error))
            return
        if model.startswith('observation-'):
            self.observation_response(record, body); return
        if model == 'error':
            output = b'{"error":{"message":"fixture provider error"}}'
            record['response'] = output
            self.send_response(400); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(output); return
        if model == 'slow':
            time.sleep(2)
        text = 'Hello 中文🙂'
        # Pi sends a user message without an item type.
        users = [part.get('text', '') for item in body.get('input', []) if item.get('type', 'message') == 'message' and item.get('role') == 'user' for part in item.get('content', []) if part.get('type') == 'input_text']
        if users and users[-1].startswith('long question'):
            text += ' ' + 'padding ' * 10500  # past pi's 20,000-token recent tail
        if self.path.endswith('/responses'):
            tool = model in ('tool', 'limited-tool', 'billing-tool') and bool(body.get('tools')) and not any(item.get('type') == 'function_call_output' for item in body['input'])
            if tool:
                output = [{'type': 'function_call', 'id': 'fc_1', 'call_id': 'call_1', 'name': 'read', 'arguments': '{"path":"README.md"}'}]
                events = [{'type': 'response.output_item.added', 'output_index': 0, 'item': {**output[0], 'arguments': ''}}, {'type': 'response.function_call_arguments.delta', 'output_index': 0, 'delta': output[0]['arguments']}]
            else:
                output = [{'type': 'reasoning', 'id': 'rs_1', 'summary': [], 'encrypted_content': 'test-opaque'}, {'type': 'message', 'id': 'msg_1', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text, 'annotations': []}], 'status': 'completed'}]
                events = [{'type': 'response.output_text.delta', 'delta': text}]
            events += [{'type': 'response.completed', 'response': {'id': 'resp_1', 'status': 'completed', 'output': output, 'usage': {'input_tokens': 20, 'output_tokens': 8, 'input_tokens_details': {'cached_tokens': 10}}}}]
        else:
            tool = model in ('tool', 'limited-tool') and bool(body.get('tools')) and not any(block.get('type') == 'tool_result' for message in body['messages'] for block in message.get('content', []))
            events = [
                {'type': 'message_start', 'message': {'id': 'msg_1', 'type': 'message', 'role': 'assistant', 'content': [], 'usage': {'input_tokens': 20, 'output_tokens': 1, 'cache_read_input_tokens': 10, 'cache_creation_input_tokens': 0}}},
                {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}},
                {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}},
                {'type': 'content_block_stop', 'index': 0},
                {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 8}},
                {'type': 'message_stop'}]
            if tool:
                events[1] = {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'call_1', 'name': 'read', 'input': {}}}
                events[2] = {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': '{"path":"README.md"}'}}
                events[4]['delta']['stop_reason'] = 'tool_use'
        effective = None
        if model.startswith('route-'):
            history = body.get('input',body.get('messages',[]))
            turns = sum(1 for m in history if m.get('role')=='user')
            effective = 'fixture-a' if turns < 2 else 'fixture-b'
            if model == 'route-echo': effective = model
            if model == 'route-unknown': effective = None
            if model == 'route-conflict': effective = 'fixture-a'
            if self.path.endswith('/responses'):
                if effective: events[-1]['response']['model'] = effective
                if model == 'route-late': events.insert(0,{'type':'response.created','response':{'model':model}})
            elif effective:
                events[0]['message']['model'] = model if model == 'route-late' else effective
                if model == 'route-late': events[-2]['delta']['model'] = effective
        if model.startswith('billing-'):
            usage = events[-1]['response']['usage'] if self.path.endswith('/responses') else events[-2]['usage']
            if model != 'billing-unknown': usage['cost'] = 0 if model == 'billing-free' else -1 if model == 'billing-invalid' else 0.0123
            if model == 'billing-conflict': usage['response_cost'] = 0.0456
        if model in ('json','route-json','billing-json'):
            value = events[-1]['response'] if self.path.endswith('/responses') else {'type':'message', 'role':'assistant', 'content':[{'type':'text','text':text}], 'stop_reason':'end_turn', 'usage':{'input_tokens':20,'output_tokens':8}}
            if effective: value['model'] = effective
            if model == 'billing-json': value['usage']['cost'] = 0.0123
            output = encoded(value); record['response'] = output
            self.send_response(200); self.send_header('Content-Type','application/json')
            if model == 'billing-json': self.send_header('X-Litellm-Response-Cost','0.0123'); self.send_header('X-Fixture-Cache','MISS')
            self.end_headers(); self.wfile.write(output); return
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('X-Request-Id', self.headers['Authorization'] if model == 'credential-echo' else 'fixture-request')
        if model == 'credential-echo':
            self.send_header('X-Fixture-Actual-Model',self.headers['Authorization'].removeprefix('Bearer ')); self.send_header('Set-Cookie','synthetic-cookie-secret')
        if model.startswith('billing-'):
            self.send_header('X-Litellm-Response-Cost','0'); self.send_header('X-Litellm-Version','fixture-v1')
            if model != 'billing-unknown': self.send_header('X-Fixture-Cache','HIT' if model == 'billing-free' else 'MISS')
        if model == 'route-conflict': self.send_header('X-Fixture-Actual-Model','fixture-b')
        if model.startswith('route-'):
            self.send_header('X-Fixture-Deployment','opaque-deployment-123'); self.send_header('X-Fixture-Group',model)
        self.end_headers()
        prefix = b'data: {"type":"ping"}\n\n' if model == 'timing' else b''
        if model == 'terminal-only' and self.path.endswith('/responses'): events = [events[-1]]
        if model == 'refusal' and self.path.endswith('/responses'):
            events[0] = {'type':'response.refusal.delta','delta':'Cannot comply'}
            events[-1]['response']['output'] = [{'type':'message','role':'assistant','content':[{'type':'refusal','refusal':'Cannot comply'}]}]
        if model == 'block-start' and self.path.endswith('/messages'):
            events[1]['content_block']['text'] = text
            events = [e for e in events if e['type'] != 'content_block_delta']
        if model == 'failed-terminal':
            terminal = {'type':'response.failed','response':{'status':'failed','error':{'message':'fixture'}}} if self.path.endswith('/responses') else {'type':'error','error':{'type':'overloaded_error','message':'fixture'}}
            events[-1] = terminal
        output = prefix + b''.join(b'data: ' + encoded(event) + b'\r\n\r\n' for event in events)
        if model == 'incomplete':
            output = b'data: {"type":"response.output_text.delta","delta":"partial"}\n\n'
        record['response'] = output
        try:
            # Repeated short writes exercise arbitrary transport boundaries.
            if prefix:
                self.wfile.write(prefix); self.wfile.flush(); time.sleep(.08)
            for start in range(len(prefix), len(output), 7):
                self.wfile.write(output[start:start+7]); self.wfile.flush()
            if model in ('timing','failed-terminal'): time.sleep(.18)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def reject(self, record, reason):
        record['rejection'] = reason
        record['response'] = encoded({'error': {'type': 'fixture_contract', 'message': reason}})
        self.send_response(422); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(record['response']))); self.end_headers()
        self.wfile.write(record['response'])

    def observation_response(self, record, body):
        """Request-aware three-response tool loop with real interim boundaries."""
        round_number = 1 + sum(i.get('type') == 'function_call_output' for i in body['input'])
        if round_number < 3:
            output = [{'type':'function_call','id':f'item-{round_number}','call_id':f'call-{round_number}',
                       'name':'read','arguments':'{"path":"README.md"}'}]
        else:
            output = [{'type':'message','id':'answer','role':'assistant','status':'completed',
                       'content':[{'type':'output_text','text':'Three requests complete 中文🙂'}]}]
        response = {'id':f'observation-{round_number}','model':body['model'],'router_model_name':'resolved-fixture',
                    'status':'in_progress','output':[]}
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        def emit(kind, sequence, usage=None):
            current = dict(response, usage=usage)
            if kind == 'response.completed': current.update(status='completed', output=output)
            payload = b'data: ' + encoded({'type':kind,'sequence_number':sequence,'response':current}) + b'\n\n'
            record['response'] += payload; self.wfile.write(payload); self.wfile.flush()
        try:
            emit('response.created', 0)
            time.sleep(.12)
            if body['model'] != 'observation-final':
                emit('response.in_progress', 1, {'input_tokens':round_number*1000,'output_tokens':10})
                emit('response.in_progress', 2, {'output_tokens':20})
                emit('response.in_progress', 3, {'output_tokens':20})
                emit('response.in_progress', 2, {'input_tokens':99999})
            time.sleep(.4)
            emit('response.completed', 4, {'input_tokens':round_number*1000,'output_tokens':30,'total_tokens':round_number*1000+30,
                'input_tokens_details':{'cached_tokens':round_number*100},'output_tokens_details':{'reasoning_tokens':20}})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def owner_sample_response(self, record, body, semantic):
        """The owner's shape, selected only after validating the actual request."""
        CONTRACT.require(self.path == '/v1/responses', 'owner sample requires the Responses route')
        CONTRACT.validate_request('POST', self.path, dict(self.headers), body,
                                  api_key='fixture-secret', model='auto-router', max_output_tokens=4096,
                                  custom_headers={'X-Fixture-Contract': 'owner-sample-v1'}, native_items='portable',
                                  expected_tool_names=['read','ls','find','grep','write','edit','bash','mcp'])
        variants = {f'fixture: owner-sample {transport} {cost}': (transport, cost, False)
                    for transport in ('json', 'sse') for cost in ('null', 'paid', 'zero')}
        variants.update({f'fixture: owner-billing {transport}': (transport, 'null', True) for transport in ('json','sse')})
        prompt = semantic['latest_text']
        CONTRACT.require(prompt in variants, 'unrecognized owner sample prompt')
        CONTRACT.require(semantic['user_texts'] == [prompt] and not semantic['calls'] and not semantic['results'],
                         'owner sample requires one original user question without invented tool history')
        transport, cost, billing = variants[prompt]
        response = json.loads((ROOT / 'fixtures/native' / ('responses-owner-billing-sample.json' if billing else 'responses-owner-sample.json')).read_bytes())
        if cost != 'null': response['usage']['cost'] = 0.00123 if cost == 'paid' else 0
        if transport == 'json':
            output = encoded(response)
        else:
            events = [{'type':'response.created','response':{'id':response['id'],'model':'auto-router','status':'in_progress'}},
                      {'type':'response.reasoning_summary_text.delta','delta':'A short calculation.'},
                      {'type':'response.output_text.delta','delta':'9.109996226'},
                      {'type':'response.completed','response':response}]
            output = b''.join(b'event: '+event['type'].encode()+b'\r\ndata: '+encoded(event)+b'\r\n\r\n' for event in events)
        record['scenario'] = ('owner-billing-' if billing else 'owner-sample-')+transport+'-'+cost
        record['response'] = output
        self.send_response(200)
        self.send_header('Content-Type', 'application/json' if transport == 'json' else 'text/event-stream')
        if billing:
            for name,value in json.loads((ROOT / 'fixtures/native/responses-owner-billing-headers.json').read_bytes()).items():
                self.send_header(name,value)
        elif transport == 'sse': self.send_header('X-Litellm-Response-Cost', '0')
        self.end_headers()
        try:
            for offset in range(0, len(output), 7):
                self.wfile.write(output[offset:offset+7]); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            record['cancelled'] = True

    def strict_response(self, record, body, semantic):
        """Select responses only after checking actual instructions and history."""
        responses = self.path.endswith('/responses')
        native_policy = 'pinned' if body['model'] == 'strict-pinned' else 'portable'
        CONTRACT.require(body['model'] in ('strict-portable','strict-pinned'), 'model alias is not part of the strict fixture contract')
        CONTRACT.validate_request('POST', self.path, dict(self.headers), body, api_key='fixture-secret',
                                  model=body['model'], max_output_tokens=4096,
                                  custom_headers={'X-Fixture-Contract': 'strict-v1'}, native_items=native_policy,
                                  expected_tool_names=[] if semantic['is_compaction'] else ['read','ls','find','grep','write','edit','bash','mcp'])
        prompt = semantic['user_texts'][0] if semantic['is_compaction'] else semantic['latest_text']
        history = body['input' if responses else 'messages']
        tool_result = history[-1].get('type') == 'function_call_output' if responses else any(block.get('type') == 'tool_result' for block in history[-1]['content'])
        expected_opaque = {'type': 'reasoning', 'id': 'strict-reasoning', 'summary': [], 'encrypted_content': 'strict-original-opaque'} if responses else {'type': 'thinking', 'thinking': 'Fixture reasoning.', 'signature': 'strict-original-signature'}
        if native_policy == 'pinned' and not semantic['is_compaction'] and (tool_result or len(semantic['user_texts']) > 1):
            CONTRACT.require(expected_opaque in semantic['opaque'], 'pinned continuation did not retain the exact issued opaque item')
        with self.lock:
            for ident, result in semantic['results'].items():
                issued = self.strict_calls.get(ident)
                CONTRACT.require(issued is not None, 'continuation invented a tool ID that the gateway never issued')
                CONTRACT.require(semantic['calls'][ident] == issued['call'], 'continuation changed the issued tool name or arguments')
                CONTRACT.require(result == issued['result'], 'tool result differs from the actual fixture file contents')
        if semantic['is_compaction'] and 'This is the PREFIX of a turn that was too large to keep.' in prompt:
            # Pi's split turn: the long echo's request is summarized as the kept answer's prefix.
            CONTRACT.require('fixture: long echo' in prompt, 'turn-prefix summary lost the split turn\'s request')
            text, kind = 'Fixture turn prefix: the long echo was requested.', 'compaction'
        elif semantic['is_compaction']:
            CONTRACT.require('fixture: read README.md' in prompt and 'fixture file contents' in prompt, 'compaction source lost the completed tool turn')
            # A compaction is one request: a split turn's prefix comes in <turn-prefix>.
            if '<turn-prefix>' in prompt:
                CONTRACT.require('fixture: long echo' in prompt.split('<turn-prefix>', 1)[1], 'the split turn\'s prefix lost its request')
            text, kind = 'Fixture continuation summary: README.md read successfully; fixture file contents; remaining echo preserved.', 'compaction'
        elif tool_result:
            ident = history[-1]['call_id'] if responses else history[-1]['content'][0]['tool_use_id']
            text, kind = 'Validated read: ' + semantic['results'][ident], 'tool-result'
        elif prompt.startswith('fixture: read '):
            path = prompt.removeprefix('fixture: read ')
            CONTRACT.require(path == 'README.md' and 'read' in semantic['tool_names'], 'requested fixture read path or read schema is missing')
            text, kind = '', 'tool-call'
        elif prompt.startswith('fixture: long echo '):
            # Past pi's 20,000-token recent tail, so compaction has earlier work to summarize.
            text, kind = 'Echo from validated request: ' + prompt.removeprefix('fixture: long echo ') + ' ' + 'padding ' * 10500, 'text'
        elif prompt.startswith('fixture: echo '):
            text, kind = 'Echo from validated request: ' + prompt.removeprefix('fixture: echo '), 'text'
        elif prompt.startswith('fixture: cache '):
            text, kind = 'Cache content: ' + prompt.removeprefix('fixture: cache '), 'cache'
        elif prompt == 'fixture: error':
            record['scenario'] = 'provider-error'; record['response'] = b'{"error":{"message":"Validated synthetic gateway overload"}}'
            self.send_response(429); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(record['response']); return
        elif prompt == 'fixture: cancel':
            text, kind = 'Partial reply before deliberate cancellation.', 'cancel'
        else:
            raise CONTRACT.FixtureContractError('strict fixture received an unrecognized prompt')
        record['scenario'] = kind
        record['semantic'] = {'calls': semantic['calls'], 'results': semantic['results'], 'opaque': semantic['opaque']}
        # This deterministic fixture deliberately keys the submitted bytes,
        # including correlation metadata. It makes no deployed cache-policy claim.
        cache_key = hashlib.sha256(record['body']).hexdigest()
        with self.lock:
            cache_hit = kind == 'cache' and cache_key in self.strict_cache
            if kind == 'cache': self.strict_cache.add(cache_key)
        cost = 0 if cache_hit else 0.002 if kind == 'tool-call' else 0.003 if kind == 'tool-result' else 0.001 if kind == 'compaction' else 0.0123
        if kind == 'tool-call':
            ident = 'call_' + cache_key[:16]
            arguments = {'path': 'README.md'}
            with self.lock:
                self.strict_calls[ident] = {'call': {'name': 'read', 'arguments': arguments}, 'result': 'fixture file contents'}
        if responses:
            if kind == 'tool-call':
                tool = {'type': 'function_call', 'id': 'fc_' + cache_key[:16], 'call_id': ident, 'name': 'read', 'arguments': encoded(arguments).decode()}
                output = [expected_opaque, tool]
                events = [{'type': 'response.output_item.added', 'output_index': 1, 'item': {**tool, 'arguments': ''}}, {'type': 'response.function_call_arguments.delta', 'output_index': 1, 'delta': tool['arguments']}]
            else:
                output = [expected_opaque, {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text, 'annotations': []}], 'status': 'completed'}]
                events = [{'type': 'response.output_text.delta', 'delta': text}]
            events += [{'type': 'response.completed', 'response': {'id': 'resp_' + cache_key[:16], 'model': 'fixture-fixed', 'status': 'completed', 'output': output, 'usage': {'input_tokens': 24, 'output_tokens': 8, 'input_tokens_details': {'cached_tokens': 8}, 'cost': cost}}}]
        else:
            block = {'type': 'tool_use', 'id': ident, 'name': 'read', 'input': {}} if kind == 'tool-call' else {'type': 'text', 'text': ''}
            delta = {'type': 'input_json_delta', 'partial_json': encoded(arguments).decode()} if kind == 'tool-call' else {'type': 'text_delta', 'text': text}
            events = [{'type': 'message_start', 'message': {'id': 'msg_' + cache_key[:16], 'type': 'message', 'model': 'fixture-fixed', 'role': 'assistant', 'content': [], 'usage': {'input_tokens': 16, 'output_tokens': 0, 'cache_read_input_tokens': 8, 'cache_creation_input_tokens': 0}}},
                      {'type': 'content_block_start', 'index': 0, 'content_block': expected_opaque}, {'type': 'content_block_stop', 'index': 0},
                      {'type': 'content_block_start', 'index': 1, 'content_block': block}, {'type': 'content_block_delta', 'index': 1, 'delta': delta}, {'type': 'content_block_stop', 'index': 1},
                      {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use' if kind == 'tool-call' else 'end_turn'}, 'usage': {'output_tokens': 8, 'cost': cost}}, {'type': 'message_stop'}]
        if kind == 'cancel':
            events = events[:-1] if responses else events[:-2]
        output = b''.join(b'event: ' + event['type'].encode() + b'\r\ndata: ' + encoded(event) + b'\r\n\r\n' for event in events)
        record['response'] = output
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
        self.send_header('X-Litellm-Response-Cost', '0'); self.send_header('X-Fixture-Cache', 'HIT' if cache_hit else 'MISS')
        self.send_header('X-Litellm-Call-Id', cache_key[:16]); self.send_header('X-Litellm-Version', 'fixture-strict-v1'); self.end_headers()
        try:
            for offset in range(0, len(output), 7):
                self.wfile.write(output[offset:offset + 7]); self.wfile.flush()
            if kind == 'cancel':
                for _ in range(60):
                    time.sleep(.03); self.wfile.write(b': pending\n\n'); self.wfile.flush()
                    record['response'] += b': pending\n\n'
        except (BrokenPipeError, ConnectionResetError):
            record['cancelled'] = True

class Peer:
    def __init__(self, cwd):
        self.process = subprocess.Popen([str(BINARY)], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.frames = queue.Queue(); self.events = []; self.captures = []; self.reject_capture = False
        self.write_lock = threading.Lock(); self.capture_lock = threading.Lock()
        def read():
            for line in self.process.stdout:
                frame = json.loads(line)
                if frame.get('kind') == 'capture':
                    with self.capture_lock: self.captures.append(frame['packet'])
                    self.send({'v': 1, 'kind': 'capture.ack', 'hostEpoch': frame['hostEpoch'], 'transferId': frame['transferId'], 'accepted': not self.reject_capture})
                else: self.frames.put(frame)
        self.reader = threading.Thread(target=read, daemon=True); self.reader.start()
        self.send({'v':1,'kind':'hello','major':1,'minor':1})
        hello = self.frames.get(timeout=10)
        assert hello['kind'] == 'ready' and hello['engine'] == 'swift', hello
        assert 'responses' in hello['capabilities'] and 'messages' not in hello['capabilities'], hello
        self.ready = hello
        self.epoch = hello['hostEpoch']
    def send(self, value):
        with self.write_lock:
            self.process.stdin.write(encoded(value)+b'\n'); self.process.stdin.flush()
    def command(self, method, params=None, session=None, command_id=None, fail=False):
        command_id = command_id or str(uuid.uuid4())
        self.send({'v':1,'kind':'command','hostEpoch':self.epoch,'commandId':command_id,'sessionId':session,'method':method,'params':params or {}})
        deadline = time.monotonic()+15
        while True:
            frame = self.frames.get(timeout=max(.01,deadline-time.monotonic()))
            if frame.get('commandId') == command_id:
                if fail:
                    assert not frame['ok'], frame
                else:
                    assert frame['ok'], frame
                return frame.get('result')
            self.events.append(frame)
    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait()
        self.reader.join(timeout=2)
        self.process.stdout.close(); self.process.stderr.close()

class NativeIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
        cls.thread = threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
        cls.base = 'http://127.0.0.1:'+str(cls.server.server_port)
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join()
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pi-native-integration-')
        self.root = pathlib.Path(self.temp.name)
        (self.root/'README.md').write_text('fixture file contents')
        self.peer = Peer(self.root)
        self.peer.command('workspace.open',{'cwd':str(self.root),'directory':str(self.root/'sessions'),'captureProtocol':1,'resources':{'codexHome':str(self.root/'codex')}})
    def tearDown(self):
        self.peer.close();self.temp.cleanup()
    def open(self, api='openai-responses', model='text', session='s', routing=None, profile_headers=None, fail=False, **extra):
        # The catalog ceiling (modelOutputLimit) is what requests carry; maxOutputTokens is the local reserve.
        profile={'id':'p','revision':'1','providerId':'litellm','modelId':model,'api':api,'baseUrl':self.base+'/v1','contextWindow':100000,'maxOutputTokens':4096,'modelOutputLimit':4096,'reasoning':True,'thinkingLevel':'default','routing': routing if routing is not None else {'replayPolicy':'portable'}}
        if profile_headers: profile['headers'] = profile_headers
        return self.peer.command('session.open',{'profile':profile,'apiKey':'fixture-secret','toolMode':'editing',**extra},session,fail=fail)
    def submit(self, session='s', text='question'):
        return self.peer.command('turn.submit',{'clientTurnId':str(uuid.uuid4()),'text':text},session)
    def settled(self, session='s', timeout=12):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            value=self.peer.command('session.snapshot',session=session)
            # Since 0.1.45 a failed run settles as 'error' (retryable from the failure row); a stop settles as 'paused'.
            if value['state'] in ('idle','paused','error'):
                return value
            time.sleep(.01)
        self.fail('Session did not settle')
    def test_request_observations_during_tool_loop_without_capture_and_after_recorder_rejection(self):
        for capture, reject in [('off',False), ('persist',True), ('memory',False)]:
            session = 'observations-'+capture
            self.peer.reject_capture = reject
            self.open(model='observation-early', session=session)
            self.peer.command('debug.mode', {'mode':capture}, session)
            self.submit(session)
            seen = {}; deadline = time.monotonic()+8
            while time.monotonic()<deadline:
                state = self.peer.command('session.snapshot', {'includeMessages':False,'includeMetrics':False}, session)
                observation = state.get('requestObservation') or {}
                input_tokens = observation.get('usage',{}).get('input')
                if input_tokens is not None:
                    seen.setdefault(input_tokens,set()).add(observation['phase'])
                    self.assertEqual(observation['contextWindow'],100000)
                    self.assertEqual(observation['sessionID'],session)
                    self.assertLessEqual(observation['usage'].get('output',0),30)
                if state['state'] in ('idle','error'): break
                time.sleep(.02)
            self.assertEqual(state['state'],'idle',state.get('preflightError'))
            self.assertEqual(set(seen),{1000,2000,3000})
            self.assertTrue(all('interim' in seen[n] for n in seen),seen)
            self.assertEqual(observation['phase'],'final'); self.assertEqual(observation['usage']['total'],3030)
            self.assertEqual(observation['usage']['reasoning'],20)
            self.peer.command('session.close',session=session)
        self.peer.reject_capture = False
        self.open(model='observation-final',session='final-only'); self.submit('final-only')
        time.sleep(.2)
        state=self.peer.command('session.snapshot',session='final-only')
        self.assertIsNone(state['requestObservation']['usage'].get('input'))
        self.assertIsNotNone(state['requestObservation']['estimate']['tokens'])
        self.assertEqual(self.settled('final-only')['requestObservation']['usage']['input'],3000)

    def test_live_monitoring_preserves_fast_usage_and_tool_phases_without_transcripts(self):
        for model in ('observation-early', 'observation-final'):
            session = 'monitor-' + model
            self.open(model=model, session=session)
            self.peer.command('debug.mode', {'mode':'off'}, session)
            self.submit(session)
            state = self.settled(session)
            page = state['monitoring']
            self.assertFalse(page['gap'])
            events = page['events']
            self.assertIn('tool', [e.get('phase') for e in events if e['kind']=='phase'])
            requests = [e for e in events if e['kind']=='request']
            attempts = {e['attemptID'] for e in requests}
            self.assertEqual(len(attempts), 3)
            for attempt in attempts:
                observations = [e for e in requests if e['attemptID']==attempt]
                final = observations[-1]
                self.assertEqual(final['phase'], 'final')
                self.assertEqual(final['usage']['output'], 30)
                self.assertEqual(final['usage']['reasoning'], 20)
                self.assertGreater(final['telemetry']['modelComplete'], final['telemetry']['dispatch'])
                self.assertEqual(final['telemetry']['identity']['effectiveModel'], 'resolved-fixture')
                interim = [e for e in observations if e['phase']=='interim' and 'output' in e['usage']]
                self.assertEqual([e['usage']['output'] for e in interim], [10,20] if model=='observation-early' else [])
            unchanged = self.peer.command('session.status', {'includeMessages':False, 'includeMetrics':False,
                'monitoringEpoch':page['epoch'], 'monitoringCursor':page['cursor']}, session)
            self.assertEqual(unchanged['monitoring']['events'], [])
            self.assertNotIn('messages', unchanged)
            self.assertNotIn('latestAttempt', unchanged)
            self.assertNotIn('fixture-secret', json.dumps(page))
            self.assertNotIn('requestFingerprint', json.dumps(page))
            self.peer.command('session.close',session=session)

    def test_responses_real_stream_tool_roundtrip_and_capture(self):
        self.open(model='tool');self.submit();value=self.settled()
        self.assertEqual(value['state'],'idle')
        self.assertIn('fixture file contents',json.dumps(value['messages']))
        attempts=self.peer.command('debug.list',session='s')['attempts'];self.assertEqual(len(attempts),2)
        for attempt in attempts:
            request=self.peer.command('debug.body',{'attemptId':attempt['attemptId'],'body':'request'},'s')
            response=self.peer.command('debug.body',{'attemptId':attempt['attemptId'],'body':'response'},'s')
            sent=base64.b64decode(request['bytes']);received=base64.b64decode(response['bytes'])
            record=next(r for r in Fixture.requests if r['body']==sent)
            self.assertEqual(record['response'],received)
            metadata=self.peer.command('debug.attempt',{'attemptId':attempt['attemptId']},'s')
            self.assertEqual(metadata['requestHash']['sha256'],hashlib.sha256(sent).hexdigest())
            self.assertEqual(metadata['requestHeaders']['authorization'],'Bearer ********cret')
            self.assertEqual(metadata['responseHeaders']['content-type'], 'text/event-stream')
            self.assertTrue(metadata['responseHeaders']['date'])
            self.assertTrue(metadata['responseHeaders']['server'].startswith('BaseHTTP/'))
            self.assertIsNotNone(metadata['metrics']['observedTTFTms'])
            # Session/turn correlation is transport-owned plain text on the wire, in
            # the captured headers and in the Responses metadata body field.
            wire={k.lower():v for k,v in record['headers'].items()}
            self.assertEqual(wire['x-session-id'],'s'); self.assertEqual(wire['x-turn-id'],attempt['turnId'])
            self.assertEqual(metadata['requestHeaders']['x-session-id'],'s'); self.assertEqual(metadata['requestHeaders']['x-turn-id'],attempt['turnId'])
            self.assertEqual(json.loads(sent)['metadata'],{'session_id':'s'}); self.assertTrue(metadata['request']['byteExact'])
            # Pi 0.85.1's request: its session prompt cache and affinity headers,
            # the system prompt as the first input item, no serial-tools or
            # strict flags, and a user message without an item type.
            body=json.loads(sent)
            self.assertEqual(body['prompt_cache_key'],'s'); self.assertEqual(wire['session_id'],'s'); self.assertEqual(wire['x-client-request-id'],'s')
            self.assertEqual(body['input'][0]['role'],'developer'); self.assertIsInstance(body['input'][0]['content'],str)
            self.assertNotIn('instructions',body); self.assertNotIn('parallel_tool_calls',body)
            self.assertTrue(all('strict' not in tool for tool in body['tools']))
            self.assertEqual(body['input'][1],{'role':'user','content':[{'type':'input_text','text':'question'}]})
    def test_turn_overrides_and_edit_branch_reach_the_wire_and_survive_reload(self):
        session='overrides'; self.open(model='text',session=session)
        first=str(uuid.uuid4()); self.peer.command('turn.submit',{'clientTurnId':first,'text':'first question'},session)
        self.assertEqual(self.settled(session)['state'],'idle')
        second=str(uuid.uuid4()); self.peer.command('turn.submit',{'clientTurnId':second,'text':'second question','model':'text','thinkingLevel':'high'},session)
        self.assertEqual(self.settled(session)['state'],'idle')
        attempt=self.peer.command('debug.list',session=session)['attempts'][0]
        body=json.loads(base64.b64decode(self.peer.command('debug.body',{'attemptId':attempt['attemptId'],'body':'request'},session)['bytes']))
        self.assertEqual(attempt['turnId'],second); self.assertEqual(attempt['requestedModel'],'text'); self.assertEqual(body['reasoning'],{'effort':'high','summary':'auto'})
        record=next(r for r in reversed(Fixture.requests) if r['path'].endswith('/responses') and r['headers'].get('x-turn-id')==second)
        self.assertEqual(record['headers']['x-session-id'],session)
        self.peer.command('turn.submit',{'clientTurnId':str(uuid.uuid4()),'text':'bad','thinkingLevel':'extreme'},session,fail=True)
        self.peer.command('turn.submit',{'clientTurnId':str(uuid.uuid4()),'text':'bad','model':''},session,fail=True)
        # Editing the first question branches: the tail leaves the display and the
        # model context, a marker row appears, and the journal keeps every record.
        edited=str(uuid.uuid4()); self.peer.command('turn.edit',{'messageId':first,'clientTurnId':edited,'text':'edited question'},session)
        value=self.settled(session); self.assertEqual(value['state'],'idle')
        kinds=[m.get('kind') for m in value['messages']]; texts=[m['text'] for m in value['messages']]
        # Since 0.1.79 every reply is preceded by its request-ledger row. The one
        # row left belongs to the edited turn's own reply; the rows of the two
        # replies edited away leave the page with them (they stay in the journal).
        self.assertEqual(kinds,['branch',None,'requestLedger',None]); self.assertEqual(texts[0],'Edited from here · earlier replies stay in the journal'); self.assertEqual(texts[1],'edited question')
        ledger,reply=value['messages'][2],value['messages'][3]
        latest=self.peer.command('debug.list',session=session)['attempts'][0]; self.assertEqual(latest['turnId'],edited)
        self.assertEqual(ledger['presentationSourceID'],reply['id']); self.assertEqual(ledger['turn'],edited)
        self.assertEqual({s['part']['attemptID'] for s in ledger['responseTimeline']['segments']},{latest['attemptId']})
        request=json.loads(base64.b64decode(self.peer.command('debug.body',{'attemptId':latest['attemptId'],'body':'request'},session)['bytes']))
        self.assertEqual([i['content'][0]['text'] for i in request['input'] if i.get('role')=='user'],['edited question'])
        self.peer.command('turn.edit',{'messageId':first,'clientTurnId':str(uuid.uuid4()),'text':'again'},session,fail=True)
        path=value['path']; self.peer.command('session.close',session=session)
        journal=[json.loads(line) for line in pathlib.Path(path).read_bytes().split(b'\n') if line]
        self.assertTrue(any(r.get('type')=='branch' and r['fromMessageId']==first and r['keptIds']==[] for r in journal))
        self.assertEqual([r for r in journal if r.get('type')=='message' and r['id']==second][0]['thinkingLevel'],'high')
        self.assertEqual(sum(1 for r in journal if r.get('type')=='message' and r['message']['role']=='user'),3)
        ledgers=[(i,r['message']['nativeTurn']) for i,r in enumerate(journal) if r.get('type')=='message' and r['message'].get('nativeKind')=='requestLedger']
        branch_at=next(i for i,r in enumerate(journal) if r.get('type')=='branch')
        self.assertEqual([turn for _,turn in ledgers],[first,second,edited],'the journal keeps every ledger row')
        self.assertEqual([i>branch_at for i,_ in ledgers],[False,False,True],'only the edited turn\'s ledger row was written after the branch')
        reopened=self.open(model='text',session=session,path=path)
        self.assertEqual([m.get('kind') for m in reopened['messages']],['branch',None,'requestLedger',None]); self.assertEqual(reopened['total'],4)
        self.assertEqual(reopened['messages'][2]['id'],ledger['id'])
        self.peer.command('session.message.read',{'messageId':first},session)
        self.peer.command('session.close',session=session)
    def test_message_versions_list_and_page_an_earlier_version_over_the_wire(self):
        # Additive since 0.1.93: an edited message's row says which version it
        # is, session.versions lists them and session.version.page reads the
        # rows of one, in the transcript's own row format.
        for capability in ('message-versions','fork-at-message'): self.assertIn(capability, self.peer.ready['capabilities'])
        session='versions'; self.open(model='text',session=session)
        first=str(uuid.uuid4()); self.peer.command('turn.submit',{'clientTurnId':first,'text':'first question'},session); self.settled(session)
        second=str(uuid.uuid4()); self.peer.command('turn.submit',{'clientTurnId':second,'text':'second question'},session); self.settled(session)
        original=next(a for a in self.peer.command('debug.list',session=session)['attempts'] if a['turnId']==second)['attemptId']
        edited=str(uuid.uuid4()); self.peer.command('turn.edit',{'messageId':second,'clientTurnId':edited,'text':'second question, edited'},session)
        value=self.settled(session); self.assertEqual(value['state'],'idle')
        rows={m['id']:m for m in value['messages']}
        self.assertEqual(rows[edited]['versions'],{'index':2,'count':2,'ids':[second,edited]})
        self.assertNotIn('versions',rows[first])
        listed=self.peer.command('session.versions',{'messageId':edited},session)
        self.assertEqual([v['messageId'] for v in listed['versions']],[second,edited]); self.assertEqual(listed['current'],2)
        self.assertEqual([v['live'] for v in listed['versions']],[False,True]); self.assertEqual(listed['versions'][0]['text'],'second question')
        self.assertEqual(self.peer.command('session.versions',session=session)['groups'][0]['group'],second)
        self.assertEqual(self.peer.command('session.versions',{'messageId':first},session)['versions'],[])
        page=self.peer.command('session.version.page',{'messageId':second},session)
        self.assertEqual([m.get('kind') for m in page['messages']],[None,'requestLedger',None])
        self.assertEqual(page['messages'][0]['text'],'second question'); self.assertIsNone(page['next']); self.assertEqual(page['total'],3)
        reply=page['messages'][2]; self.assertEqual(reply['role'],'assistant')
        self.assertEqual(reply['requestAttemptIDs'],[original]); self.assertEqual(reply['reply']['attempt'],original)
        self.assertEqual(page['messages'][1]['requestAttemptIDs'],[original])
        self.peer.command('session.version.page',{'messageId':first},session,fail=True)
        # Reopened, the same journal lists the same versions: nothing was rewritten to show them.
        path=value['path']; before=pathlib.Path(path).read_bytes(); self.peer.command('session.close',session=session)
        self.open(model='text',session=session,path=path)
        again=self.peer.command('session.versions',{'messageId':second},session)
        self.assertEqual([v['messageId'] for v in again['versions']],[second,edited])
        self.assertEqual(pathlib.Path(path).read_bytes(),before)
        self.peer.command('session.close',session=session)
    def test_fork_at_a_reply_keeps_the_journal_up_to_it_and_its_tool_batch(self):
        session='forked'; self.open(model='tool',session=session)
        turns=[str(uuid.uuid4()) for _ in range(3)]
        for index,turn in enumerate(turns):
            self.peer.command('turn.submit',{'clientTurnId':turn,'text':'question %d'%index},session); self.assertEqual(self.settled(session)['state'],'idle')
        value=self.peer.command('session.snapshot',session=session)
        replies=[m for m in value['messages'] if m['role']=='assistant']
        # The fixture calls a tool in the first turn only.
        calling=next(m for m in replies if m['turn']==turns[0] and m['tools'])
        answer=next(m for m in replies if m['turn']==turns[0] and not m['tools'])
        fork=self.peer.command('session.fork',{'forkSessionId':'at-reply','atMessageId':calling['id']},session)
        self.assertEqual(fork['origin']['forkedAtMessageId'],calling['id'])
        journal=[json.loads(line) for line in pathlib.Path(fork['path']).read_bytes().split(b'\n') if line]
        ids={r.get('id') for r in journal}
        self.assertFalse(ids & set(turns[1:])); self.assertNotIn(answer['id'],ids,'the reply after the tool batch is later')
        messages=[r for r in journal if r.get('type')=='message']
        self.assertEqual(messages[-1]['message']['role'],'toolResult','the fork starts after the tool batch')
        copied=self.peer.command('session.snapshot',session='at-reply')
        self.assertEqual(copied['state'],'idle'); self.assertEqual(copied['queueCount'],0)
        self.assertEqual([m['id'] for m in copied['messages'] if m['role']=='user'],turns[:1])
        self.assertEqual([m['id'] for m in copied['messages'] if m['role']=='assistant'][-1],calling['id'])
        self.peer.command('session.fork',{'forkSessionId':'at-user','atMessageId':turns[1]},session,fail=True)
        self.peer.command('session.fork',{'forkSessionId':'at-nothing','atMessageId':str(uuid.uuid4())},session,fail=True)
        # The fork answers from where it starts.
        self.peer.command('turn.submit',{'clientTurnId':str(uuid.uuid4()),'text':'fork question'},'at-reply')
        self.assertEqual(self.settled('at-reply')['state'],'idle')
        for name in ('at-reply',session): self.peer.command('session.close',session=name)
    def test_responses_capacity_overrides_reach_all_tool_rounds(self):
        for api in ['openai-responses']:
            session = 'limits-'+api; self.open(api=api,model='text',session=session)
            turn = str(uuid.uuid4())
            self.peer.command('turn.submit',{'clientTurnId':turn,'text':'read the file','model':'limited-tool','thinkingLevel':'high','contextWindow':16000,'maxOutputTokens':2048,'modelOutputLimit':2048},session)
            value = self.settled(session); self.assertEqual(value['state'],'idle',value.get('preflightError'))
            attempts = self.peer.command('debug.list',session=session)['attempts']; self.assertEqual(len(attempts),2)
            for attempt in attempts:
                self.assertEqual(attempt['requestedModel'],'limited-tool'); self.assertEqual(attempt['turnId'],turn)
                sent = self.captured_body(session,attempt,'request'); body = json.loads(sent)
                self.assertEqual(body['max_output_tokens' if api=='openai-responses' else 'max_tokens'],2048)
                if api=='openai-responses': self.assertEqual(body['reasoning']['effort'],'high')
                else: self.assertEqual(body['thinking'],{'type':'enabled','budget_tokens':2047})
                self.assertTrue(any(r['body']==sent and r.get('validated') for r in Fixture.requests))
            for invalid in [{'contextWindow':1000,'maxOutputTokens':1000},{'contextWindow':'16000'},{'maxOutputTokens':0}]:
                self.peer.command('turn.edit',{'messageId':turn,'clientTurnId':str(uuid.uuid4()),'text':'invalid',**invalid},session,fail=True)
            self.assertEqual(self.peer.command('session.snapshot',session=session)['messages'],value['messages'])
            self.submit(session,'back to configured model'); self.assertEqual(self.settled(session)['state'],'idle')
            last = self.peer.command('debug.list',session=session)['attempts'][0]
            body = json.loads(self.captured_body(session,last,'request'))
            self.assertEqual(body['model'],'text'); self.assertEqual(body['max_output_tokens' if api=='openai-responses' else 'max_tokens'],4096)
            self.peer.command('session.close',session=session)
    def test_responses_credentials_mask_headers_hash_bodies_and_preserve_exact_wire(self):
        key, custom = 'fixture-secret', 'custom-fixture-secret'
        fingerprint = lambda text: '[sha256:'+hashlib.sha256(text.encode()).hexdigest()+']'
        for api in ['openai-responses']:
            session = 'credentials-'+api
            self.open(api,model='credential-echo',session=session,profile_headers={'X-Custom-Auth':custom},routing={'replayPolicy':'portable','reference':'fixture-v1','modelHeader':'x-fixture-actual-model'})
            self.peer.command('debug.mode',{'mode':'persist'},session)
            self.submit(session,'literal credentials '+key+' / '+custom); self.assertEqual(self.settled(session)['state'],'idle')
            metadata = self.peer.command('debug.list',session=session)['attempts'][0]
            retained = base64.b64decode(self.peer.command('debug.body',{'attemptId':metadata['attemptId'],'body':'request'},session)['bytes'])
            record = next(r for r in reversed(Fixture.requests) if r['path'].endswith('/responses' if api=='openai-responses' else '/messages') and key.encode() in r['body'])
            wire_headers = {k.lower():v for k,v in record['headers'].items()}
            self.assertEqual(wire_headers['authorization'],'Bearer '+key); self.assertEqual(wire_headers['x-custom-auth'],custom)
            self.assertEqual(metadata['requestHeaders']['authorization'],'Bearer ********cret'); self.assertEqual(metadata['requestHeaders']['x-custom-auth'],'********cret')
            if api=='anthropic-messages':
                self.assertEqual(wire_headers['x-api-key'],key); self.assertEqual(metadata['requestHeaders']['x-api-key'],'********cret')
            self.assertEqual(retained,record['body'].replace(custom.encode(),fingerprint(custom).encode()).replace(key.encode(),fingerprint(key).encode()))
            self.assertEqual(metadata['request']['state'],'credential-hashed'); self.assertFalse(metadata['request']['byteExact'])
            self.assertEqual(metadata['request']['observedBytes'],len(record['body'])); self.assertEqual(metadata['request']['captureBytes'],len(retained))
            self.assertEqual(metadata['identity']['status'],'incomplete'); self.assertEqual(metadata['responseHeaders']['x-request-id'],'********')
            self.assertEqual(metadata['responseHeaders']['set-cookie'],'********')
            self.assertNotIn(key,json.dumps(metadata)); self.assertNotIn(custom,json.dumps(metadata))
            response = base64.b64decode(self.peer.command('debug.body',{'attemptId':metadata['attemptId'],'body':'response'},session)['bytes'])
            self.assertEqual(response,record['response'])
            with self.peer.capture_lock: packets = [p for p in self.peer.captures if p.get('attemptId',p.get('metadata',{}).get('attemptId'))==metadata['attemptId']]
            durable = b''.join(base64.b64decode(p['bytes']) for p in packets if p['type']=='bytes' and p['body']=='request')
            self.assertEqual(durable,retained)
            for packet in packets:
                if packet['type']!='bytes': self.assertNotIn(key,json.dumps(packet)); self.assertNotIn(custom,json.dumps(packet))
            self.peer.command('session.close',session=session)
    def test_refusal_final_only_and_failed_terminal_are_observed(self):
        cases = [('openai-responses','refusal'),('openai-responses','terminal-only'),('openai-responses','failed-terminal')]
        for api, model in cases:
            session = api + model
            self.open(api,model=model,session=session); self.submit(session)
            self.assertEqual(self.settled(session)['state'],'error' if model == 'failed-terminal' else 'idle')
            attempt = self.peer.command('debug.list',session=session)['attempts'][0]
            self.assertIsNotNone(attempt['timings']['firstContent']); self.assertIsNotNone(attempt['timings']['firstText'])
            self.assertIsNotNone(attempt['timings']['modelComplete'])
            self.assertEqual(attempt['response']['state'],'complete'); self.assertEqual(attempt['transportOutcome'],'eof')
            if model == 'failed-terminal':
                self.assertEqual(attempt['modelOutcome'],'failed')
                self.assertGreater(attempt['timings']['httpEnd']-attempt['timings']['modelComplete'],100)
            self.peer.command('session.close',session=session)
    def test_responses_gateway_reported_cost_cache_and_exact_bytes(self):
        for api in ['openai-responses']:
            for model, status, cost in [('billing-paid','reported',0.0123),('billing-free','reported',0),('billing-unknown','unreported',None),('billing-invalid','invalid',None),('billing-conflict','conflict',None),('billing-json','reported',0.0123)]:
                session = model+api
                self.open(api,model=model,session=session,routing={'replayPolicy':'portable','reference':'fixture-v1','cacheHeader':'x-fixture-cache'})
                self.submit(session); self.assertEqual(self.settled(session)['state'],'idle')
                attempt = self.peer.command('debug.list',session=session)['attempts'][0]
                self.assertEqual(attempt['gateway']['cost']['status'],status); self.assertEqual(attempt['gateway']['cost']['usd'],cost)
                self.assertEqual(attempt['gateway']['cache']['status'],'unreported' if model == 'billing-unknown' else 'hit' if model == 'billing-free' else 'miss')
                if status == 'reported': self.assertIn('usage.cost',attempt['gateway']['cost']['source'])
                if model == 'billing-unknown': self.assertIsNone(attempt['gateway']['cost']['usd'], 'A pre-stream zero is not a reported free request')
                request = base64.b64decode(self.peer.command('debug.body',{'attemptId':attempt['attemptId'],'body':'request'},session)['bytes'])
                response = base64.b64decode(self.peer.command('debug.body',{'attemptId':attempt['attemptId'],'body':'response'},session)['bytes'])
                observed = next(r for r in reversed(Fixture.requests) if r['body']==request)
                self.assertEqual(response,observed['response'])
                self.peer.command('session.close',session=session)
    def test_cost_limit_on_open_configure_and_reopen_stops_at_reported_spend(self):
        # Each billing reply reports usage.cost 0.0123 on its terminal event.
        self.assertIn('cost-limit', self.peer.ready['capabilities'])
        session = 'cost-limit'
        opened = self.open(model='billing-limit', session=session, costLimit={'usd': 0.02})
        self.assertEqual(opened['cost']['limitUSD'], 0.02); self.assertEqual(opened['cost']['spentUSD'], 0)
        self.submit(session, 'first'); value = self.settled(session)
        self.assertEqual(value['state'], 'idle'); self.assertAlmostEqual(value['cost']['spentUSD'], 0.0123)
        self.assertFalse(value['cost']['reached'])
        # Below the limit the request goes; its reply takes the chat past it.
        self.submit(session, 'second'); value = self.settled(session)
        self.assertEqual(value['state'], 'idle'); self.assertAlmostEqual(value['cost']['spentUSD'], 0.0246)
        self.assertEqual(value['cost']['reportedRequests'], 2); self.assertTrue(value['cost']['reached'])
        sent = len(Fixture.requests)
        refused = self.peer.command('turn.submit', {'clientTurnId': str(uuid.uuid4()), 'text': 'third'}, session, fail=True)
        self.assertEqual(refused['code'], 'cost_limit')
        self.assertEqual(refused['message'], 'This chat reached its $0.02 cost limit ($0.02 spent). Raise the limit to continue.')
        self.assertEqual(len(Fixture.requests), sent, 'A chat at its limit sends nothing')
        # A configure that carries only the limit applies at once and keeps the connection.
        self.assertEqual(self.peer.command('session.configure', {'costLimit': {'usd': 1}}, session), {'accepted': True, 'applied': True})
        self.submit(session, 'third'); value = self.settled(session)
        self.assertEqual(value['state'], 'idle'); self.assertAlmostEqual(value['cost']['spentUSD'], 0.0369)
        self.peer.command('session.configure', {'costLimit': {'usd': None}}, session)
        self.assertIsNone(self.peer.command('session.status', session=session)['cost']['limitUSD'])
        self.peer.command('session.configure', {'costLimit': {'usd': -1}}, session, fail=True)
        # The spend is in the journal: a reopened chat is checked against it.
        self.peer.command('session.close', session=session)
        reopened = self.open(model='billing-limit', session=session, path=value['path'], costLimit={'usd': 0.03})
        self.assertAlmostEqual(reopened['cost']['spentUSD'], 0.0369); self.assertTrue(reopened['cost']['reached'])
        journal = [json.loads(line) for line in pathlib.Path(value['path']).read_bytes().split(b'\n') if line]
        self.assertEqual(sum(1 for r in journal if r.get('customType') == 'pi-app.cost.v1'), 3)
        # A request whose gateway reported no cost is counted as unknown, not free.
        self.open(model='billing-unknown', session='cost-unknown', costLimit={'usd': 0.01})
        self.submit('cost-unknown'); value = self.settled('cost-unknown')
        self.assertEqual(value['cost']['spentUSD'], 0); self.assertEqual(value['cost']['unreportedRequests'], 1)
        self.assertFalse(value['cost']['reached'])
    def test_cost_limit_stops_a_running_turn_and_reaches_sides_forks_and_seeds(self):
        # A tool round costs 0.0123: the request after it is not sent under a 0.01 limit.
        session = 'cost-stop'
        self.open(model='billing-tool', session=session, costLimit={'usd': 0.01})
        self.submit(session, 'read the fixture'); value = self.settled(session)
        self.assertEqual(value['state'], 'error'); self.assertEqual(value['errorCode'], 'cost_limit')
        self.assertEqual(value['preflightError'], 'This chat reached its $0.01 cost limit ($0.01 spent). Raise the limit to continue.')
        self.assertIn('fixture file contents', json.dumps(value['messages']), 'The request in flight finished and its tool ran')
        self.assertEqual(len(self.peer.command('debug.list', session=session)['attempts']), 1)
        # Raised mid-session: the stopped turn goes on from where it stopped.
        self.peer.command('session.configure', {'costLimit': {'usd': 1}}, session)
        self.peer.command('turn.retry', {}, session); value = self.settled(session)
        self.assertEqual(value['state'], 'idle', value.get('preflightError')); self.assertNotIn('errorCode', value)
        self.assertAlmostEqual(value['cost']['spentUSD'], 0.0246); self.assertEqual(value['cost']['reportedRequests'], 2)
        # A side and a fork are sessions of their own, with their own limit and spend.
        side = self.peer.command('side.open', {'sideSessionId': 'cost-side', 'costLimit': {'usd': 2}}, session)
        self.assertEqual(side['sessionId'], 'cost-side')
        state = self.peer.command('session.status', session='cost-side')
        self.assertEqual(state['cost']['limitUSD'], 2); self.assertEqual(state['cost']['spentUSD'], 0)
        fork = self.peer.command('session.fork', {'forkSessionId': 'cost-fork', 'costLimit': {'usd': None}}, session)
        state = self.peer.command('session.status', session='cost-fork')
        self.assertIsNone(state['cost']['limitUSD']); self.assertEqual(state['cost']['spentUSD'], 0)
        self.peer.command('session.close', session='cost-fork')
        reopened = self.open(model='billing-tool', session='cost-fork', path=fork['path'], costSeed={'usd': 9, 'reported': 1, 'unreported': 0})
        self.assertEqual(reopened['cost']['spentUSD'], 0, 'A fork records its own costs from the start and takes no seed')
        # A chat whose journal has no cost record takes the app's figure once.
        first = self.open(model='billing-limit', session='cost-seeded', costSeed={'usd': 3, 'reported': 2, 'unreported': 1})
        self.assertEqual(first['cost']['spentUSD'], 0, 'A new chat takes no seed')
        path = first['path']; self.peer.command('session.close', session='cost-seeded')
        for _ in range(2):
            seeded = self.open(model='billing-limit', session='cost-seeded', path=path, costSeed={'usd': 3, 'reported': 2, 'unreported': 1}, costLimit={'usd': 2.5})
            self.assertEqual(seeded['cost']['spentUSD'], 3); self.assertEqual(seeded['cost']['unreportedRequests'], 1)
            self.assertTrue(seeded['cost']['reached'])
            self.peer.command('session.close', session='cost-seeded')
        bad = self.peer.command('session.open', {'profile': {'id':'p'}, 'costLimit': 5}, 'cost-bad', fail=True)
        self.assertEqual(bad['code'], 'invalid_params'); self.assertIn('costLimit', bad['message'])
    def test_owner_samples_json_and_fragmented_sse_usage_model_cost_and_exact_capture(self):
        variants = [(f'fixture: owner-sample {transport} {cost}',transport,cost,False)
                    for transport in ('json','sse') for cost in ('null','paid','zero')]
        variants += [(f'fixture: owner-billing {transport}',transport,'null',True) for transport in ('json','sse')]
        for index,(prompt,transport,cost,billing) in enumerate(variants):
            with self.subTest(prompt=prompt):
                session='owner-sample-'+str(index)
                self.open(model='auto-router',session=session,profile_headers={'X-Fixture-Contract':'owner-sample-v1'})
                self.peer.command('debug.mode',{'mode':'persist'},session)
                self.submit(session,prompt)
                snapshot=self.settled(session); self.assertEqual(snapshot['state'],'idle',snapshot.get('preflightError'))
                self.assertEqual(snapshot['messages'][-1]['text'],'9.109996226')
                self.assertEqual(snapshot['messages'][-1]['thinking'],'A short calculation.')
                attempts=self.peer.command('debug.list',session=session)['attempts']; self.assertEqual(len(attempts),1)
                attempt=self.peer.command('debug.attempt',{'attemptId':attempts[0]['attemptId']},session)
                output,reasoning,total=(302,253,340) if billing else (423,326,461)
                self.assertEqual(attempt['usage']['input'],38)
                self.assertEqual(attempt['usage']['inputIncludingCache'],38)
                self.assertEqual(attempt['usage']['output'],output)
                self.assertEqual(attempt['usage']['reasoning'],reasoning)
                self.assertEqual(attempt['usage']['cacheRead'],0)
                self.assertEqual(attempt['usage']['cacheWrite'],0)
                self.assertEqual(attempt['usage']['raw']['total_tokens'],total)
                context=self.peer.command('context.info',session=session)
                self.assertEqual(context['cumulative'],{'input':38,'output':output,'inputStatus':'reported','outputStatus':'reported'})
                self.assertEqual(sum(context['cumulative'][key] for key in ('input','output')),total,'Reasoning and cache tokens must not be added twice')
                self.assertEqual(attempt['requestedModel'],'auto-router')
                self.assertEqual(attempt['identity']['requestedAlias'],'auto-router')
                self.assertEqual(attempt['identity']['status'],'reported')
                self.assertEqual(attempt['identity']['effectiveModel'],'gpt-5.4-mini')
                source='response.completed.response.router_model_name' if transport=='sse' else 'body.router_model_name'
                self.assertIn({'kind':'model','source':source,'value':'gpt-5.4-mini'},attempt['identity']['evidence'])
                expected_cost=0.0013875 if billing and transport=='json' else 0.00123 if cost=='paid' else 0 if cost=='zero' else None
                gateway=attempt['gateway']
                self.assertEqual(gateway['cost']['status'],'reported' if expected_cost is not None else 'unreported')
                self.assertEqual(gateway['cost']['usd'],expected_cost)
                self.assertEqual(gateway['cache']['status'],'unreported','Prompt-cache counts cannot imply a response-cache hit')
                if billing:
                    self.assertEqual(gateway['gatewayVersion'],'1.99.0')
                    self.assertEqual(gateway['costBreakdown']['reasoning']['status'],'reported' if transport=='json' else 'unreported')
                    self.assertEqual(gateway['costBreakdown']['reasoning']['usd'],0.0011385 if transport=='json' else None)
                    if transport=='json':
                        self.assertEqual(gateway['cost']['source'],'header:x-litellm-response-cost')
                        self.assertEqual(gateway['costBreakdown']['classifier']['usd'],0.0000904)
                        self.assertEqual(gateway['cost']['usd'],0.0013875,'Classifier and reasoning components must not be added to total')
                    else:
                        self.assertEqual(gateway['costBreakdown']['reasoning']['streamingHeaderUSD'],0.0011385)
                    self.assertIn({'kind':'model','source':'header:x-litellm-model-name','value':'openai/gpt-5.4-mini'},attempt['identity']['evidence'])
                elif expected_cost is not None:
                    self.assertEqual(gateway['cost']['source'],('response.completed.response.usage.cost' if transport=='sse' else 'body.usage.cost'))
                request=self.captured_body(session,attempt,'request'); response=self.captured_body(session,attempt,'response')
                with Fixture.lock: record=next(r for r in reversed(Fixture.requests) if r['body']==request)
                self.assertTrue(record['validated']); self.assertNotIn('rejection',record)
                self.assertEqual(record['response'],response)
                body=json.loads(request)
                self.assertEqual(body['model'],'auto-router'); self.assertEqual(body['metadata'],{'session_id':session})
                self.assertTrue(body['stream']); self.assertEqual(body['max_output_tokens'],4096)
                self.assertEqual(record['path'],'/v1/responses')
                self.assertEqual(attempt['requestHash']['sha256'],hashlib.sha256(request).hexdigest())
                self.assertEqual(attempt['responseHash']['sha256'],hashlib.sha256(response).hexdigest())
                self.assertEqual(attempt['response']['state'],'complete')
                with self.peer.capture_lock: packets=list(self.peer.captures)
                for kind,expected in [('request',request),('response',response)]:
                    durable=bytearray()
                    for packet in packets:
                        if packet.get('type')=='bytes' and packet.get('attemptId')==attempt['attemptId'] and packet.get('body')==kind:
                            self.assertEqual(packet['offset'],len(durable)); durable.extend(base64.b64decode(packet['bytes']))
                    self.assertEqual(bytes(durable),expected)
                self.peer.command('session.close',session=session)

    def test_owner_sample_gateway_rejects_wrong_model_auth_correlation_and_prompt(self):
        self.open(model='auto-router',profile_headers={'X-Fixture-Contract':'owner-sample-v1'})
        self.submit(text='fixture: owner-sample json null'); self.assertEqual(self.settled()['state'],'idle')
        attempt=self.peer.command('debug.list',session='s')['attempts'][0]
        sent=self.captured_body('s',attempt,'request')
        with Fixture.lock: record=next(r for r in reversed(Fixture.requests) if r['body']==sent)
        headers={name:value for name,value in record['headers'].items() if name.lower() not in ('content-length','host','connection')}
        changes=[('model',lambda body:body.update(model='wrong-alias')),
                 ('limit',lambda body:body.update(max_output_tokens=7)),
                 ('metadata',lambda body:body.update(metadata={'session_id':'wrong-session'})),
                 ('prompt',lambda body:body['input'][-1]['content'][0].update(text='not the requested fixture'))]
        probes=[]
        for name,mutate in changes:
            body=json.loads(sent); mutate(body); probes.append((name,headers,encoded(body)))
        probes.append(('auth',{**headers,'Authorization':'Bearer wrong-fixture-key'},sent))
        probes.append(('custom-header',{name:value for name,value in headers.items() if name.lower()!='x-fixture-contract'},sent))
        for name,request_headers,payload in probes:
            with self.subTest(mutation=name):
                connection=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=5)
                connection.request('POST','/v1/responses',body=payload,headers=request_headers)
                response=connection.getresponse(); rejection=json.loads(response.read()); connection.close()
                self.assertEqual(response.status,422); self.assertEqual(rejection['error']['type'],'fixture_contract')
                self.assertNotIn('fixture-secret',json.dumps(rejection))
    def strict_open(self, api, session, policy='portable'):
        routing = {'replayPolicy':policy, 'reference':'Request-aware local fixture v1', 'cacheHeader':'x-fixture-cache'}
        if policy == 'pinned': routing.update(expectedModel='fixture-fixed', replayContract='Fixture route fixes exact compatible provider items')
        return self.open(api, model='strict-'+policy, session=session, routing=routing, profile_headers={'X-Fixture-Contract':'strict-v1'})
    def captured_body(self, session, attempt, kind):
        output, offset = bytearray(), 0
        while True:
            page = self.peer.command('debug.body',{'attemptId':attempt['attemptId'],'body':kind,'offset':offset},session)
            self.assertEqual(page['offset'], len(output)); output.extend(base64.b64decode(page['bytes']))
            if page['next'] is None: return bytes(output)
            offset = page['next']
    def test_responses_request_aware_gateway_tools_replay_compaction_and_capture(self):
        for api in ['openai-responses']:
            for policy in ['portable','pinned']:
                session = 'strict-'+api+policy
                self.strict_open(api, session, policy); self.peer.command('debug.mode',{'mode':'persist'},session)
                self.submit(session, 'fixture: read README.md')
                first = self.settled(session); self.assertEqual(first['state'],'idle')
                self.assertIn('Validated read: fixture file contents',json.dumps(first['messages']))
                self.submit(session,'fixture: long echo continuation 中文🙂'); self.assertEqual(self.settled(session)['state'],'idle')
                self.peer.command('context.compact',session=session)
                compacted = self.settled(session); self.assertEqual(compacted['state'],'idle',compacted.get('preflightError'))
                self.assertIn('Fixture continuation summary',json.dumps(compacted['messages']))
                # Pi splits the long echo's turn: one request summarizes the history and the turn's prefix.
                attempts = self.peer.command('debug.list',session=session)['attempts']; self.assertEqual(len(attempts),4)
                records = []
                with self.peer.capture_lock: packets = list(self.peer.captures)
                for attempt in attempts:
                    sent = self.captured_body(session,attempt,'request'); received = self.captured_body(session,attempt,'response')
                    record = next(r for r in reversed(Fixture.requests) if r['body']==sent)
                    records.append(record)
                    self.assertTrue(record['validated']); self.assertNotIn('rejection',record); self.assertEqual(record['response'],received)
                    self.assertEqual(json.loads(sent)['model'],'strict-'+policy)
                    self.assertEqual(attempt['requestHeaders']['authorization'],'Bearer ********cret')
                    self.assertNotIn('fixture-secret',json.dumps(attempt))
                    self.assertEqual(attempt['identity']['effectiveModel'],'fixture-fixed')
                    self.assertEqual(attempt['gateway']['cost']['status'],'reported'); self.assertEqual(attempt['gateway']['cache']['status'],'miss')
                    self.assertEqual(attempt['usage']['inputIncludingCache'],24)
                    for kind, expected in [('request',sent),('response',received)]:
                        durable = bytearray()
                        for packet in packets:
                            if packet.get('type')=='bytes' and packet.get('attemptId')==attempt['attemptId'] and packet.get('body')==kind:
                                self.assertEqual(packet['offset'],len(durable)); durable.extend(base64.b64decode(packet['bytes']))
                        self.assertEqual(bytes(durable),expected)
                self.assertEqual({r['scenario'] for r in records},{'tool-call','tool-result','text','compaction'})
                continuation = next(r for r in records if r['scenario']=='tool-result')
                self.assertEqual(bool(continuation['semantic']['opaque']),policy=='pinned')
                self.assertEqual(list(continuation['semantic']['results'].values()),['fixture file contents'])
                self.assertEqual(sum(a['purpose']=='compaction' for a in attempts),1)
                self.assertAlmostEqual(sum(a['gateway']['cost']['usd'] for a in attempts),0.0183)
                journals = ''.join(path.read_text() for path in (self.root/'sessions').rglob('*.jsonl'))
                self.assertIn('strict-original-opaque' if api=='openai-responses' else 'strict-original-signature',journals,'Portable replay must still retain original provider items on disk')
                self.peer.command('session.close',session=session)
    def test_strict_gateway_cache_depends_on_identical_request_and_preserves_zero_cost(self):
        for api in ['openai-responses']:
            requests = []
            session='cache-'+api; self.strict_open(api,session)
            previous_turn = None
            for index in range(3):
                turn = str(uuid.uuid4())
                params = {'clientTurnId':turn,'text':'fixture: cache same question '+api+(' changed' if index==2 else '')}
                if previous_turn is None:
                    self.peer.command('turn.submit',params,session)
                else:
                    self.peer.command('turn.edit',{'messageId':previous_turn,**params},session)
                previous_turn = turn
                self.assertEqual(self.settled(session)['state'],'idle')
                attempt=self.peer.command('debug.list',session=session)['attempts'][0]
                requests.append(self.captured_body(session,attempt,'request'))
                self.assertEqual(attempt['gateway']['cache']['status'],'hit' if index==1 else 'miss')
                self.assertEqual(attempt['gateway']['cost']['usd'],0 if index==1 else 0.0123)
                self.assertEqual(attempt['gateway']['cost']['status'],'reported')
                self.assertEqual(attempt['usage']['cacheRead'],8,'Provider prompt-cache tokens do not determine response-cache state')
            self.assertEqual(requests[0],requests[1], 'Cache fixture must key on actual identical serialized requests')
            self.assertNotEqual(requests[1],requests[2], 'Changing the question must miss the exact-request cache')
            if api=='openai-responses': self.assertTrue(all(json.loads(r)['metadata']=={'session_id':session} for r in requests))
            self.peer.command('session.close',session=session)
    def test_strict_gateway_request_selected_error_and_cancellation_do_not_replay(self):
        for api in ['openai-responses']:
            session='strict-errors-'+api; self.strict_open(api,session)
            self.submit(session,'fixture: error')
            # Pi's three production backoffs total 14 seconds; other scenarios keep
            # their original short deadline. Every physical attempt is captured.
            failed=self.settled(session,timeout=40); self.assertEqual(failed['state'],'error')
            self.assertIn('Failed after 4 attempts.',failed['preflightError'])
            attempts=self.peer.command('debug.list',session=session)['attempts']; self.assertEqual(len(attempts),4)
            request_bodies=[]
            for attempt in attempts:
                self.assertEqual(attempt['status'],429); self.assertEqual(attempt['gateway']['cost']['status'],'unreported')
                sent=self.captured_body(session,attempt,'request'); request_bodies.append(sent)
                record=next(r for r in reversed(Fixture.requests) if r['body']==sent)
                self.assertEqual(self.captured_body(session,attempt,'response'),record['response']); self.assertEqual(record['scenario'],'provider-error')
            self.assertEqual(len(set(request_bodies)),1,'Retries must preserve the submitted model context')
            self.assertEqual(sum(r['body']==request_bodies[0] for r in Fixture.requests),4,'The gateway must receive exactly one initial request and pi\'s three retries')
            self.peer.command('session.close',session=session)
            session='strict-cancel-'+api; self.strict_open(api,session); self.submit(session,'fixture: cancel')
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                attempts=self.peer.command('debug.list',session=session)['attempts']
                if attempts and attempts[0]['metrics']['observedTTFTms'] is not None: break
                time.sleep(.01)
            else: self.fail('Strict cancellation stream never produced content')
            self.submit(session,'fixture: echo queued'); self.peer.command('turn.stop',session=session)
            cancelled=self.settled(session); self.assertEqual(cancelled['state'],'paused'); self.assertEqual(cancelled['queueCount'],1)
            attempts=self.peer.command('debug.list',session=session)['attempts']; self.assertEqual(len(attempts),1)
            attempt=attempts[0]; self.assertEqual(attempt['transportOutcome'],'cancelled'); self.assertEqual(attempt['response']['state'],'partial')
            self.assertIsNone(attempt['gateway']['cost']['usd']); self.assertEqual(attempt['gateway']['cost']['status'],'unreported')
            record=next(r for r in reversed(Fixture.requests) if r['body']==self.captured_body(session,attempt,'request'))
            retained=self.captured_body(session,attempt,'response'); self.assertTrue(retained)
            self.assertTrue(record['response'].startswith(retained),'Cancelled capture must retain an exact prefix of actual response bytes')
            deadline=time.monotonic()+3
            while not record.get('cancelled') and time.monotonic()<deadline: time.sleep(.01)
            self.assertTrue(record.get('cancelled'),'Stopping the helper must close the gateway HTTP stream')
            for queued in cancelled['queue']:
                self.peer.command('queue.remove',{'turnId':queued['turnId']},session)
            self.peer.command('session.close',session=session)
    def test_strict_gateway_rejects_mutated_outgoing_requests_and_wrong_tool_results(self):
        for api in ['openai-responses']:
            session='strict-negative-'+api; self.strict_open(api,session); self.submit(session,'fixture: read README.md'); self.assertEqual(self.settled(session)['state'],'idle')
            attempt=self.peer.command('debug.list',session=session)['attempts'][0]
            sent=self.captured_body(session,attempt,'request'); record=next(r for r in reversed(Fixture.requests) if r['body']==sent)
            route=record['path']; headers={k:v for k,v in record['headers'].items() if k.lower() not in ('content-length','host','connection')}
            changes=[('stream',lambda b:b.update(stream=False)),('model',lambda b:b.update(model='strict-unknown')),
                     ('limit',lambda b:b.update({('max_output_tokens' if api=='openai-responses' else 'max_tokens'):0})),
                     ('schema',lambda b:b['tools'][0].update({('parameters' if api=='openai-responses' else 'input_schema'):{'type':'object','required':['missing'],'properties':{}}}))]
            if api=='openai-responses':
                changes += [('result-id',lambda b:b['input'][-1].update(call_id='invented-id')),('result-content',lambda b:b['input'][-1].update(output='made-up-result')),
                            ('native-replay',lambda b:b['input'].insert(0,{'type':'reasoning','encrypted_content':'must-not-replay'}))]
            else:
                changes += [('result-id',lambda b:b['messages'][-1]['content'][0].update(tool_use_id='invented-id')),('result-content',lambda b:b['messages'][-1]['content'][0].update(content='made-up-result')),
                            ('native-replay',lambda b:b['messages'].insert(0,{'role':'assistant','content':[{'type':'thinking','thinking':'x','signature':'must-not-replay'}]}))]
            probes=[]
            for name, mutate in changes:
                changed=json.loads(sent); mutate(changed); probes.append((name,route,headers,encoded(changed)))
            probes.append(('auth',route,{**headers,'Authorization':'Bearer wrong-fixture-key'},sent))
            probes.append(('custom-header',route,{name:value for name,value in headers.items() if name.lower()!='x-fixture-contract'},sent))
            probes.append(('session-header',route,{name:value for name,value in headers.items() if name.lower()!='x-session-id'},sent))
            probes.append(('turn-header',route,{**headers,'x-turn-id':'bad turn\x7f'},sent))
            if api=='openai-responses':
                mismatched=json.loads(sent); mismatched['metadata']={'session_id':'another-session'}; probes.append(('metadata',route,headers,encoded(mismatched)))
            else:
                leaked=json.loads(sent); leaked['metadata']={'session_id':session}; probes.append(('metadata',route,headers,encoded(leaked)))
            probes.append(('route','/v1/chat/completions',headers,sent))
            probes.append(('invalid-json',route,headers,b'{'))
            for name,path,request_headers,payload in probes:
                with self.subTest(api=api,mutation=name):
                    connection=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=5)
                    connection.request('POST',path,body=payload,headers=request_headers); response=connection.getresponse(); rejection=json.loads(response.read()); connection.close()
                    self.assertEqual(response.status,422); self.assertEqual(rejection['error']['type'],'fixture_contract')
                    self.assertNotIn('fixture-secret',json.dumps(rejection),'Contract diagnostics must not log the auth key')
            connection=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=5)
            connection.request('GET',route,headers=headers); response=connection.getresponse(); response.read(); connection.close(); self.assertEqual(response.status,404)
            self.peer.command('session.close',session=session)
    def test_router_identity_preserves_aliases_and_distinguishes_unknown_conflict_and_deployment(self):
        contract = {'replayPolicy':'portable','reference':'Deterministic fixture contract v1', 'modelHeader':'x-fixture-actual-model', 'deploymentHeader':'x-fixture-deployment', 'groupHeader':'x-fixture-group'}
        for api in ['openai-responses']:
            for alias, state in [('route-changing','reported'),('route-echo','unreported'),('route-unknown','unreported'),('route-late','reported'),('route-conflict','conflict'),('route-json','reported')]:
                session = api + alias
                self.open(api,model=alias,session=session,routing=contract); self.submit(session)
                self.assertEqual(self.settled(session)['state'],'idle')
                first = self.peer.command('debug.list',session=session)['attempts'][0]
                identity = first['identity']; self.assertEqual(identity['status'],state)
                self.assertEqual(first['requestedModel'],alias)
                if state == 'reported': self.assertEqual(identity['effectiveModel'],'fixture-a')
                else: self.assertIsNone(identity['effectiveModel'])
                if alias != 'route-json': self.assertTrue(any(e['kind']=='deployment' and e['value']=='opaque-deployment-123' for e in identity['evidence']))
                if alias == 'route-conflict': self.assertEqual(identity['reportedModels'],['fixture-a','fixture-b'])
                if alias == 'route-changing':
                    self.submit(session,'second route'); self.assertEqual(self.settled(session)['state'],'idle')
                    attempts = self.peer.command('debug.list',session=session)['attempts']; self.assertEqual(len(attempts),2)
                    self.assertEqual(attempts[0]['identity']['effectiveModel'],'fixture-b')
                    request = json.loads(base64.b64decode(self.peer.command('debug.body',{'attemptId':attempts[0]['attemptId'],'body':'request'},session)['bytes']))
                    self.assertEqual(request['model'],alias)
                    self.assertNotIn('encrypted_content',json.dumps(request.get('input',request.get('messages'))), 'Explicit portable policy omits native reasoning on wire')
                self.peer.command('session.close',session=session)
    def test_responses_distinct_timing_boundaries_streaming_and_json(self):
        for api in ['openai-responses']:
            for model in ['timing','json']:
                session = api + model
                self.open(api, model=model, session=session); self.submit(session)
                self.assertEqual(self.settled(session)['state'],'idle')
                attempt = self.peer.command('debug.list',session=session)['attempts'][0]
                t, m = attempt['timings'], attempt['metrics']
                self.assertEqual(attempt['transportOutcome'],'eof')
                self.assertLessEqual(t['dispatch'],t['firstHTTPByte'])
                self.assertLessEqual(t['firstHTTPByte'],t['firstBodyByte'])
                self.assertLessEqual(t['firstBodyByte'],t['firstContent'])
                self.assertLessEqual(t['firstContent'],t['modelComplete'])
                # The last output token: never after the terminal event. One
                # delta (or a JSON body) is first and last at once, so it
                # spans nothing and has no decode rate.
                self.assertLessEqual(t['firstContent'],t['lastContent'])
                self.assertLessEqual(t['lastContent'],t['modelComplete'])
                self.assertEqual(t['lastContent'],t['firstContent'])
                self.assertIsNone(m['decodeTokensPerSecond'])
                # The stream duration is the span the rate divides by: first
                # output to last, never to the terminal event.
                self.assertAlmostEqual(m['streamDurationMs'],t['lastContent']-t['firstContent'])
                self.assertNotIn('outputTokensPerSecond',m)
                self.assertAlmostEqual(m['httpDurationMs'],t['httpEnd']-t['dispatch'])
                if model == 'timing':
                    self.assertGreater(t['httpEnd']-t['modelComplete'],100)
                    self.assertGreater(t['firstContent']-t['firstBodyByte'],40, 'Ping must not start TTFT')
                self.peer.command('session.close',session=session)
    def test_messages_is_not_advertised_and_rejected_before_http_dispatch(self):
        with Fixture.lock: before = len(Fixture.requests)
        self.assertIn('responses', self.peer.ready['capabilities'])
        self.assertNotIn('messages', self.peer.ready['capabilities'])
        failure = self.open('anthropic-messages',fail=True)
        self.assertEqual(failure['code'],'unsupported_api')
        self.peer.command('turn.submit',{'clientTurnId':str(uuid.uuid4()),'text':'must not dispatch'},'s',fail=True)
        with Fixture.lock: self.assertEqual(len(Fixture.requests),before)
        self.assertEqual(self.peer.command('debug.list',session='s')['total'],0)
    def test_responses_durable_capture_is_exact_for_tools_and_compaction(self):
        for api in ['openai-responses']:
            session = api
            self.open(api, model='tool', session=session)
            self.peer.command('debug.mode', {'mode':'persist'}, session)
            self.submit(session); first = self.settled(session); self.assertEqual(first['state'], 'idle')
            self.assertIn('fixture file contents', json.dumps(first['messages']))
            self.submit(session, 'long question'); self.assertEqual(self.settled(session)['state'], 'idle')
            self.peer.command('context.compact', session=session); self.assertEqual(self.settled(session)['state'], 'idle')
            attempts = self.peer.command('debug.list', session=session)['attempts']
            self.assertTrue(any(a['purpose']=='compaction' for a in attempts))
            with self.peer.capture_lock: packets = list(self.peer.captures)
            for attempt in attempts:
                ident = attempt['attemptId']; bodies = {}
                for kind in ['request', 'response']:
                    output = bytearray()
                    for packet in packets:
                        if packet.get('type')=='bytes' and packet.get('attemptId')==ident and packet.get('body')==kind:
                            chunk = base64.b64decode(packet['bytes']); self.assertLessEqual(len(chunk), 32768)
                            self.assertEqual(packet['offset'], len(output)); output.extend(chunk)
                    bodies[kind] = bytes(output)
                record = next(r for r in Fixture.requests if r['body']==bodies['request'])
                self.assertEqual(bodies['response'], record['response'])
                self.assertTrue(any(p.get('type')=='finish' and p['metadata']['attemptId']==ident for p in packets))
                indices = [event for p in packets if p.get('type')=='events' and p['attemptId']==ident for event in p['events']]
                self.assertGreater(len(indices), 0)
                for event in indices:
                    self.assertTrue(bodies['response'][event['start']:event['end']].startswith(b'data: '))
                self.assertTrue(any(p.get('type')=='links' and p['attemptId']==ident and p.get('messageIds') for p in packets))
                self.assertTrue(any(p.get('type')=='links' and p['attemptId']==ident and p.get('outputMessageIds') for p in packets))
            self.peer.command('session.close', session=session)
    def test_recorder_rejection_does_not_fail_or_replay_a_tool_turn(self):
        self.peer.reject_capture = True
        self.open(model='tool'); self.peer.command('debug.mode', {'mode':'persist'}, 's'); self.submit()
        self.assertEqual(self.settled()['state'], 'idle')
        attempts = self.peer.command('debug.list', session='s')['attempts']; self.assertEqual(len(attempts), 2)
        self.assertTrue(all(a['persistenceError'] for a in attempts))
    def test_http_error_and_incomplete_stream_are_not_completed(self):
        self.open(model='error');self.submit();value=self.settled();self.assertEqual(value['state'],'error')
        latest=self.peer.command('debug.list',session='s')['attempts'][0];self.assertEqual(latest['status'],400)
        self.assertEqual(latest['response']['state'],'complete'); self.assertEqual(latest['transportOutcome'],'eof')
        self.assertIsNone(latest['timings']['modelComplete']); self.assertIsNone(latest['metrics']['observedTTFTms'])
        self.peer.command('session.close',session='s')
        # A stream that ends without its terminal event ran no tool, so since
        # 0.1.85 it is retried like a dropped connection (this fixture cuts every
        # attempt). The cut attempt is never completed: its partial reply stays as
        # an interrupted row, and the attempt is not recorded as completed.
        self.open(model='incomplete',session='other');self.submit('other')
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            value=self.peer.command('session.snapshot',session='other')
            if value.get('retry'): break
            time.sleep(.02)
        self.assertEqual(value['retry']['attempt'],2); self.assertIn('terminal event',value['retry']['reason'])
        self.assertIn('partial',json.dumps(value['messages']))
        self.assertEqual([m['text'] for m in value['messages'] if m.get('stopReason')=='interrupted'],['partial'])
        cut=self.peer.command('debug.list',session='other')['attempts'][0]
        self.assertEqual(cut['outcome'],'failed'); self.assertEqual(cut['modelOutcome'],'interrupted')
        self.peer.command('turn.stop',session='other'); value=self.settled('other')
        self.assertEqual(value['state'],'paused'); self.assertIsNone(value['retry'])
    def test_cancellation_keeps_queued_message_paused(self):
        self.open(model='slow');self.submit();time.sleep(.1)
        self.submit(text='queued question');self.peer.command('turn.stop',session='s');value=self.settled()
        self.assertEqual(value['queueCount'],1);self.assertEqual(value['state'],'paused')
        self.assertEqual(value['runStatus'],'cancelled')
        attempt = self.peer.command('debug.list',session='s')['attempts'][0]
        self.assertEqual(attempt['transportOutcome'],'cancelled'); self.assertIsNotNone(attempt['timings']['httpEnd'])
        self.assertIsNone(attempt['timings']['modelComplete']); self.assertIsNone(attempt['metrics']['streamDurationMs'])
    def test_side_keep_and_resume(self):
        self.open();self.submit();self.settled()
        before = len(Fixture.requests)
        opened = self.peer.command('side.open',{'sideSessionId':'side'},'s')
        self.assertFalse(opened['ephemeral']); self.assertTrue(pathlib.Path(opened['path']).is_file())
        self.assertEqual(len(Fixture.requests), before, 'Opening an empty side must not send a message')
        self.submit('side','side question');self.settled('side')
        kept=self.peer.command('side.keep',session='side');self.assertTrue(kept['path'].endswith('side_side.jsonl'))
        parent=self.peer.command('session.snapshot',session='s');self.assertNotIn('side question',json.dumps(parent['messages']))
        closed=self.peer.command('side.close',session='side');self.assertEqual(closed['path'],kept['path'])
        self.peer.command('session.close',session='side');self.open(session='side',path=kept['path']);self.submit('side','after resume')
        self.assertEqual(self.settled('side')['state'],'idle')
    def test_side_request_extends_the_parents_cached_prefix(self):
        # Ours (pi has no side chats), as Codex's /side: the side's first request is
        # its parent's last one extended, so it joins the parent's prompt cache.
        before = len(Fixture.requests)
        self.open(model='billing-limit'); self.submit(text='parent question'); self.assertEqual(self.settled()['state'], 'idle')
        self.peer.command('side.open', {'sideSessionId': 'cache-side'}, 's')
        self.submit('cache-side', 'side question'); self.assertEqual(self.settled('cache-side')['state'], 'idle')
        def sent(session):
            with Fixture.lock:
                records = [({k.lower(): v for k, v in r['headers'].items()}, r['body']) for r in Fixture.requests[before:] if r['path'] == '/v1/responses']
            return [(headers, raw, json.loads(raw)) for headers, raw in records if headers.get('x-session-id') == session]
        parent, side = sent('s'), sent('cache-side')
        self.assertEqual((len(parent), len(side)), (1, 1))
        (parent_headers, parent_raw, parent_body), (side_headers, side_raw, side_body) = parent[-1], side[0]
        self.assertTrue(all(r.get('validated') for r in Fixture.requests[before:] if r['path'] == '/v1/responses'), 'every request met the contract')
        # Keys are sorted, so the tools close both bodies: byte-equal lists.
        self.assertEqual(side_raw[side_raw.rindex(b'"tools":'):], parent_raw[parent_raw.rindex(b'"tools":'):])
        self.assertEqual([t['name'] for t in side_body['tools']], ['read','ls','find','grep','write','edit','bash','mcp'])
        self.assertEqual(side_body['input'][:len(parent_body['input'])], parent_body['input'], 'same instructions, then the parent input')
        # Then the parent's reply, the hidden note as a user message, and the question.
        added = side_body['input'][len(parent_body['input']):]
        self.assertTrue(added[0]['role'] == 'assistant' and all(item.get('role') != 'user' for item in added[:-2]), added)
        note = added[-2]
        self.assertEqual(note['role'], 'user'); self.assertTrue(note['content'][0]['text'].startswith('This is a side conversation'))
        self.assertEqual(side_body['input'][-1]['content'][0]['text'], 'side question')
        self.assertEqual(side_body['prompt_cache_key'], parent_body['prompt_cache_key'])
        self.assertEqual(parent_body['prompt_cache_key'], 's')
        self.assertEqual((side_headers['session_id'], side_headers['x-client-request-id']), ('s', 's'))
        self.assertEqual((side_headers['x-session-id'], side_body['metadata']['session_id']), ('cache-side', 'cache-side'))
        # The side's attempts and spend are its own.
        attempts = self.peer.command('debug.list', session='cache-side')['attempts']
        self.assertEqual([a['sessionId'] for a in attempts], ['cache-side'])
        self.assertEqual(len(self.peer.command('debug.list', session='s')['attempts']), 1)
        self.assertAlmostEqual(self.peer.command('session.status', session='cache-side')['cost']['spentUSD'], 0.0123)
        self.assertAlmostEqual(self.peer.command('session.status', session='s')['cost']['spentUSD'], 0.0123)
        snapshot = self.peer.command('session.snapshot', session='cache-side')
        self.assertNotIn('side conversation', json.dumps(snapshot['messages']), 'the note is never a row')
    def test_side_close_preserves_active_work_and_fork_has_independent_complete_context(self):
        before=len(Fixture.requests)
        self.open(model='slow')
        opened=self.peer.command('side.open',{'sideSessionId':'child'},'s')
        self.assertEqual(len(Fixture.requests),before,'Opening an empty side must not send a message')
        self.submit('child','side work continues after closing its panel')
        closed=self.peer.command('side.close',session='child')
        self.assertEqual(closed['path'],opened['path'])
        child=self.settled('child');self.assertEqual(child['state'],'idle')
        parent=self.peer.command('session.snapshot',session='s');self.assertEqual(parent['messages'],[])
        before=len(Fixture.requests)
        fork=self.peer.command('session.fork',{'forkSessionId':'independent'},'child')
        copied=self.peer.command('session.snapshot',session='independent')
        self.assertEqual(copied['messages'],child['messages']);self.assertEqual(copied['queueCount'],0)
        self.assertEqual(len(Fixture.requests),before)
        self.assertTrue(fork['path'].endswith('fork_independent.jsonl'))
        self.peer.command('session.close',session='independent')
        self.open(model='slow',session='independent',path=fork['path'])
        reloaded=self.peer.command('session.snapshot',session='independent')
        self.assertEqual(reloaded['messages'],child['messages'])
    def test_mcp_stdio_and_http_schema_batch_single_invocation(self):
        self.open()
        self.peer.command('mcp.configure',{'config':{'servers':{'stdio':{'command':sys.executable,'args':[str(ROOT/'fixtures/native/mcp-server.py')]},'http':{'url':self.base+'/mcp'}}}})
        servers=self.peer.command('mcp.list')['servers'];self.assertEqual(len(servers),2)
        listed=self.peer.command('mcp.list',{'server':'stdio'})['tools'];self.assertNotIn('inputSchema',listed[0])
        schemas=self.peer.command('mcp.describe',{'targets':[{'server':'stdio','tool':'echo'},{'server':'http','tool':'echo'}]})
        self.assertEqual(len(schemas['tools']),2)
        for server in ('stdio','http'):
            result=self.peer.command('mcp.invoke',{'server':server,'tool':'echo','arguments':{'text':server}},'s')
            self.assertEqual(result['content'][0]['text'],server)
        self.peer.command('mcp.invoke',{'targets':[]},'s',fail=True)
    def test_http_mcp_consumes_multiple_json_and_sse_ingress_batches(self):
        self.open()
        for mode in ('json', 'sse'):
            self.peer.command('mcp.configure',{'config':{'servers':{'large':{'url':self.base+'/mcp','headers':{'X-Fixture-MCP-Mode':mode}}}}})
            schemas=self.peer.command('mcp.describe',{'targets':[{'server':'large','tool':'echo'}]})
            self.assertEqual(len(schemas['tools']),1)
            result=self.peer.command('mcp.invoke',{'server':'large','tool':'echo','arguments':{'text':mode}},'s')
            self.assertEqual(result['content'][0]['text'],mode)

    def test_command_identity_is_not_replayed(self):
        self.open();params={'clientTurnId':'turn','text':'once'}
        first=self.peer.command('turn.submit',params,'s',command_id='same');second=self.peer.command('turn.submit',params,'s',command_id='same');self.assertEqual(first,second)
        self.settled();self.assertEqual(len(self.peer.command('debug.list',session='s')['attempts']),1)
        self.peer.command('turn.submit',{'clientTurnId':'other','text':'changed'},'s',command_id='same',fail=True)
    def test_connection_test_exposes_no_tools(self):
        self.open(connectionTest=True);self.submit();self.settled()
        attempt=self.peer.command('debug.list',session='s')['attempts'][0]
        request=self.peer.command('debug.body',{'attemptId':attempt['attemptId'],'body':'request'},'s')
        self.assertNotIn('tools',json.loads(base64.b64decode(request['bytes'])))

if __name__=='__main__':
    if '--serve' in sys.argv:
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        print(json.dumps({'port': server.server_port}), flush=True)
        server.serve_forever()
    else:
        unittest.main(verbosity=2)
