import http from 'node:http';
import net from 'node:net';
import {randomBytes} from 'node:crypto';
import {writeFileSync} from 'node:fs';

// Whitelist this diagnostic schema: never retain raw headers or unknown fields.
export function decodePublicObservation(header) {
  const bad=code=>{throw new Error(code);};
  if(typeof header!=='string'||header.length>10924||! /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(header))bad('observation-base64-invalid');
  const bytes=Buffer.from(header,'base64');if(bytes.length>8192||bytes.toString('base64')!==header)bad('observation-size-or-encoding-invalid');
  let s;try{s=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{bad('observation-json-invalid');}
  const object=v=>!!v&&typeof v==='object'&&!Array.isArray(v);
  const integer=(v,min=0)=>Number.isSafeInteger(v)&&v>=min;
  const string=(v,max=128)=>typeof v==='string'&&v.length>0&&v.length<=max;
  const bool=v=>typeof v==='boolean';
  if(!object(s)||s.schema!==1||!string(s.processNonce,36)||! /^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$/.test(s.processNonce)||!integer(s.sequence,1)||!integer(s.pid,1)||!integer(s.uid)||!integer(s.sampleStartNs,1)||!integer(s.sampleEndNs,s.sampleStartNs)||!integer(s.importance)||!['ordinary','foreground'].includes(s.serviceMode))bad('observation-envelope-invalid');
  const a=s.activity,b=s.activityBefore,v=s.service,m=s.memoryState;
  const validActivity=x=>object(x)&&integer(x.version,1)&&string(x.event,40)&&integer(x.elapsedNs)&&integer(x.started)&&integer(x.resumed)&&x.resumed<=x.started;
  if(!validActivity(a)||!validActivity(b)||!bool(s.activityStable)||!integer(s.emittedElapsedNs,s.sampleEndNs))bad('observation-activity-invalid');
  if(!object(m)||!integer(m.pid,1)||!integer(m.uid)||!integer(s.serviceMatches))bad('observation-identity-invalid');
  if(!object(v)||!string(v.component)||!integer(v.pid,1)||!integer(v.uid)||!bool(v.started)||!bool(v.foreground)||!integer(v.flags)||!bool(v.foregroundFlag)||!bool(v.startedFlag)||!integer(v.activeSinceMs))bad('observation-service-invalid');
  if(!integer(s.peerCountStart)||!integer(s.peerCountEnd)||s.peerSnapshotAtomic!==false||!Array.isArray(s.peers)||s.peers.length>32)bad('observation-peers-invalid');
  const peers=s.peers.map(p=>{
    if(!object(p)||!string(p.id,20)||! /^\d{1,20}$/.test(p.id)||!['closed','connected','inputShutdown','outputShutdown'].every(k=>bool(p[k]))||!['localAddress','remoteAddress'].every(k=>string(p[k],64)&&/^[0-9a-fA-F:.%]+$/.test(p[k]))||!['localPort','remotePort'].every(k=>integer(p[k])&&p[k]<=65535))bad('observation-peer-invalid');
    return Object.fromEntries(['id','closed','connected','inputShutdown','outputShutdown','localAddress','localPort','remoteAddress','remotePort'].map(k=>[k,p[k]]));
  });
  const activity=x=>({version:x.version,event:x.event,elapsedNs:x.elapsedNs,started:x.started,resumed:x.resumed});
  return {schema:1,processNonce:s.processNonce,sequence:s.sequence,sampleStartNs:s.sampleStartNs,sampleEndNs:s.sampleEndNs,emittedElapsedNs:s.emittedElapsedNs,pid:s.pid,uid:s.uid,importance:s.importance,serviceMode:s.serviceMode,activityStable:s.activityStable,serviceMatches:s.serviceMatches,memoryState:{pid:m.pid,uid:m.uid},activityBefore:activity(b),activity:activity(a),service:{component:v.component,pid:v.pid,uid:v.uid,started:v.started,foreground:v.foreground,flags:v.flags,foregroundFlag:v.foregroundFlag,startedFlag:v.startedFlag,activeSinceMs:v.activeSinceMs},peerCountStart:s.peerCountStart,peerCountEnd:s.peerCountEnd,peerSnapshotAtomic:false,peers};
}

export function relay({httpPort=8080,tcpPort=53318,token=randomBytes(24).toString('hex')}={}) {
  const peers=new Map(); const events=[]; let waiter=null; let queued=0; let peak=0; let next=0;
  const metrics={opened:0,fromSender:0,fromDevice:0,paused:0};
  const trace=[];const started=process.hrtime.bigint();
  function record(origin,id,detail={}){const now=process.hrtime.bigint();const event={utc:new Date().toISOString(),runnerMonotonicMs:Number(now)/1e6,elapsedMs:Number(now-started)/1e6,origin,id,...detail};trace.push(event);return event;}
  function respondPull(res,body,observation){const emitted=record('poll-response-emission',undefined,{observationSequence:observation?.sequence,processNonce:observation?.processNonce});res.once('finish',()=>record('poll-response',undefined,{observationSequence:observation?.sequence,processNonce:observation?.processNonce,responseEmissionMonotonicMs:emitted.runnerMonotonicMs,completionScope:'server-response-finish; subsequent sample proves helper advanced'}));res.end(body);}
  function dequeue() {
    const batch=[];
    while(events.length && batch.length<8) {
      const e=events.shift(); batch.push(e); queued-=e.bytes||0;
    }
    if(queued<256*1024) for(const p of peers.values()) p.resume();
    return batch;
  }
  function wake() {if(waiter && events.length) {const w=waiter;waiter=null;clearTimeout(w.timer);respondPull(w.res,JSON.stringify(dequeue()),w.observation);}}
  function enqueue(e) {events.push(e);queued+=e.bytes||0;peak=Math.max(peak,queued);if(queued>512*1024){for(const p of peers.values())p.pause();metrics.paused++;}wake();}
  const tcp=net.createServer({allowHalfOpen:true},p=>{
    const id=String(++next); peers.set(id,p);metrics.opened++;
    record('sender-open',id);
    enqueue({id,kind:'open'});
    p.on('data',data=>{metrics.fromSender+=data.length;enqueue({id,kind:'data',bytes:data.length,data:data.toString('base64')});});
    p.on('end',()=>{record('sender-eof',id);enqueue({id,kind:'eof'});});
    p.on('error',e=>{record('sender-error',id,{code:e.code||'SOCKET_ERROR'});enqueue({id,kind:'error',error:e.code||'SOCKET_ERROR'});});
    p.on('close',()=>{record('sender-close',id);peers.delete(id);enqueue({id,kind:'close'});});
  });
  const server=http.createServer((req,res)=>{
    if(req.headers.authorization!==`Bearer ${token}`){res.writeHead(401);res.end();return;}
    res.setHeader('content-type','application/json');
    if(req.method==='GET' && req.url==='/pull') {
      let observation;
      if(req.headers['x-cloudtransport-observation']!==undefined){
        try{observation=decodePublicObservation(req.headers['x-cloudtransport-observation']);record('public-observation',undefined,{observation});}
        catch(error){record('public-observation-error',undefined,{code:error.message.startsWith('observation-')?error.message:'observation-invalid'});}
      }
      record("poll-open");if(waiter){record("poll-conflict");res.writeHead(409);res.end();return;}
      if(events.length){respondPull(res,JSON.stringify(dequeue()),observation);return;}
      const w={res,observation,timer:setTimeout(()=>{record('poll-renewal');if(waiter===w)waiter=null;respondPull(res,'[]',observation);},15000)};
      waiter=w;res.on('close',()=>{record("poll-close");if(waiter===w){clearTimeout(w.timer);waiter=null;}});return;
    }
    if(req.method==='GET' && req.url==='/status'){res.end(JSON.stringify({...metrics,queued,peak,peers:peers.size,pollPending:!!waiter}));return;}
    if(req.method==='POST' && req.url==='/push') {
      let raw=''; req.on('data',d=>{raw+=d;if(raw.length>256*1024)req.destroy();});
      req.on('end',()=>{
        try {
          const e=JSON.parse(raw);const p=peers.get(e.id);
          if(!p){res.writeHead(410);res.end('{}');return;}
          if(e.kind==='data'){const data=Buffer.from(e.data,'base64');metrics.fromDevice+=data.length;p.write(data,()=>res.end('{}'));}
          else if(e.kind==='eof'){record('device-eof',e.id);p.end();res.end('{}');}
          else if(e.kind==='error'){record('device-error',e.id,{source:e.origin||'unspecified'});p.destroy(new Error('Device socket failed'));res.end('{}');}
          else {res.writeHead(400);res.end('{}');}
        }catch{res.writeHead(400);res.end('{}');}
      });return;
    }
    res.writeHead(404);res.end('{}');
  });
  return {token,metrics,trace,record,status:()=>({...metrics,queued,peak,peers:peers.size,pollPending:!!waiter}),
    start:async()=>{await new Promise(r=>tcp.listen(tcpPort,'127.0.0.1',r));await new Promise(r=>server.listen(httpPort,'0.0.0.0',r));},
    stop:async()=>{record('relay-stop');if(waiter){clearTimeout(waiter.timer);waiter.res.end('[]');waiter=null;}for(const [id,p] of peers){record('relay-stop-close',id);p.destroy();}server.closeAllConnections();await Promise.all([new Promise(r=>server.close(r)),new Promise(r=>tcp.close(r))]);}};
}

if(process.argv[1]?.endsWith('/relay.mjs')) {
  const token=process.env.RELAY_TOKEN;if(!token)throw new Error('RELAY_TOKEN required');
  const r=relay({token});await r.start();
  console.log('relay ready: HTTP8080 / sender TCP53318');
  const timer=setInterval(()=>{writeFileSync('relay-status.json',JSON.stringify(r.status()));writeFileSync('relay-trace.json',JSON.stringify(r.trace));},3000);
  process.on('SIGTERM',async()=>{clearInterval(timer);await r.stop();process.exit();});
}
