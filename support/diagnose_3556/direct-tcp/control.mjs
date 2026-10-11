import assert from 'node:assert/strict';
import {readFileSync, mkdirSync, writeFileSync, appendFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {createServer as httpServer} from 'node:http';
import {createServer as tcpServer} from 'node:net';
import {createHash} from 'node:crypto';

// Run only inside the explicitly owned fork Actions job. Never retries session creation.
assert.equal(process.env.GITHUB_REPOSITORY, 'ShlomoCode/localsend');
assert.equal(process.env.GITHUB_ACTIONS, 'true');
for (const key of ['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','TCP_TOKEN','TCP_MARKER','TCP_HELPER_APK','BS_LOCAL_ID','BS_LOCAL_BINARY']) assert(process.env[key], key);
const env = process.env, output = 'evidence/direct-tcp'; mkdirSync(output,{recursive:true});
const auth = 'Basic '+Buffer.from(env.BROWSERSTACK_USERNAME+':'+env.BROWSERSTACK_ACCESS_KEY).toString('base64');
const secrets = [env.BROWSERSTACK_USERNAME,env.BROWSERSTACK_ACCESS_KEY,env.TCP_TOKEN,auth];
const redact = value => secrets.reduce((text, secret) => text.replaceAll(secret,'[redacted]'),String(value));
const save = (name,value) => writeFileSync(output+'/'+name,redact(typeof value==='string'?value:JSON.stringify(value,null,2)));
const trace = value => appendFileSync(output+'/trace.jsonl',redact(JSON.stringify({utc:new Date().toISOString(),...value}))+'\n');
const sleep = ms => new Promise(resolve=>setTimeout(resolve,ms));
const buildName = 'direct3556-'+env.GITHUB_RUN_ID+'-'+env.GITHUB_RUN_ATTEMPT;
const cases=[], sockets=new Set();
const expected = [0,1,65537].map(count=>{
 const bytes=Buffer.alloc(count);for(let i=0;i<count;i++)bytes[i]=(i*31+7)&255;
 return {count,sha256:createHash('sha256').update(bytes).digest('hex')};
});
const report={status:'preparing',startedUtc:new Date().toISOString(),hostname:'bs-local.com',httpPort:8080,tcpPort:53317,
 marker:env.TCP_MARKER,expected,runnerCases:cases,cleanupErrors:[],
 scope:'Synthetic native Socket reachability and byte/half-close/EOF control; no original app transfer',
 limitations:['Windows Server 2022 differs from reporter Windows 10','Physical Samsung S20 Android 10; reporter Android version unknown','A tiny pass establishes no sustained throughput or 16GB result']};
const http=httpServer((request,response)=>{
 if(request.url!=='/health'||request.headers.authorization!=='Bearer '+env.TCP_TOKEN){response.writeHead(403);response.end();return;}
 trace({event:'authenticated-http-health',remote:request.socket.remoteAddress});
 response.writeHead(200,{'content-type':'application/json','connection':'close'});response.end(JSON.stringify({marker:env.TCP_MARKER}));
});
http.requestTimeout=10000;http.headersTimeout=10000;http.setTimeout(10000);
const tcp=tcpServer({allowHalfOpen:true},socket=>{
 sockets.add(socket);const index=cases.length;
 const record={index,openedUtc:new Date().toISOString(),remote:socket.remoteAddress,count:0};cases.push(record);
 const hash=createHash('sha256'),deadline=setTimeout(()=>socket.destroy(new Error('Absolute TCP case deadline')),30000);
 trace({event:'tcp-connect',index,remote:socket.remoteAddress});socket.setTimeout(10000,()=>socket.destroy(new Error('TCP idle timeout')));
 socket.on('data',data=>{record.count+=data.length;hash.update(data);if(record.count>65537)socket.destroy(new Error('Unexpected extra bytes'));});
 socket.once('end',()=>{
  record.readableEof=true;record.eofUtc=new Date().toISOString();record.sha256=hash.digest('hex');
  record.byteExact=expected[index]?.count===record.count&&expected[index]?.sha256===record.sha256;
  trace({event:'tcp-readable-eof',...record});
  const reply=JSON.stringify({marker:env.TCP_MARKER,count:record.count,sha256:record.sha256});
  socket.write(reply,()=>{record.replyFlushedUtc=new Date().toISOString();trace({event:'tcp-reply-flushed',index});socket.end();record.outputHalfCloseRequested=true;});
 });
 socket.on('error',error=>{record.exceptionType=error.name;record.message=redact(error.message);trace({event:'tcp-error',...record});});
 socket.once('close',()=>{clearTimeout(deadline);sockets.delete(socket);record.closedUtc=new Date().toISOString();});
});
async function request(url,method='GET',body,timeout=30000){
 const response=await fetch(url,{method,headers:{authorization:auth,...(body instanceof FormData?{}:{'content-type':'application/json'})},
  body:body===undefined?undefined:body instanceof FormData?body:JSON.stringify(body),signal:AbortSignal.timeout(timeout)});
 const data=await response.json();
 if(!response.ok||data.value?.error){const error=Error('Provider '+response.status+' '+redact(data.value?.message||JSON.stringify(data)));error.status=response.status;throw error;}
 return data;
}
const api = path => 'https://api-cloud.browserstack.com/app-automate/'+path;
let session,local,creationAttempted=false;
const wd=async(method,path,body,attempt=0)=>{
 const started=Date.now();try{
  const data=await request('https://hub-cloud.browserstack.com/wd/hub'+path,method,body,path==='/session'?300000:30000);
  trace({event:'webdriver',method,path,elapsedMs:Date.now()-started});return data.value;
 }catch(error){
  trace({event:'webdriver-error',method,path,attempt,elapsedMs:Date.now()-started,error:redact(error.message)});
  if(method==='GET'&&error.status===404&&/Session not started or terminated/i.test(error.message)&&attempt<2){await sleep(1000);return wd(method,path,body,attempt+1);}
  throw error;
 }
};
const base=()=>'/session/'+session;
function decode(text){return text.replace(/&#x([0-9a-f]+);/gi,(_,n)=>String.fromCodePoint(parseInt(n,16))).replace(/&#(\d+);/g,(_,n)=>String.fromCodePoint(Number(n)))
 .replace(/&quot;/g,'"').replace(/&apos;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');}
// Attribute parser handles both Appium quote conventions and XML entities.
function attributes(xml){return [...xml.matchAll(/<[^/!?][^>]*>/g)].map(m=>Object.fromEntries([...m[0].matchAll(/([\w.:-]+)=(["'])(.*?)\2/g)].map(a=>[a[1],decode(a[3])])));}
async function snapshot(name,xml){save(name+'.xml',xml||await wd('GET',base()+'/source'));writeFileSync(output+'/'+name+'.png',Buffer.from(await wd('GET',base()+'/screenshot'),'base64'));}
async function recoverOwnedSession(){
 const deadline=Date.now()+120000;
 do {
  const builds=(await request(api('builds.json'))).map(b=>b.automation_build).filter(b=>b.name===buildName);
  assert(builds.length<=1,'Ambiguous owned build');
  if(builds.length){
   const owned=(await request(api('builds/'+builds[0].hashed_id+'/sessions.json'))).map(s=>s.automation_session);
   assert(owned.length<=1,'Ambiguous owned startup session');
   save('startup-recovery.json',{utc:new Date().toISOString(),sessions:owned.map(s=>({id:s.hashed_id,status:s.status}))});
   if(owned[0]?.status==='running'){session=owned[0].hashed_id;return;}
   if(owned[0]&&['done','failed','timeout','error'].includes(owned[0].status))return;
  }
  await sleep(10000);
 }while(Date.now()<deadline);
 report.cleanupErrors.push('Unknown session-create outcome: no running owned session found within bounded provider lookup; parent must inspect owned build '+buildName);
}
try{
 await new Promise((ok,no)=>{http.once('error',no);http.listen(8080,'0.0.0.0',ok);});
 await new Promise((ok,no)=>{tcp.once('error',no);tcp.listen(53317,'0.0.0.0',ok);});
 trace({event:'listeners-ready',http:'0.0.0.0:8080',tcp:'0.0.0.0:53317'});
 let localText='';local=spawn(env.BS_LOCAL_BINARY,['--key',env.BROWSERSTACK_ACCESS_KEY,'--local-identifier',env.BS_LOCAL_ID,'--force-local','--only-automate'],{windowsHide:true,stdio:['ignore','pipe','pipe']});
 local.on('error',error=>{localText+='\n'+error.message;});
 for(const stream of [local.stdout,local.stderr])stream.on('data',data=>{localText+=data.toString();save('local.log',localText);});
 const readyDeadline=Date.now()+120000;
 while(!/You can now access your local|Local Testing successfully connected|BrowserStackLocal is connected|Local connection established|Connected to BrowserStack/i.test(localText)){
  assert(local.exitCode===null,'Owned Local process exited before readiness');assert(Date.now()<readyDeadline,'Local readiness timeout');await sleep(500);
 }
 trace({event:'owned-local-ready',pid:local.pid,identifier:env.BS_LOCAL_ID});
 const form=new FormData();form.append('file',new Blob([readFileSync(env.TCP_HELPER_APK)]),'direct-tcp-helper.apk');
 const uploaded=await request(api('upload'),'POST',form,300000);assert(/^bs:\/\/[a-zA-Z0-9]+$/.test(uploaded.app_url),'Invalid private app reference');secrets.push(uploaded.app_url);
 const devices=await request(api('devices.json'));save('device-catalog.json',{utc:new Date().toISOString(),devices});
 assert(devices.some(d=>d.device==='Samsung Galaxy S20'&&String(d.os_version)==='10.0'&&d.real_mobile!==false),'Requested physical S20 Android 10 absent');
 const plan=await request(api('plan.json'));save('admission.json',{utc:new Date().toISOString(),plan});
 const allowed=Number(plan.parallel_sessions_max_allowed),running=Number(plan.parallel_sessions_running);
 assert(Number.isFinite(allowed)&&Number.isFinite(running)&&running<allowed,'No free provider session capacity');
 creationAttempted=true;
 const created=await request('https://hub-cloud.browserstack.com/wd/hub/session','POST',{capabilities:{alwaysMatch:{
  platformName:'Android','appium:automationName':'UiAutomator2','appium:deviceName':'Samsung Galaxy S20','appium:platformVersion':'10.0',
  'appium:app':uploaded.app_url,'appium:newCommandTimeout':120,'bstack:options':{local:true,localIdentifier:env.BS_LOCAL_ID,realMobile:true,
   projectName:'Issue 3556 native TCP',buildName,sessionName:'0-1-65537 direct TCP gate',idleTimeout:120}}}},300000);
 session=created.sessionId||created.value?.sessionId;assert(session,'Session ID absent');
 save('session.json',{id:session,capabilities:created.value?.capabilities||created.value});
 let xml=await wd('GET',base()+'/source');await snapshot('before',xml);
 const button=attributes(xml).find(n=>n['content-desc']==='Run direct TCP control'&&n.enabled==='true');
 assert(button,'Observed native start button absent');
 const bounds=button.bounds?.match(/^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/);assert(bounds,'Observed button bounds absent');
 const x=Math.round((Number(bounds[1])+Number(bounds[3]))/2),y=Math.round((Number(bounds[2])+Number(bounds[4]))/2);
 await wd('POST',base()+'/actions',{actions:[{type:'pointer',id:'finger',parameters:{pointerType:'touch'},actions:[
  {type:'pointerMove',duration:0,origin:'viewport',x,y},{type:'pointerDown',button:0},{type:'pause',duration:100},{type:'pointerUp',button:0}]}]});
 const end=Date.now()+180000;
 while(Date.now()<end){
  xml=await wd('GET',base()+'/source');const text=attributes(xml).flatMap(n=>[n.text||'',n['content-desc']||'']).find(t=>t.startsWith('DIRECT_TCP_RESULT\n'));
  if(text){report.android=JSON.parse(text.slice('DIRECT_TCP_RESULT\n'.length));break;}await sleep(1000);
 }
 await snapshot('after',xml);assert(report.android,'Native result not observed before deadline');save('android-result.json',report.android);
 assert.equal(report.android.status,'passed','Native control failed at '+report.android.failedPhase);
 assert.equal(cases.length,3,'Runner case count');
 for(let i=0;i<3;i++){
  assert.equal(report.android.cases[i].response.marker,env.TCP_MARKER);assert.equal(report.android.cases[i].response.count,expected[i].count);
  assert.equal(report.android.cases[i].response.sha256,expected[i].sha256);assert(report.android.cases[i].replyReadThroughEof&&report.android.cases[i].verified);
  assert(cases[i].byteExact&&cases[i].readableEof&&cases[i].replyFlushedUtc&&cases[i].outputHalfCloseRequested&&!cases[i].message);
 }
 report.status='passed';
}catch(error){report.status='failed';report.exceptionType=error.name;report.message=redact(error.message);process.exitCode=1;
 if(session){try{await snapshot('failure');}catch(e){report.snapshotError=redact(e.message);}}
}finally{
 if(!session&&creationAttempted){try{await recoverOwnedSession();}catch(e){report.cleanupErrors.push('startup lookup: '+redact(e.message));}}
 if(session){try{await wd('DELETE',base());trace({event:'owned-session-deleted',session});}catch(e){report.cleanupErrors.push('session DELETE: '+redact(e.message));}}
 if(local&&local.exitCode===null){
  local.kill();await Promise.race([new Promise(resolve=>local.once('exit',resolve)),sleep(10000)]);
  if(local.exitCode===null)report.cleanupErrors.push('Owned Local process did not exit within 10 seconds');else trace({event:'owned-local-exited',code:local.exitCode});
 }
 for(const socket of sockets)socket.destroy();http.closeAllConnections();
 await Promise.all([http,tcp].map(server=>new Promise(resolve=>server.close(()=>resolve()))));
 report.finishedUtc=new Date().toISOString();save('results.json',report);
 if(report.cleanupErrors.length)process.exitCode=1;
}
