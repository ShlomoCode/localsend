import assert from 'node:assert/strict';
import {mkdtempSync,rmSync,readFileSync,writeFileSync,createWriteStream,copyFileSync,openSync,readSync,closeSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {Readable,Transform} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import path from 'node:path';

const run=promisify(execFile),sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const authHosts=new Set(['api-cloud.browserstack.com','api.browserstack.com','app-automate.browserstack.com']);
function trusted(value) {
 const url=new URL(value);
 assert(url.protocol==='https:'&&!url.username&&!url.password&&(!url.port||url.port==='443'),'Unexpected provider artifact URL');
 const signedStorage=/^(?:[a-z0-9.-]+\.)?s3(?:[.-][a-z0-9-]+)?\.amazonaws\.com$/.test(url.hostname)&&url.searchParams.has('X-Amz-Signature');
 assert(authHosts.has(url.hostname)||signedStorage,'Unlisted provider artifact host');return url;
}
function prefix(file,size=65536) {
 const fd=openSync(file,'r');try{const bytes=Buffer.alloc(size),count=readSync(fd,bytes,0,size,0);return bytes.subarray(0,count);}finally{closeSync(fd);}
}
function validLog(bytes,contentType) {
 // Both retained provider endpoints returned text/plain; other MIME types remain unvalidated.
 const type=String(contentType||''),mime=type.split(';')[0].trim().toLowerCase();
 if(mime!=='text/plain')return false;
 const charset=type.match(/;\s*charset\s*=\s*"?([^;"\s]+)/i)?.[1];
 if(charset&&!/^utf-?8$/i.test(charset))return false;
 if(bytes.includes(0)||bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))||bytes.subarray(0,4).equals(Buffer.from([80,75,3,4])))return false;
 let text;try{text=new TextDecoder('utf-8',{fatal:true}).decode(bytes);}catch{return false;}
 if(/^\s*%PDF-/.test(text))return false;
 const body=text.trim();if(!body||/^\s*(?:<\?xml|<Error|<!doctype|<html)/i.test(body))return false;
 if(body.startsWith('{')){try{const json=JSON.parse(body);if(json.error||json.errors||json.value?.error||json.success===false||json.status==='error'||Number(json.status)>=400)return false;}catch{}}
 return true;
}

