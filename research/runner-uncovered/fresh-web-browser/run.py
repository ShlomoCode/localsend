#!/usr/bin/env python3
import base64, http.server, json, os, pathlib, shutil, subprocess, tempfile, threading, time, urllib.parse, urllib.request
import websocket
ROOT=pathlib.Path(__file__).resolve().parent
OUT=ROOT/'runtime';OUT.mkdir(exist_ok=True)
I18N={'waiting':'Waiting','enterPin':'Enter PIN','invalidPin':'Invalid PIN','tooManyAttempts':'Too many attempts','rejected':'Rejected','uploadRejected':'Rejected','busy':'Busy','files':'Files','dropHint':'Drop files'}
CONTENT=b'hello from web fixture\n'
records=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def respond(self,status,body,ctype='application/json',extra=None):
  if not isinstance(body,bytes):body=body.encode()
  self.send_response(status);self.send_header('Content-Type',ctype);self.send_header('Content-Length',str(len(body)))
  for k,v in (extra or {}).items():self.send_header(k,v)
  self.end_headers();self.wfile.write(body)
 def do_GET(self):
  url=urllib.parse.urlparse(self.path);q=urllib.parse.parse_qs(url.query);records.append({'method':'GET','path':self.path})
  if url.path=='/':self.respond(200,self.server.html,'text/html; charset=utf-8')
  elif url.path=='/i18n.json':self.respond(200,json.dumps(I18N))
  elif url.path.endswith('/download'):
   if q.get('sessionId')==['test-session'] and q.get('fileId')==['text']:
    self.respond(200,CONTENT,'application/octet-stream',{'Content-Disposition':'attachment; filename="test.txt"'})
   else:self.respond(403,'{}')
  else:self.respond(404,'{}')
 def do_POST(self):
  url=urllib.parse.urlparse(self.path);q=urllib.parse.parse_qs(url.query);body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  records.append({'method':'POST','path':self.path,'body':body.decode(errors='replace')})
  if url.path.endswith('/prepare-download'):
   if q.get('pin')!=['123456']:self.respond(401,'{}');return
   self.respond(200,json.dumps({'sessionId':'test-session','files':{'text':{'fileName':'test.txt','size':len(CONTENT)}}}))
  elif url.path.endswith('/prepare-upload'):
   if q.get('pin')!=['123456']:self.respond(401,'{}');return
   self.respond(200,json.dumps({'sessionId':'test-session','files':{'0':'token'}}))
  elif url.path.endswith('/upload'):
   self.respond(200,'{}')
  else:self.respond(404,'{}')
class CDP:
 def __init__(self,url):self.ws=websocket.create_connection(url,timeout=6);self.i=0;self.events=[]
 def call(self,method,params=None):
  self.i+=1;id=self.i;self.ws.send(json.dumps({'id':id,'method':method,'params':params or {}}))
  while True:
   msg=json.loads(self.ws.recv())
   if msg.get('id')==id:
    if 'error' in msg:raise RuntimeError(msg['error'])
    return msg.get('result',{})
   self.events.append(msg)
   if msg.get('method')=='Page.javascriptDialogOpening':
    self.i+=1;self.ws.send(json.dumps({'id':self.i,'method':'Page.handleJavaScriptDialog','params':{'accept':True,'promptText':'123456'}}))
 def evaluate(self,expression):return self.call('Runtime.evaluate',{'expression':expression,'returnByValue':True,'awaitPromise':True})
def wait_for(fn,timeout=8):
 until=time.time()+timeout
 while time.time()<until:
  if fn():return True
  time.sleep(.1)
 return False
