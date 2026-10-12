import http from 'node:http';
import net from 'node:net';
import {randomBytes} from 'node:crypto';
import {writeFileSync} from 'node:fs';

export function relay({httpPort=8080,tcpPort=53318,reverseTargetPort=null,token=randomBytes(24).toString('hex'),transport='legacy',peerAbsoluteTimeoutMs=15*60000}={}) {
  if(!['legacy','stream','coalesced'].includes(transport))throw new Error('Unknown diagnostic transport');
  if(![15*60000,90*60000].includes(peerAbsoluteTimeoutMs))throw new Error('Invalid explicit logical peer limit');
  const peerDeadlines=new Map();
  const uploadProgressTimeoutMs=90000,uploadAbsoluteTimeoutMs=15*60000,binaryLimit=1024*1024;
  const activeUploads=new Map(),uploads=Object.create(null);
  const peers=new Map(); const events=[]; let waiter=null; let queued=0; let peak=0; let next=0,traceDropped=0;
  const metrics={opened:0,fromSender:0,fromDevice:0,paused:0};
  const trace=[];const started=process.hrtime.bigint();
  const emptyChunks=()=>({count:0,bytes:0,min:null,max:0,firstElapsedMs:null,lastElapsedMs:null});
  const chunks={fromSender:emptyChunks(),fromDevice:emptyChunks()},peerChunks=Object.create(null);
  let measurement=null;
  function measureChunk(direction,length,id){
    const now=Number(process.hrtime.bigint()-started)/1e6;
    const peer=peerChunks[id]??={fromSender:emptyChunks(),fromDevice:emptyChunks()};
    const counters=[chunks[direction],peer[direction]];
    if(measurement){const measuredPeer=measurement.peerChunks[id]??={fromSender:emptyChunks(),fromDevice:emptyChunks()};counters.push(measurement.chunks[direction],measuredPeer[direction]);}
    for(const c of counters){c.count++;c.bytes+=length;c.min=c.min===null?length:Math.min(c.min,length);c.max=Math.max(c.max,length);c.firstElapsedMs??=now;c.lastElapsedMs=now;}
  }
  const status=()=>({...metrics,transport,queued,peak,peers:peers.size,activeUploads:activeUploads.size,pendingPull:waiter!==null,traceDropped,
    uploadLimits:{progressTimeoutMs:uploadProgressTimeoutMs,absoluteTimeoutMs:uploadAbsoluteTimeoutMs,binaryLimit,peerAbsoluteTimeoutMs},
    earliestPeerExpiryUtc:peerDeadlines.size?new Date(Math.min(...peerDeadlines.values())).toISOString():null,
    uploads:structuredClone(uploads),chunks:structuredClone(chunks),peerChunks:structuredClone(peerChunks),measurement:structuredClone(measurement)});
  function record(origin,id,detail={}){if(trace.length<4096)trace.push({elapsedMs:Number(process.hrtime.bigint()-started)/1e6,origin,id,...detail});else traceDropped++;}
  function dequeue() {
    const batch=[];
    while(events.length && batch.length<8) {
      const e=events.shift(); batch.push(e); queued-=e.bytes||0;
    }
    if(queued<256*1024) for(const p of peers.values()) p.resume();
    return batch;
  }
  function wake() {if(waiter && events.length) {const w=waiter;waiter=null;clearTimeout(w.timer);w.res.end(JSON.stringify(dequeue()));}}
  function enqueue(e) {events.push(e);queued+=e.bytes||0;peak=Math.max(peak,queued);if(queued>512*1024){for(const p of peers.values())p.pause();metrics.paused++;}wake();}
  function attach(p,id,source){
    peers.set(id,p);metrics.opened++;
    const expiresAt=Date.now()+peerAbsoluteTimeoutMs;peerDeadlines.set(id,expiresAt);
    const lifetime=setTimeout(()=>{record('logical-peer-deadline',id);activeUploads.get(id)?.fail('Logical peer absolute deadline');p.destroy();},peerAbsoluteTimeoutMs);
    record(source+'-open',id);
    p.on('data',data=>{metrics.fromSender+=data.length;measureChunk('fromSender',data.length,id);enqueue({id,kind:'data',bytes:data.length,data:data.toString('base64')});});
    p.on('end',()=>{record(source+'-eof',id);enqueue({id,kind:'eof'});});
    p.on('error',e=>{record(source+'-error',id,{code:e.code||'SOCKET_ERROR'});enqueue({id,kind:'error',error:e.code||'SOCKET_ERROR'});});
    p.on('close',()=>{clearTimeout(lifetime);peerDeadlines.delete(id);record(source+'-close',id);activeUploads.get(id)?.fail('Target socket closed during upload');peers.delete(id);enqueue({id,kind:'close'});});
  }
  const tcp=net.createServer({allowHalfOpen:true},p=>{
    const id=String(++next);attach(p,id,'sender');enqueue({id,kind:'open'});
  });
  const server=http.createServer((req,res)=>{
    if(req.headers.authorization!==`Bearer ${token}`){res.writeHead(401);res.end();return;}
    res.setHeader('content-type','application/json');
    if(req.method==='GET' && req.url==='/pull') {
      if(waiter){record('poll-conflict',null,{status:409});res.writeHead(409);res.end();return;}
      if(events.length){res.end(JSON.stringify(dequeue()));return;}
      const w={res,timer:setTimeout(()=>{record('poll-renewal');if(waiter===w)waiter=null;res.end('[]');},15000)};
      waiter=w;res.on('close',()=>{if(waiter===w){clearTimeout(w.timer);waiter=null;}});return;
    }
    if(req.method==='GET' && req.url==='/status'){res.end(JSON.stringify(status()));return;}
    const uploadRoute=req.url?.match(/^\/(upload|binary)\/([A-Za-z0-9_-]{1,40})$/);
    if(req.method==='POST' && uploadRoute){
      const [,route,id]=uploadRoute,p=peers.get(id),mode=route==='upload'?'stream':'coalesced';
      if(transport!==mode){res.writeHead(409);res.end('{}');return;}
      if(!p||p.destroyed||p.writableEnded){res.writeHead(410);res.end('{}');return;}
      if(activeUploads.has(id)||(mode==='stream'&&uploads[id]?.streamStarted)){res.writeHead(409);res.end('{}');return;}
      const length=Number(req.headers['content-length']);
      if(req.headers['content-type']!=='application/octet-stream'||(mode==='coalesced'&&(!Number.isInteger(length)||length<1||length>binaryLimit))){res.writeHead(400);res.end('{}');return;}
      const now=()=>Number(process.hrtime.bigint()-started)/1e6;
      const stats=uploads[id]??={mode,bytes:0,chunks:0,requests:0,completedRequests:0,paused:0,peakWritableLength:0,
        peakRequestReadableLength:0,socketWritableHighWaterMark:p.writableHighWaterMark,openedElapsedMs:now(),errors:[]};
      stats.requests++;stats.streamStarted ||= mode==='stream';stats.lastProgressElapsedMs=now();stats.requestEof=false;stats.responseFinished=false;
      if(mode==='stream')stats.streamStartedElapsedMs=now();
      stats.targetLocalPort=p.localPort;
      let settled=false,received=0;
      const clear=()=>{clearInterval(progress);clearTimeout(absolute);activeUploads.delete(id);req.unpipe(p);};
      const fail=message=>{
        if(settled)return;settled=true;stats.errors.push(message);stats.failedElapsedMs=now();record('upload-error',id,{mode,message});
        clear();if(!res.headersSent){res.writeHead(502);res.end('{}');}else res.destroy();req.destroy();p.destroy(new Error(message));
      };
      const progress=setInterval(()=>{if(now()-stats.lastProgressElapsedMs>=uploadProgressTimeoutMs)fail('Upload progress timeout');},1000);
      const absolute=setTimeout(()=>fail('Upload absolute deadline'),uploadAbsoluteTimeoutMs);
      activeUploads.set(id,{fail,req,res});record('upload-request-start',id,{mode,request:stats.requests});
      req.on('data',data=>{
        received+=data.length;stats.bytes+=data.length;stats.chunks++;stats.lastProgressElapsedMs=now();
        stats.peakWritableLength=Math.max(stats.peakWritableLength,p.writableLength+data.length);
        stats.peakRequestReadableLength=Math.max(stats.peakRequestReadableLength,req.readableLength);
        metrics.fromDevice+=data.length;measureChunk('fromDevice',data.length,id);
        if(mode==='coalesced'&&received>length)fail('Binary request exceeds declared bounded length');
      });
      req.on('pause',()=>{stats.paused++;if(stats.paused===1)record('upload-backpressure-first-pause',id,{mode,writableLength:p.writableLength,readableLength:req.readableLength});});
      req.once('aborted',()=>fail('Upload request aborted'));
      req.on('error',error=>fail('Upload request '+error.name));
      req.once('close',()=>{if(!req.complete)fail('Upload request closed before EOF');});
      req.once('end',()=>{
        if(settled)return;stats.requestEof=true;stats.requestEofElapsedMs=now();record('upload-request-eof',id,{mode,received});
        if(mode==='coalesced'&&received!==length){fail('Binary request length mismatch');return;}
        const flushed=()=>{
          if(settled)return;settled=true;clear();stats.completedRequests++;stats.responseFinished=true;stats.responseFinishedElapsedMs=now();
          record('upload-response-after-flush',id,{mode,received});res.end('{}');
        };
        // A coalesced request EOF is only a batch boundary; only a stream's true EOF maps to TCP FIN.
        if(mode==='stream'){record('device-eof',id,{mode});p.end(flushed);}else p.write(Buffer.alloc(0),flushed);
      });
      // Node pipe pauses IncomingMessage when this one target's writable buffer reaches its high-water mark.
      req.pipe(p,{end:false});return;
    }
    if(req.method==='POST' && req.url==='/push') {
      let raw=''; req.on('data',d=>{raw+=d;if(raw.length>256*1024)req.destroy();});
      req.on('end',()=>{
        try {
          const e=JSON.parse(raw);
          if(reverseTargetPort && e.kind==='open'){
            if(peers.has(e.id)||typeof e.id!=='string'||!/^[A-Za-z0-9_-]{1,40}$/.test(e.id)||peers.size>=16){res.writeHead(409);res.end('{}');return;}
            const p=net.connect({host:'127.0.0.1',port:reverseTargetPort,allowHalfOpen:true});attach(p,e.id,'target');
            p.once('connect',()=>{record('target-connected',e.id,{localPort:p.localPort,remotePort:p.remotePort});res.end('{}');});p.once('error',()=>{if(!res.writableEnded){res.writeHead(502);res.end('{}');}});return;
          }
          const p=peers.get(e.id);
          if(!p){res.writeHead(410);res.end('{}');return;}
          if(e.kind==='data'){if(transport!=='legacy'){res.writeHead(409);res.end('{}');return;}const data=Buffer.from(e.data,'base64');metrics.fromDevice+=data.length;measureChunk('fromDevice',data.length,e.id);p.write(data,()=>res.end('{}'));}
          else if(e.kind==='eof'){if(transport==='stream'){res.writeHead(409);res.end('{}');return;}record('device-eof',e.id);p.end();res.end('{}');}
          else if(e.kind==='error'){record('device-error',e.id,{source:e.origin||'unspecified'});p.destroy(new Error('Device socket failed'));res.end('{}');}
          else {res.writeHead(400);res.end('{}');}
        }catch{res.writeHead(400);res.end('{}');}
      });return;
    }
    res.writeHead(404);res.end('{}');
  });
  server.requestTimeout=uploadAbsoluteTimeoutMs;server.headersTimeout=10000;
  server.setTimeout(uploadProgressTimeoutMs+5000,socket=>socket.destroy());
  const closePeers=reason=>{record('owned-peer-reset',null,{reason});for(const [id,p] of peers){activeUploads.get(id)?.fail(reason);p.destroy();}};
  return {token,metrics,trace,record,status,
    setPeerLimit:milliseconds=>{if(![15*60000,90*60000].includes(milliseconds)||peers.size||activeUploads.size)throw new Error('Peer limit change requires empty owned peers');peerAbsoluteTimeoutMs=milliseconds;record('logical-peer-limit',null,{milliseconds});},
    beginMeasurement:label=>{measurement={label,startedElapsedMs:Number(process.hrtime.bigint()-started)/1e6,chunks:{fromSender:emptyChunks(),fromDevice:emptyChunks()},peerChunks:Object.create(null)};},
    closePeers,
    retireStoppedHelper:reason=>{
      if(peers.size||activeUploads.size)throw new Error('Stopped helper retirement requires empty owned peers and uploads');
      // A tunnel may retain the old HTTP poll after Android disconnects. Retire only at the observed stopped-helper boundary.
      const retired=waiter;waiter=null;
      if(retired){clearTimeout(retired.timer);retired.res.end('[]');}
      const discardedEvents=events.length;events.length=0;queued=0;
      record('stopped-helper-retired',null,{reason,endedPendingPull:retired!==null,discardedEvents});
    },
    setTransport:mode=>{if(!['legacy','stream','coalesced'].includes(mode)||peers.size||activeUploads.size)throw new Error('Transport change requires no live peers');transport=mode;record('transport-mode',null,{mode});},
    start:async()=>{if(!reverseTargetPort)await new Promise(r=>tcp.listen(tcpPort,'127.0.0.1',r));await new Promise(r=>server.listen(httpPort,'0.0.0.0',r));},
    stop:async()=>{record('relay-stop');if(waiter){clearTimeout(waiter.timer);waiter.res.end('[]');waiter=null;}closePeers('Owned relay stopped');server.closeAllConnections();await Promise.all([new Promise(r=>server.close(r)),...(reverseTargetPort?[]:[new Promise(r=>tcp.close(r))])]);}};
}

if(process.argv[1]?.endsWith('/relay.mjs')) {
  const token=process.env.RELAY_TOKEN;if(!token)throw new Error('RELAY_TOKEN required');
  const r=relay({token,reverseTargetPort:process.env.REVERSE_TARGET_PORT?Number(process.env.REVERSE_TARGET_PORT):null,transport:process.env.RELAY_TRANSPORT||'legacy'});await r.start();
  console.log('relay ready: HTTP8080 / sender TCP53318');
  const timer=setInterval(()=>{writeFileSync('relay-status.json',JSON.stringify(r.status()));writeFileSync('relay-trace.json',JSON.stringify(r.trace));},3000);
  process.on('SIGTERM',async()=>{clearInterval(timer);await r.stop();process.exit();});
}
