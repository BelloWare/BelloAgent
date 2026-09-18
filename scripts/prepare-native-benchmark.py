#!/usr/bin/env python3
"""Prepare isolated synthetic state; never touch the user's normal app database."""
import argparse, hashlib, json, sqlite3, uuid
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('directory',type=Path);p.add_argument('--port',type=int,default=51277);a=p.parse_args()
root=a.directory.resolve();root.mkdir(parents=True,exist_ok=False)
workspace=root/'workspace';workspace.mkdir();(root/'codex-home').mkdir();(root/'history').mkdir()
(workspace/'tiny.txt').write_text('Synthetic read-only benchmark file.\n')
models=root/'models.json'
routes=[('normal','fixture-model'),('fast','fixture-fast')]
models.write_text(json.dumps({'providers':{'litellm':{'api':'openai-responses','apiKey':'synthetic-fixture-only','baseUrl':f'http://127.0.0.1:{a.port}',
    'models':[{'id':model,'name':f'M5 {label} Responses','api':'openai-responses','reasoning':False,'input':['text','image'], 'contextWindow':2000000,'maxTokens':300000,'cost':{'input':0,'output':0,'cacheRead':0,'cacheWrite':0}}
              for label,model in routes]}}},indent=2)+'\n')
models_hash=hashlib.sha256(models.read_bytes()).hexdigest()
state=root/'state';state.mkdir();db=sqlite3.connect(state/'desktop.sqlite');db.execute('PRAGMA journal_mode=WAL');db.execute('PRAGMA synchronous=FULL')
db.execute('CREATE TABLE records(kind TEXT NOT NULL,id TEXT NOT NULL,value BLOB NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(kind,id))')
def put(kind,id,value,revision=1):db.execute('INSERT INTO records VALUES(?,?,?,?)',(kind,id,json.dumps(value).encode(),revision))
workspace_id=str(uuid.uuid4()).upper();put('workspace',workspace_id,{'id':workspace_id,'path':str(workspace),'trusted':True})
put('resources',workspace_id,{'codexHome':str(root/'codex-home')})
profiles={}
for label,model in routes:
    id=hashlib.sha256(f'{models}\0litellm\0{model}\0openai-responses'.encode()).hexdigest();profiles[label]=id
    put('profile',id,{'id':id,'revision':models_hash,'name':f'M5 fixture · {label} Responses','providerId':'litellm','modelId':model,'api':'openai-responses','baseUrl':f'http://127.0.0.1:{a.port}',
        'contextWindow':2000000,'maxOutputTokens':300000,'advancedJSON':json.dumps({'reasoning':False,'input':['text','image'],'thinkingLevel':'off',
        'source':{'modelsPath':str(models),'authPath':str(root/'auth.json'),'sha256':models_hash,'commandTrust':False}})})
lines=[]
for n in range(10000):
    role='user' if n%2==0 else 'assistant';message={'role':role,'timestamp':1,'content':[{'type':'text','text':f'Message {n:05d} · 🌍\n\n'+('A synthetic retained paragraph. '*4)}]}
    if role=='assistant':message.update(api='openai-responses',provider='openai-responses',model='fixture-model',stopReason='stop',usage={'input':100,'output':10,'cacheRead':0,'cacheWrite':0,'totalTokens':110,'cost':{'input':0,'output':0,'cacheRead':0,'cacheWrite':0,'total':0}})
    lines.append(json.dumps({'type':'message','id':f'e{n:06x}','parentId':f'e{n-1:06x}' if n else None,'timestamp':'2026-09-14T00:00:00.000Z','message':message},ensure_ascii=False)+'\n')
body=''.join(lines)
for n in range(100):
    id=str(uuid.uuid4()).upper();path=root/'history'/f'{n:03d}.jsonl'
    path.write_text(json.dumps({'type':'session','version':3,'id':id,'timestamp':'2026-09-14T00:00:00.000Z','cwd':str(workspace)})+'\n'+body)
    put('chat',id,{'id':id,'workspaceID':workspace_id,'title':f'History {n:03d} · 10000 messages','path':str(path),'profileID':profiles['normal'],'toolMode':'read-only','imported':True},100-n)
db.commit();db.close()
(state/'desktop.sqlite').chmod(0o600)
(root/'configuration.json').write_text(json.dumps({'workspaceID':workspace_id,'profiles':profiles,'port':a.port,'historyMessages':10000,'historicalChats':100,'historyBytesEach':len(body.encode()),'stateRoot':str(state)},indent=2)+'\n')
print(json.dumps({'stateRoot':str(state),'historyBytesEach':len(body.encode()),'historicalChats':100,'output':str(root/'native-timings.json')},indent=2))