export async function retainProviderArtifacts({session,auth,output,privatePrefix,deadline,redact,save}) {
 assert(process.env.GITHUB_ACTIONS==='true'&&process.env.GITHUB_REPOSITORY==='ShlomoCode/localsend','Provider artifact workload runs only in admitted fork Actions');
 const safe=value=>redact(String(value)).replace(/https?:\/\/[^\s"'<>]+/g,'[artifact URL redacted]');
 const receipt={session,status:'retention-pending',artifacts:[],coverage:'Original frames and input/action alignment still require independent inspection'};
 const persist=()=>save('provider-recording-retention.json',receipt);
 async function get(url,end) {
  let current=trusted(url);
  for(let redirects=0;redirects<=5;redirects++) {
   assert(end-Date.now()>0,'Provider artifact deadline expired');
   const response=await fetch(current,{redirect:'manual',headers:authHosts.has(current.hostname)?{authorization:auth}:{},signal:AbortSignal.timeout(Math.max(1,end-Date.now()))});
   if(response.status>=300&&response.status<400) {
    await response.body?.cancel();assert(redirects<5&&response.headers.get('location'),'Invalid provider redirect');
    current=trusted(new URL(response.headers.get('location'),current).href);continue;
   }
   return {response,origin:current.origin,redirects};
  }
 }
 async function metadata() {
  const end=Math.min(deadline,Date.now()+10000);
  const {response}=await get('https://api-cloud.browserstack.com/app-automate/sessions/'+encodeURIComponent(session)+'.json',end);
  assert(response.ok,'Provider metadata HTTP '+response.status);
  const json=await response.json(),value=json.automation_session;
  assert(value?.hashed_id===session,'Provider metadata session identity mismatch');return value;
 }
 async function validateVideo(file,entry) {
  assert(deadline-Date.now()>=60000,'Full probe/decode reserve unavailable');
  const probe=await run('ffprobe',['-v','error','-show_format','-show_streams','-show_frames','-show_entries','format=format_name,duration:format_tags=major_brand:stream=codec_type,codec_name:frame=pts_time,best_effort_timestamp_time','-of','json',file],{timeout:30000,maxBuffer:16*1024*1024});
  const info=JSON.parse(probe.stdout);
  assert(String(info.format?.format_name||'').split(',').includes('mp4')&&String(info.format?.tags?.major_brand||'').trim()!=='qt'&&info.streams?.some(stream=>stream.codec_type==='video')&&info.frames?.some(frame=>frame.pts_time!==undefined||frame.best_effort_timestamp_time!==undefined),'Original MP4 stream/PTS unavailable');
  save('android-provider-original-probe.json',probe.stdout);
  assert(deadline-Date.now()>=30000,'Full decode reserve unavailable');
  const decode=await run('ffmpeg',['-v','error','-xerror','-i',file,'-map','0:v','-map','0:a?','-f','null','-'],{timeout:30000,maxBuffer:1024*1024});
  save('android-provider-original-decode.json',{exit:0,stdout:decode.stdout,stderr:decode.stderr});
  entry.validation={mp4Container:true,videoStream:true,framePts:true,fullDecode:true,durationSeconds:Number(info.format.duration)};
 }
 async function retain(field,name,maxBytes) {
  const entry={name,status:'incomplete',plaintextRedacted:field!=='video_url',generations:[]};receipt.artifacts.push(entry);persist();
  for(let attempt=0;attempt<3;attempt++) {
   const generation={attempt:attempt+1,startedUtc:new Date().toISOString(),rawBytes:0,rawSha256:null,retainedBytes:null,retainedSha256:null};entry.generations.push(generation);
   const hash=createHash('sha256');let directory;
   try {
    assert(deadline-Date.now()>10000,'Artifact retention reserve expired');
    const info=await metadata();assert(info[field],'Provider omitted artifact URL');
    const end=Math.min(deadline,Date.now()+30000),reply=await get(info[field],end);
    const response=reply.response;
    generation.status=response.status;generation.contentType=response.headers.get('content-type');generation.referenceOrigin=reply.origin;generation.redirects=reply.redirects;
    directory=mkdtempSync(path.join(process.env.RUNNER_TEMP,privatePrefix+'private-logs-'));
    const file=path.join(directory,'provider.response');
    const bounded=new Transform({transform(chunk,encoding,callback){
     if(generation.rawBytes+chunk.length>maxBytes){callback(Error('Provider artifact exceeds byte bound'));return;}
     generation.rawBytes+=chunk.length;hash.update(chunk);callback(null,chunk);
    }});
    assert(response.body,'Provider artifact body unavailable');
    await pipeline(Readable.fromWeb(response.body),bounded,createWriteStream(file,{mode:0o600}));
    generation.rawComplete=true;generation.rawSha256=hash.digest('hex');
    const head=prefix(file),mp4=head.length>=12&&head.toString('ascii',4,8)==='ftyp';
    generation.mp4Candidate=mp4;
    if(!response.ok||field==='video_url'&&!mp4||field!=='video_url'&&!validLog(readFileSync(file),generation.contentType)) {
     const failureName=name+'.attempt-'+(attempt+1)+'.invalid-response.txt';
     const retained=Buffer.from(safe(head.toString('utf8')),'utf8');writeFileSync(path.join(output,failureName),retained);
     generation.invalidBodyFile=failureName;generation.invalidBodyPrefixBytes=head.length;
     generation.invalidRetainedBytes=retained.length;generation.invalidRetainedSha256=createHash('sha256').update(retained).digest('hex');
     throw Error('Provider returned HTTP '+response.status+' with invalid '+(field==='video_url'?'MP4':'log')+' content');
    }
    if(field==='video_url') {
     assert(/^(video\/mp4|application\/octet-stream)(?:;|$)/i.test(generation.contentType||''),'Provider MP4 content type unavailable');
     await validateVideo(file,entry);copyFileSync(file,path.join(output,name));
     generation.retainedBytes=generation.rawBytes;generation.retainedSha256=generation.rawSha256;
    }else {
     const retained=Buffer.from(safe(readFileSync(file,'utf8')),'utf8');writeFileSync(path.join(output,name),retained);
     generation.retainedBytes=retained.length;generation.retainedSha256=createHash('sha256').update(retained).digest('hex');
    }
    generation.retainedUtc=new Date().toISOString();entry.status='retained';break;
   }catch(error) {
    if(!generation.rawSha256)generation.rawSha256=hash.digest('hex');generation.rawComplete??=false;
    generation.error=safe(error.message);
    // Failed candidates remain explicitly provisional, never named original.mp4.
    if(directory&&generation.mp4Candidate) {
     const candidate=name+'.attempt-'+(attempt+1)+'.unvalidated.mp4';copyFileSync(path.join(directory,'provider.response'),path.join(output,candidate));generation.unvalidatedCandidateFile=candidate;
    }
   }finally{if(directory)rmSync(directory,{recursive:true,force:true});persist();}
   if(attempt>=2||deadline-Date.now()<75000)break;
   await sleep(1000);
  }
 }
 // Independent downloads allow logs to survive unavailable/processing video within the same fixed clock.
 const results=await Promise.allSettled([retain('video_url','android-provider-original.mp4',300*1024*1024),retain('device_logs_url','android-provider-device.log',32*1024*1024),retain('appium_logs_url','android-provider-appium.log',32*1024*1024)]);
 receipt.unexpectedErrors=results.filter(result=>result.status==='rejected').map(result=>safe(result.reason?.message||result.reason));
 receipt.status=!receipt.unexpectedErrors.length&&receipt.artifacts.length===3&&receipt.artifacts.every(entry=>entry.status==='retained')?'original-video-decoded-and-redacted-logs-retained-frame-audit-required':'partial-retention';persist();return receipt;
}
