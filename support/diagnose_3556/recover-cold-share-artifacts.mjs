// One same-session recovery command. Credentials arrive as JSON on stdin; never in argv.
// Required argv pairs: --receipt PATH --receipt-sha256 HASH --metadata PRIVATE_PATH --output NEW_DIRECTORY.
// Optional: --socks5 100.108.223.54:38471 permits one HTTP-418 retry through that SOCKS5 endpoint.
// The original cloud receipt's absolute deadline is authoritative; there is no duration/deadline override.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,existsSync,chmodSync,statSync,openSync,readSync,closeSync,createReadStream} from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';

const options={};
for(let i=2;i<process.argv.length;i+=2){const key=process.argv[i],value=process.argv[i+1];
 assert(['--receipt','--receipt-sha256','--metadata','--output','--socks5'].includes(key)&&value&&!options[key],'Unsupported, missing, or duplicate recovery argument');options[key]=value;}
for(const key of ['--receipt','--receipt-sha256','--metadata','--output'])assert(options[key],'Required recovery argument missing: '+key);
assert(!options['--socks5']||options['--socks5']==='100.108.223.54:38471','Unadmitted SOCKS5 endpoint');
const originalBytes=readFileSync(options['--receipt']),originalSha=createHash('sha256').update(originalBytes).digest('hex');
assert(originalSha===options['--receipt-sha256'],'Immutable original cloud retention receipt hash differs');
const original=JSON.parse(originalBytes.toString()),session=original.session,deadline=Date.parse(original.deadlineUtc);
const stateObservation=original.stateObservationOnly===true,artifactFields=['video_url','device_logs_url','appium_logs_url',...(stateObservation?['logs']:[])];
assert(typeof session==='string'&&/^[a-f0-9]{32,64}$/.test(session)&&Number.isFinite(deadline),'Original cloud receipt session/deadline unavailable');
const output=path.resolve(options['--output']);assert(!existsSync(output),'Recovery output must be a new directory; existing/late artifacts are never overwritten');mkdirSync(output,{mode:0o700});
const receipt={status:'incomplete',session,originalReceiptSha256:originalSha,deadlineUtc:original.deadlineUtc,startedUtc:new Date().toISOString(),attempts:[],
 scope:'Original same-session artifact recovery only; retained candidates do not establish decode, onset coverage, or ANR absence',
 privacy:'Raw metadata, bodies, headers, and curl errors are private files; references and credentials are never printed'};
const receiptPath=path.join(output,'recovery-receipt.json');
const save=()=>writeFileSync(receiptPath,JSON.stringify(receipt,null,2),{mode:0o600});save();
const apiHosts=new Set(['api.browserstack.com','api-cloud.browserstack.com']);
const checked=(value,field)=>{const u=new URL(value);assert(u.protocol==='https:'&&!u.username&&!u.password&&(!u.port||u.port==='443'),'Recovery reference must use admitted HTTPS');
 if(field==='metadata')assert(u.hostname==='api-cloud.browserstack.com'&&u.pathname==='/app-automate/sessions/'+session+'.json'&&!u.search,'Metadata is not the exact owned session endpoint');
 else assert(apiHosts.has(u.hostname)||u.hostname==='app-automate.browserstack.com','Recovery artifact origin outside source allowlist');return u;};
