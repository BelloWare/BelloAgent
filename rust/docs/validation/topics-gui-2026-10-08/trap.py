import http.server,json,pathlib,datetime
r=pathlib.Path('/workspace/shared/agent-topics-gui/evidence')
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self): self.record()
 def do_GET(self): self.record()
 def record(self):
  n=int(self.headers.get('Content-Length','0')); body=self.rfile.read(min(n,1048576))
  with (r/'requests.jsonl').open('a') as f: f.write(json.dumps({'time':datetime.datetime.now(datetime.timezone.utc).isoformat(),'method':self.command,'path':self.path,'body_bytes':len(body)})+'\n')
  self.send_response(503); self.end_headers(); self.wfile.write(b'Unexpected request: Topics validation must not send')
server=http.server.ThreadingHTTPServer(('127.0.0.1',47931),Handler)
(r/'listener-ready.json').write_text(json.dumps({'host':'127.0.0.1','port':47931,'started':datetime.datetime.now(datetime.timezone.utc).isoformat()}))
server.serve_forever()
