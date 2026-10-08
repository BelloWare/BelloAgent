import json, threading, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=Path(__file__).parent
lock=threading.Lock(); count=0
class Handler(BaseHTTPRequestHandler):
 def do_POST(self):
  global count
  size=int(self.headers.get('Content-Length','0'))
  if self.path!='/v1/responses' or size>32*1024*1024:
   self.send_error(400);return
  request=json.loads(self.rfile.read(size))
  with lock: count+=1; number=count
  (root/f'evidence/request-{number}.json').write_text(json.dumps(request,indent=2))
  if number==1:
   body={'id':'warmup-fixture','status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':'Synthetic verified progress. '*1800}]}],'usage':{'input_tokens':20,'output_tokens':12000}}
  elif number==2:
   body={'error':{'code':'context_length_exceeded','message':'Synthetic provider rejection: input exceeds the context window'},'usage':{'input_tokens':111}}
  elif number==3:
   (root/'evidence/summary-waiting').write_text('Actual summary request received; waiting for explicit fixture release.')
   deadline=time.monotonic()+180
   while not (root/'release-summary').exists() and time.monotonic()<deadline: time.sleep(.1)
   body={'id':'summary-fixture','status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':'Synthetic summary: objective and verified progress retained. Continue the user task.'}]}],'usage':{'input_tokens':100,'output_tokens':10}}
  elif number==4:
   body={'id':'retry-fixture','status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':'Synthetic fixture: original task continued after one summary and one retry. No real AI service was contacted.'}]}],'usage':{'input_tokens':50,'output_tokens':20}}
  else:
   body={'error':{'code':'fixture_unexpected_request','message':'More than one warmup and three recovery requests were observed'}}
  data=json.dumps(body).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.send_header('Connection','close');self.end_headers()
  try:self.wfile.write(data)
  except (BrokenPipeError,ConnectionResetError):pass
 def log_message(self,fmt,*args):print('fixture:',fmt%args,flush=True)
ThreadingHTTPServer(('127.0.0.1',47941),Handler).serve_forever()
