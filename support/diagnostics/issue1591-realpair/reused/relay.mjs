import http from 'node:http';
import net from 'node:net';
import {randomBytes} from 'node:crypto';
import {writeFileSync} from 'node:fs';

export function relay({httpPort=8080,tcpPort=53318,token=randomBytes(24).toString('hex'),senderNoDelay=false}={}) {
  const peers=new Map(); const events=[]; let waiter=null; let queued=0; let peak=0; let next=0;let nextSeq=0;let pendingBatch=null;
  const faults=[],peerBytes={};
  const metrics={opened:0,fromSender:0,fromDevice:0,paused:0};
  const trace=[];const started=process.hrtime.bigint();
  const healthSamples=[];let healthDropped=0;
  const elapsedMs=()=>Number(process.hrtime.bigint()-started)/1e6;
  const health=()=>({lastHealth:healthSamples.at(-1)||null,healthAgeMs:healthSamples.length?elapsedMs()-healthSamples.at(-1).receivedElapsedMs:null,
    healthGeneration:healthSamples.at(-1)?.payload.generation||null,healthSamples:healthSamples.length,healthDropped});
  const status=()=>({...metrics,queued,peak,peers:peers.size,pollPending:!!waiter,pendingAckSeq:pendingBatch?.at(-1)?.seq||null,peerBytes,faults,...health()});
  function fault(kind,detail={}){const entry={utc:new Date().toISOString(),elapsedMs:elapsedMs(),kind,...detail};faults.push(entry);record('transport-fault',undefined,entry);}
  function validHealth(value){
    return value&&Number.isInteger(value.pid)&&value.pid>0&&Number.isFinite(value.elapsedSeconds)&&value.elapsedSeconds>=0&&
      typeof value.generation==='string'&&value.generation.length>0&&value.generation.length<=128&&
      ['active','inactive','background'].includes(value.applicationState)&&typeof value.running==='boolean'&&
      (value.budgetState==='foreground-unbounded'&&value.remainingBudgetSeconds==null||value.budgetState==='finite'&&Number.isFinite(value.remainingBudgetSeconds)&&value.remainingBudgetSeconds>=0)&&
      Array.isArray(value.peers)&&value.peers.length<=128&&value.peers.every(peer=>peer&&typeof peer.id==='string'&&peer.id.length<=128&&
        typeof peer.ready==='boolean'&&Number.isSafeInteger(peer.toLocalSendBytes)&&peer.toLocalSendBytes>=0&&
        Number.isSafeInteger(peer.fromLocalSendBytes)&&peer.fromLocalSendBytes>=0&&typeof peer.inputEOF==='boolean'&&typeof peer.outputEOF==='boolean');
  }
  function record(origin,id,detail={}){trace.push({elapsedMs:Number(process.hrtime.bigint()-started)/1e6,origin,id,...detail});}
  const socketState=p=>({writableEnded:p.writableEnded,destroyed:p.destroyed,readableEnded:p.readableEnded});
  function batch() {pendingBatch=events.slice(0,8);return pendingBatch;}
  function wake() {if(waiter && events.length&&!pendingBatch) {const w=waiter;waiter=null;clearTimeout(w.timer);w.res.end(JSON.stringify(batch()));}}
  function enqueue(e) {events.push({...e,seq:++nextSeq});queued+=e.bytes||0;peak=Math.max(peak,queued);if(queued>512*1024){for(const p of peers.values())p.pause();metrics.paused++;}wake();}
  const tcp=net.createServer({allowHalfOpen:true},p=>{
    if(senderNoDelay)p.setNoDelay(true);
    const id=String(++next); peers.set(id,p);metrics.opened++;
    peerBytes[id]={fromSender:0,toSender:0,acknowledgedToDevice:0};
    record('sender-open',id,{senderNoDelay,policy:senderNoDelay?'setNoDelay(true)':'Node accepted socket default'});
    enqueue({id,kind:'open'});
    p.on('data',data=>{metrics.fromSender+=data.length;peerBytes[id].fromSender+=data.length;record('sender-data',id,{bytes:data.length,total:peerBytes[id].fromSender});enqueue({id,kind:'data',bytes:data.length,data:data.toString('base64')});});
    p.on('end',()=>{record('sender-eof',id,{utc:new Date().toISOString(),socketState:socketState(p)});enqueue({id,kind:'eof'});});
    p.on('error',e=>{fault('sender-socket-error',{id,code:e.code||'SOCKET_ERROR'});record('sender-error',id,{code:e.code||'SOCKET_ERROR'});enqueue({id,kind:'error',error:e.code||'SOCKET_ERROR'});});
    p.on('close',()=>{record('sender-close',id,{utc:new Date().toISOString(),socketState:socketState(p)});peers.delete(id);enqueue({id,kind:'close'});});
  });
  const server=http.createServer((req,res)=>{
    if(req.headers.authorization!==`Bearer ${token}`){res.writeHead(401);res.end();return;}
    res.setHeader('content-type','application/json');
    if(req.method==='GET' && req.url==='/pull') {
      record("poll-open");if(waiter){record("poll-conflict");res.writeHead(409);res.end();return;}
      if(pendingBatch){fault('poll-before-ack',{pendingSeq:pendingBatch.at(-1).seq});res.writeHead(409);res.end('{}');return;}
      if(events.length){res.end(JSON.stringify(batch()));return;}
      const w={res,timer:setTimeout(()=>{record('poll-renewal');if(waiter===w)waiter=null;res.end('[]');},15000)};
      waiter=w;res.on('close',()=>{record("poll-close");if(waiter===w){clearTimeout(w.timer);waiter=null;}});return;
    }
    if(req.method==='GET' && req.url==='/status'){res.end(JSON.stringify(status()));return;}
    if(req.method==='POST' && req.url==='/ack'){
      let raw='';req.on('data',data=>{raw+=data;if(raw.length>4096)req.destroy();});
      req.on('end',()=>{
        try{
          const ack=JSON.parse(raw);
          if(!pendingBatch||!Number.isSafeInteger(ack.seq)||ack.seq!==pendingBatch.at(-1).seq){fault('invalid-ack');res.writeHead(409);res.end('{}');return;}
          for(const event of pendingBatch){queued-=event.bytes||0;if(event.kind==='data')peerBytes[event.id].acknowledgedToDevice+=event.bytes;}
          events.splice(0,pendingBatch.length);record('device-batch-ack',undefined,{seq:ack.seq,count:pendingBatch.length});pendingBatch=null;
          if(queued<256*1024)for(const peer of peers.values())peer.resume();
          res.end('{}');wake();
        }catch{fault('invalid-ack');res.writeHead(400);res.end('{}');}
      });return;
    }
    if(req.method==='POST' && req.url==='/health'){
      let raw='';req.on('data',data=>{raw+=data;if(raw.length>64*1024)req.destroy();});
      req.on('end',()=>{
        try{
          const payload=JSON.parse(raw);
          if(!validHealth(payload)){res.writeHead(400);res.end('{}');record('invalid-health');return;}
          const sample={receivedUtc:new Date().toISOString(),receivedElapsedMs:elapsedMs(),payload};
          healthSamples.push(sample);if(healthSamples.length>1800){healthSamples.shift();healthDropped++;}
          record('helper-health',undefined,{pid:payload.pid,generation:payload.generation,applicationState:payload.applicationState});
          res.end('{}');
        }catch{res.writeHead(400);res.end('{}');record('invalid-health');}
      });return;
    }
    if(req.method==='POST' && req.url==='/push') {
      let raw=''; req.on('data',d=>{raw+=d;if(raw.length>256*1024)req.destroy();});
      req.on('end',()=>{
        try {
          const e=JSON.parse(raw);const p=peers.get(e.id);
          if(!p){fault('push-missing-peer',{id:e.id});res.writeHead(410);res.end('{}');return;}
          if(e.kind==='data'){const data=Buffer.from(e.data,'base64');
            const attempt={attemptedUtc:new Date().toISOString(),attemptedBytes:data.length,
              peerIdentity:{id:e.id,localAddress:p.localAddress,localPort:p.localPort,remoteAddress:p.remoteAddress,remotePort:p.remotePort},attemptState:socketState(p)};
            record('device-data-write-attempt',e.id,attempt);
            p.write(data,error=>{
            const result={...attempt,callbackUtc:new Date().toISOString(),callbackState:socketState(p),code:error?.code||null};
            record('device-data-write-result',e.id,result);
            if(error){fault('sender-write-error',{id:e.id,...result,code:error.code||'SOCKET_WRITE_ERROR'});res.writeHead(502);res.end('{}');return;}
            metrics.fromDevice+=data.length;peerBytes[e.id].toSender+=data.length;record('device-data-written',e.id,{bytes:data.length,total:peerBytes[e.id].toSender});res.end('{}');
          });}
          else if(e.kind==='eof'){record('device-eof',e.id);p.end();res.end('{}');}
          else if(e.kind==='error'){fault('device-socket-error',{id:e.id,source:e.origin||'unspecified'});record('device-error',e.id,{source:e.origin||'unspecified'});p.destroy(new Error('Device socket failed'));res.end('{}');}
          else {res.writeHead(400);res.end('{}');}
        }catch{res.writeHead(400);res.end('{}');}
      });return;
    }
    res.writeHead(404);res.end('{}');
  });
  return {token,metrics,trace,record,status,health,healthSamples,
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
