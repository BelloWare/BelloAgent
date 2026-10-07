#!/usr/bin/env python3
"""Disposable loopback fixture. Record booleans only, never credential text."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=47861)
parser.add_argument('--log', type=Path, required=True)
args = parser.parse_args()
log = args.log
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if self.path != '/v1/responses' or length > 1024 * 1024:
            self.send_error(400)
            return
        json.loads(self.rfile.read(length))
        with log.open('a') as out:
            out.write(json.dumps({'expected_fixture_key': self.headers.get('Authorization') == 'Bearer synthetic-project-fixture-only',
                'expected_fixture_header': self.headers.get('X-Fixture') == 'synthetic-header-fixture-only',
                'header_absent': self.headers.get('X-Fixture') is None}) + '\n')
        text = 'Local secure-input fixture response. No external or paid service was contacted.'
        events = [{'type':'response.output_text.delta','delta':text},
            {'type':'response.completed','response':{'status':'completed','output':[{'type':'message','status':'completed','role':'assistant','content':[{'type':'output_text','text':text}]}]}}]
        body = ''.join('data: '+json.dumps(event)+'\n\n' for event in events).encode()
        self.send_response(200)
        self.send_header('Content-Type','text/event-stream')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_): pass
ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