results=[]
for mode in ['download','upload']:
 for variant,blocked in [('before',True),('after',True),('before',False)]:
  name=f'{mode}-{variant}-'+('blocked' if blocked else 'control')
  profile=OUT/(name+'-profile');(profile/'Default').mkdir(parents=True,exist_ok=True)
  (profile/'Default'/'Preferences').write_text(json.dumps({'profile':{'default_content_setting_values':{'cookies':2 if blocked else 1}}}))
  records.clear();server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
  server.html=(ROOT/(variant+'-'+mode+'.html')).read_text();threading.Thread(target=server.serve_forever,daemon=True).start()
  proc=subprocess.Popen(['google-chrome','--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--no-first-run','--no-default-browser-check','--remote-allow-origins=*','--remote-debugging-port=0','--user-data-dir='+str(profile),'about:blank'],stdout=(OUT/(name+'.stdout')).open('w'),stderr=(OUT/(name+'.stderr')).open('w'))
  try:
   if not wait_for(lambda:(profile/'DevToolsActivePort').exists()):raise RuntimeError('Chrome did not start')
   port=(profile/'DevToolsActivePort').read_text().splitlines()[0]
   tabs=json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/json/list'))
   c=CDP(next(x['webSocketDebuggerUrl'] for x in tabs if x['type']=='page'))
   c.call('Page.enable');c.call('Runtime.enable');c.call('Network.enable')
   downloads=OUT/(name+'-downloads');downloads.mkdir(exist_ok=True)
   c.call('Page.setDownloadBehavior',{'behavior':'allow','downloadPath':str(downloads)})
   # Download uses prompted PIN; upload uses query PIN. Both exact scripts are served unchanged.
   url=f'http://127.0.0.1:{server.server_port}/'+('?pin=123456' if mode=='upload' else '')
   c.call('Page.navigate',{'url':url})
   wait_for(lambda:c.evaluate('document.readyState')['result'].get('value')=='complete')
   time.sleep(.4)
   storage=c.evaluate("(()=>{try { sessionStorage.getItem('probe'); return 'allowed'; } catch(e) { return e.name+': '+e.message; }})()")['result'].get('value')
   action=None
   if mode=='upload':
    selected=OUT/'selected.txt';selected.write_bytes(CONTENT)
    doc=c.call('DOM.getDocument');node=c.call('DOM.querySelector',{'nodeId':doc['root']['nodeId'],'selector':'#file-input'})
    c.call('DOM.setFileInputFiles',{'nodeId':node['nodeId'],'files':[str(selected)]})
    wait_for(lambda:any('/upload?' in x['path'] for x in records),2)
   else:
    wait_for(lambda:c.evaluate("!!document.querySelector('a.file-item')")['result'].get('value'),2)
    action=c.evaluate("(()=>{const a=document.querySelector('a.file-item');if(a){a.click();return a.href}return null})()")
    wait_for(lambda:(downloads/'test.txt').exists(),2)
   screenshot=c.call('Page.captureScreenshot');(OUT/(name+'.png')).write_bytes(base64.b64decode(screenshot['data']))
   status=c.evaluate("document.getElementById('status-text').innerText")['result'].get('value')
   download=(downloads/'test.txt').read_bytes().decode() if (downloads/'test.txt').exists() else None
   errors=[x['params']['exceptionDetails'] for x in c.events if x.get('method')=='Runtime.exceptionThrown']
   result={'case':name,'mode':mode,'variant':variant,'blocked':blocked,'native_storage':storage,'url':url,'requests':list(records),'runtime_exceptions':errors,'status':status,'download':download,'chrome_version':c.call('Browser.getVersion'),'screenshot':str(OUT/(name+'.png'))}
   results.append(result);print(json.dumps(result),flush=True)
   c.ws.close()
  finally:proc.terminate();proc.wait(timeout=10);server.shutdown()
(OUT/'results.json').write_text(json.dumps(results,indent=2))
for mode in ['download','upload']:
 before,after,control=[r for r in results if r['mode']==mode]
 assert before['native_storage'].startswith('SecurityError'),before
 assert after['native_storage'].startswith('SecurityError'),after
 assert control['native_storage']=='allowed',control
 assert before['runtime_exceptions'],before
 assert not after['runtime_exceptions'],after
 assert not control['runtime_exceptions'],control
 if mode=='download':
  assert not any('prepare-download' in r['path'] for r in before['requests'])
  assert after['download']==control['download']==CONTENT.decode()
 else:
  assert not any('prepare-upload' in r['path'] for r in before['requests'])
  uploads=lambda r:[x['body'] for x in r['requests'] if '/upload?' in x['path']]
  assert uploads(after)==uploads(control)==[CONTENT.decode()]
print('PASS: native storage blocking breaks exact pinned download and upload scripts; patched scripts complete actual HTTP transfers and PIN flow, matching unblocked controls.',flush=True)