const quote=value=>{assert(!/[\r\n\0]/.test(value),'Invalid curl config value');return '"'+value.replace(/\\/g,'\\\\').replace(/"/g,'\\"')+'"';};
const safeError=error=>String(error.message||error).replace(/https?:\/\/\S+/g,'[private artifact URL]').replace(/bs:\/\/\S+/g,'[private app reference]');
const hashFile=async(file)=>{const hash=createHash('sha256');for await(const chunk of createReadStream(file))hash.update(chunk);return hash.digest('hex');};
let credentials,metadata,sequence=0;

// This is the only provider-dispatch boundary: every curl hop/retry rechecks the immutable deadline here.
async function request(field,value,end,maxMs,cap,proxy=false){
 const url=checked(value,field),entry={field,sequence:++sequence,startedUtc:new Date().toISOString(),runnerMonotonicMs:performance.now(),status:'incomplete',
  origin:url.origin,transport:proxy?'admitted-SOCKS5':'direct'};receipt.attempts.push(entry);
 const prefix=field+'-'+entry.sequence,body=path.join(output,prefix+'.body.private'),headers=path.join(output,prefix+'.headers.private'),errors=path.join(output,prefix+'.errors.private');
 // Reserve empty private files before dispatch. No shell/queue contains credentials or signed references.
 for(const file of [body,headers,errors])writeFileSync(file,'',{flag:'wx',mode:0o600});
 entry.files={body:path.basename(body),headers:path.basename(headers),errors:path.basename(errors)};
 let config='url = '+quote(url.href)+'\n';
 const ownedTextLog=field==='logs'&&url.hostname==='app-automate.browserstack.com'&&
  new RegExp('^/builds/[a-f0-9]{40}/sessions/'+session+'/logs$').test(url.pathname);
 if(field==='metadata'||(field!=='video_url'&&apiHosts.has(url.hostname))||ownedTextLog)config+='user = '+quote(credentials.username+':'+credentials.key)+'\n';
 if(proxy)config+='proxy = '+quote('socks5h://'+options['--socks5'])+'\n';
 // Compute this immediately before spawn, after all config/filesystem preparation: queued callers cannot extend it.
 const dispatched=Date.now(),remaining=Math.floor(Math.min(end,deadline)-dispatched);
 if(remaining<=0){entry.status='not-dispatched-deadline-expired';entry.finishedUtc=new Date().toISOString();save();return {entry};}
 const timeoutMs=Math.min(maxMs,remaining);entry.dispatchedUtc=new Date(dispatched).toISOString();entry.remainingAggregateMs=deadline-dispatched;entry.timeoutMs=timeoutMs;
 entry.phaseDeadlineUtc=new Date(end).toISOString();entry.requestDeadlineUtc=new Date(dispatched+timeoutMs).toISOString();
 const child=spawn(process.platform==='win32'?'curl.exe':'curl',['--disable','--silent','--show-error','--config','-','--max-time',String(timeoutMs/1000),
  '--max-filesize',String(cap),'--output',body,'--dump-header',headers,'--stderr',errors,'--write-out','%{http_code}'],{windowsHide:true,stdio:['pipe','pipe','pipe']});
 let statusText='',spawnError=null;child.stdout.on('data',chunk=>{statusText=(statusText+chunk.toString()).slice(-32);});child.stderr.resume();
 child.stdin.on('error',()=>{});child.stdin.end(config);
 const exit=await new Promise(resolve=>{const timer=setTimeout(()=>{entry.timeoutKilled=true;child.kill();},Math.max(1,Math.min(dispatched+timeoutMs,deadline)-Date.now()));
  child.once('error',error=>{spawnError=error;clearTimeout(timer);resolve(null);});child.once('close',code=>{clearTimeout(timer);resolve(code);});});
 const finished=Date.now();entry.finishedUtc=new Date(finished).toISOString();entry.finishedRunnerMonotonicMs=performance.now();
 entry.finishedAfterPhaseDeadline=finished>=end;entry.finishedAfterRequestDeadline=finished>=dispatched+timeoutMs;entry.finishedAfterOriginalDeadline=finished>=deadline;entry.exitCode=exit;
 if(spawnError)entry.error=safeError(spawnError);entry.httpStatus=Number(statusText.trim())||null;
 for(const file of [body,headers,errors])chmodSync(file,0o600);
 entry.bytes=statSync(body).size;entry.sha256=await hashFile(body);entry.headerSha256=await hashFile(headers);entry.errorSha256=await hashFile(errors);
 const rawHeaders=readFileSync(headers,'utf8'),blocks=rawHeaders.trim().split(/\r?\n\r?\n/),last=blocks[blocks.length-1]||'';
 const headerMap=Object.fromEntries(last.split(/\r?\n/).slice(1).filter(line=>line.includes(':')).map(line=>{const at=line.indexOf(':');return [line.slice(0,at).toLowerCase(),line.slice(at+1).trim()];}));
 entry.headers=Object.fromEntries(['content-type','content-length','date','etag','last-modified','retry-after'].filter(key=>headerMap[key]).map(key=>[key,headerMap[key]]));
 entry.status=entry.finishedAfterPhaseDeadline||entry.finishedAfterRequestDeadline||entry.finishedAfterOriginalDeadline?'late-unusable-response-retained':exit===0?'response-retained':'curl-failed-raw-response-retained';save();return {entry,body,location:headerMap.location};
}

async function artifact(field,end,maxMs,cap){
 let totalBytes=0,proxyUsed=false;
 for(let attempt=1;attempt<=3&&Date.now()<Math.min(end,deadline);attempt++){
  let url=metadata[field],proxy=false;const attemptEnd=Math.min(end,deadline,Date.now()+maxMs);
  if(!url){receipt.attempts.push({field,attempt,status:'reference-unavailable',utc:new Date().toISOString()});save();return false;}
  try{
   for(let hop=0;hop<=5;hop++){
    const result=await request(field,url,attemptEnd,maxMs,Math.max(1,cap-totalBytes),proxy),entry=result.entry;entry.attempt=attempt;entry.hop=hop;totalBytes+=entry.bytes||0;entry.totalArtifactBytes=totalBytes;save();
    if(!entry.dispatchedUtc)return false;
    if(entry.httpStatus===418&&options['--socks5']&&!proxyUsed){proxyUsed=true;proxy=true;hop--;continue;}
    if(entry.httpStatus>=300&&entry.httpStatus<400&&result.location){assert(hop<5,'Finite recovery redirect limit reached');url=checked(new URL(result.location,url).href,field).href;continue;}
    if(entry.exitCode!==0||entry.httpStatus!==200||!entry.bytes||totalBytes>cap||entry.finishedAfterPhaseDeadline||entry.finishedAfterRequestDeadline||entry.finishedAfterOriginalDeadline)break;
    const file=openSync(result.body,'r'),head=Buffer.alloc(32);let size;try{size=readSync(file,head,0,head.length,0);}finally{closeSync(file);}
    const contentType=entry.headers['content-type']||'',isMp4=/video\/mp4/i.test(contentType)&&size>=12&&head.subarray(4,8).toString()==='ftyp';
    const errorDocument=/xml|html/i.test(contentType)||/^\s*<(?:\?xml|html|Error)/i.test(head.subarray(0,size).toString());
    if(field==='video_url'?!isMp4:errorDocument){entry.status='unusable-response-retained';save();break;}
    entry.candidateCompletedUtc=new Date().toISOString();
    if(Date.now()>=Math.min(end,attemptEnd,deadline)){entry.status='late-unusable-response-retained';save();break;}
    entry.status='candidate-retained-pending-independent-audit';save();entry.candidateReceiptCompletedUtc=new Date().toISOString();
    if(Date.now()>=Math.min(end,attemptEnd,deadline)){entry.status='late-unusable-response-retained';save();break;}return true;
   }
  }catch(error){receipt.attempts.push({field,attempt,status:'recovery-unavailable',error:safeError(error),utc:new Date().toISOString()});save();}
  if(totalBytes>=cap)break;
 }
 receipt.attempts.push({field,status:'finite-recovery-exhausted-or-deadline-expired',utc:new Date().toISOString()});save();return false;
}

try{
 if(Date.now()>=deadline){receipt.status='original-deadline-expired-no-provider-request';process.exitCode=2;}
 else{
  assert(statSync(options['--metadata']).size<=1024*1024,'Private metadata file byte limit exceeded');let privateValue;
  try{privateValue=JSON.parse(readFileSync(options['--metadata'],'utf8'));}catch{throw Error('Private same-session metadata must be valid JSON');}metadata=privateValue.automation_session||privateValue;
  assert(metadata?.hashed_id===session,'Private metadata does not identify the exact original session');
  for(const field of artifactFields)if(metadata[field])checked(metadata[field],field);
  receipt.initialMetadataSessionValidated=true;
  const chunks=[];let bytes=0;for await(const chunk of process.stdin){bytes+=chunk.length;assert(bytes<=65536,'Credential stdin byte limit exceeded');chunks.push(chunk);}
  try{credentials=JSON.parse(Buffer.concat(chunks).toString());}catch{throw Error('Credential stdin must be valid JSON');}
  assert(typeof credentials.username==='string'&&credentials.username&&typeof credentials.key==='string'&&credentials.key,'Recovery credentials unavailable on stdin');
  // Reserve up to thirty seconds independently for each log, sharing short remaining budgets without extending them.
  const logCount=stateObservation?3:2,logReserve=Math.min(30000,Math.max(0,Math.floor((deadline-Date.now())/logCount))),
   videoEnd=deadline-logCount*logReserve,deviceEnd=deadline-(logCount-1)*logReserve,appiumEnd=deadline-(stateObservation?1:0)*logReserve;
  receipt.logReservationMsEach=logReserve;let meta;
  try{meta=await request('metadata','https://api-cloud.browserstack.com/app-automate/sessions/'+session+'.json',videoEnd,10000,1024*1024);}
  catch{receipt.metadataRefresh='unavailable-private-original-same-session-references-preserved';}
  const previousMetadata=metadata;let metadataPromoted=false;
  if(meta?.entry.exitCode===0&&meta.entry.httpStatus===200&&!meta.entry.finishedAfterPhaseDeadline&&!meta.entry.finishedAfterRequestDeadline&&!meta.entry.finishedAfterOriginalDeadline){
   try{const fresh=JSON.parse(readFileSync(meta.body,'utf8')).automation_session;assert(fresh?.hashed_id===session,'Fresh recovery metadata does not identify the exact original session');
    const candidate={...metadata};for(const field of artifactFields)if(fresh[field])candidate[field]=checked(fresh[field],field).href;
    receipt.metadataRefreshCompletedUtc=new Date().toISOString();assert(Date.now()<Math.min(videoEnd,deadline,Date.parse(meta.entry.requestDeadlineUtc)),'Fresh metadata validation completed late');metadata=candidate;metadataPromoted=true;
    receipt.metadataRefresh='same-session-validated';}catch{receipt.metadataRefresh='unavailable-private-original-same-session-references-preserved';}
  }else receipt.metadataRefresh='unavailable-private-original-same-session-references-preserved';save();
  receipt.metadataReceiptCompletedUtc=new Date().toISOString();
  if(metadataPromoted&&Date.now()>=Math.min(videoEnd,deadline,Date.parse(meta.entry.requestDeadlineUtc))){metadata=previousMetadata;receipt.metadataRefresh='late-unusable-private-original-same-session-references-preserved';save();}
  const video=await artifact('video_url',videoEnd,35000,1024*1024*1024);
  const device=await artifact('device_logs_url',deviceEnd,10000,100*1024*1024);
  const appium=await artifact('appium_logs_url',appiumEnd,10000,100*1024*1024);
  const text=stateObservation?await artifact('logs',deadline,10000,100*1024*1024):null;
  receipt.artifacts={video,device,appium,...(stateObservation?{text}: {})};receipt.status=video&&device&&appium&&(!stateObservation||text)?'candidates-retained-pending-independent-audit':'incomplete';
  if(receipt.status==='incomplete')process.exitCode=1;
 }
}catch(error){receipt.error=safeError(error);process.exitCode=1;}
finally{receipt.finishedUtc=new Date().toISOString();save();}
