import http from 'node:http';
import net from 'node:net';
import {randomBytes} from 'node:crypto';
import {writeFileSync} from 'node:fs';

export function relay({httpPort=8080,tcpPort=53318,reverseTargetPort=null,token=randomBytes(24).toString('hex'),transport='legacy',downlink='poll',peerAbsoluteTimeoutMs=15*60000}={}) {
  if(!['legacy','stream','coalesced'].includes(transport))throw new Error('Unknown diagnostic transport');
  if(!['poll','persistent'].includes(downlink))throw new Error('Unknown downlink mode');
  if(![15*60000,90*60000].includes(peerAbsoluteTimeoutMs))throw new Error('Invalid explicit logical peer limit');
  const peerDeadlines=new Map();
  const uploadProgressTimeoutMs=90000,uploadAbsoluteTimeoutMs=15*60000,binaryLimit=1024*1024;
  const activeUploads=new Map(),uploads=Object.create(null);
  const peers=new Map(); const events=[]; let waiter=null; let queued=0; let peak=0; let next=0,traceDropped=0;
  let persistent=null,streamNumber=0,stopping=false;
  const streamOwners=new Map(),streamHistory=[];
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
  const status=()=>({...metrics,transport,downlink,queued,peak,peers:peers.size,activeUploads:activeUploads.size,traceDropped,
    persistent:persistent?{id:persistent.id,established:persistent.established,blocked:persistent.blocked,...persistent.identity}:null,
    streamHistory:structuredClone(streamHistory),streamOwners:Object.fromEntries(streamOwners),peerDownlink:Object.fromEntries(streamOwners),activePeerIds:[...peers.keys()],
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
  function wake() {
    if(downlink==='persistent'){
      const stream=persistent;if(!stream||stream.ended||stream.blocked)return;
      while(events.length&&!stream.blocked){stream.blocked=!stream.res.write(JSON.stringify(dequeue())+'\n');}
      return;
    }
    if(waiter && events.length) {const w=waiter;waiter=null;clearTimeout(w.timer);w.res.end(JSON.stringify(dequeue()));}
  }
  function endPersistent(stream,origin,{code=null,diagnostic=false}={}){
    if(stream.ended)return;stream.ended=true;
    const physical=!diagnostic&&!stopping&&stream.established;
    const ids=[...streamOwners].filter(([,owner])=>owner===stream.id).map(([id])=>id);
    const evidence={id:stream.id,origin,code,physical,diagnostic:!physical,requiresMatchingDeviceOutcome:true,established:stream.established,elapsedMs:Number(process.hrtime.bigint()-started)/1e6,identity:stream.identity,ownedPeers:ids};
    streamHistory.push(evidence);record('persistent-downlink-ended',null,evidence);
    if(persistent===stream){persistent=null;events.length=0;queued=0;}
    for(const id of ids){const p=peers.get(id);if(p){record(physical?'physical-downlink-peer-error':'diagnostic-downlink-peer-error',id,{streamId:stream.id,origin,code});activeUploads.get(id)?.fail((physical?'Physical':'Diagnostic')+' downlink ended: '+origin);p.destroy(new Error((physical?'Physical':'Diagnostic')+' downlink ended: '+origin));}}
  }
  function enqueue(e,owner=streamOwners.get(e.id)) {
    if(downlink==='persistent'&&(!persistent||owner!==persistent.id)){record('retired-downlink-event',e.id,{kind:e.kind,owner});return;}
    events.push(e);queued+=e.bytes||0;peak=Math.max(peak,queued);
    if(downlink==='persistent'&&(queued>4*1024*1024||events.length>4096)){const stream=persistent;endPersistent(stream,'queue-bound',{diagnostic:true});stream.res.destroy();return;}
    if(queued>512*1024){for(const p of peers.values())p.pause();metrics.paused++;}wake();
  }
  function attach(p,id,source){
    if(downlink==='persistent'){
      if(!persistent?.established||persistent.ended||peers.size>=16){record('diagnostic-peer-rejected',id,{reason:'No established persistent downlink or owned peer bound'});p.destroy();return false;}
      streamOwners.set(id,persistent.id);
    }
    const owner=streamOwners.get(id);
    peers.set(id,p);metrics.opened++;
    const expiresAt=Date.now()+peerAbsoluteTimeoutMs;peerDeadlines.set(id,expiresAt);
    const lifetime=setTimeout(()=>{record('logical-peer-deadline',id);activeUploads.get(id)?.fail('Logical peer absolute deadline');p.destroy();},peerAbsoluteTimeoutMs);
    record(source+'-open',id);
    p.on('data',data=>{metrics.fromSender+=data.length;measureChunk('fromSender',data.length,id);enqueue({id,kind:'data',bytes:data.length,data:data.toString('base64')},owner);});
    p.on('end',()=>{record(source+'-eof',id);enqueue({id,kind:'eof'},owner);});
    p.on('error',e=>{record(source+'-error',id,{code:e.code||'SOCKET_ERROR'});enqueue({id,kind:'error',error:e.code||'SOCKET_ERROR'},owner);});
    p.on('close',()=>{clearTimeout(lifetime);peerDeadlines.delete(id);record(source+'-close',id);activeUploads.get(id)?.fail('Target socket closed during upload');peers.delete(id);streamOwners.delete(id);enqueue({id,kind:'close'},owner);});
    return true;
  }
  const tcp=net.createServer({allowHalfOpen:true},p=>{
    const id=String(++next);if(attach(p,id,'sender'))enqueue({id,kind:'open'});
  });
  const server=http.createServer((req,res)=>{
    if(req.headers.authorization!==`Bearer ${token}`){res.writeHead(401);res.end();return;}
    res.setHeader('content-type','application/json');
    if(req.method==='POST'&&req.url==='/downlink-retire'){
      let raw='';req.on('data',data=>{raw+=data;if(raw.length>4096)req.destroy();});
      req.on('end',()=>{try{const command=JSON.parse(raw);const stream=persistent;
        if(!stream||command.streamId!==stream.id||!['service-cleanup','diagnostic-opening','diagnostic-handler-failure','diagnostic-framing-failure','diagnostic-line-bound','diagnostic-batch-bound'].includes(command.reason)){res.writeHead(409);res.end('{}');return;}
        record('device-diagnostic-downlink-retire',null,{streamId:stream.id,reason:command.reason});endPersistent(stream,command.reason,{diagnostic:true});stream.res.end();res.end('{}');
      }catch{res.writeHead(400);res.end('{}');}});return;
    }
    if(req.method==='GET'&&req.url==='/downlink'){
      if(downlink!=='persistent'||persistent){res.writeHead(409);res.end('{}');return;}
      const socket=req.socket;
      const stream={id:String(++streamNumber),req,res,established:false,ended:false,blocked:false,identity:{localAddress:socket.localAddress,localPort:socket.localPort,remoteAddress:socket.remoteAddress,remotePort:socket.remotePort,openedUtc:new Date().toISOString()}};
      persistent=stream;
      // No idle timer, heartbeat or reconnect may manufacture a link-loss observation.
      socket.setTimeout(0);res.setTimeout(0);
      res.setHeader('content-type','application/x-ndjson');res.setHeader('cache-control','no-store');res.setHeader('x-accel-buffering','no');res.setHeader('x-relay-stream-id',stream.id);
      res.flushHeaders();stream.established=true;record('persistent-downlink-established',null,{streamId:stream.id,...stream.identity});
      stream.blocked=!res.write('[]\n');
      res.on('drain',()=>{stream.blocked=false;wake();});
      const ended=(origin,detail={})=>{record('persistent-native-event',null,{streamId:stream.id,origin,alreadyEnded:stream.ended,...detail});endPersistent(stream,origin,detail);};
      req.once('aborted',()=>ended('request-aborted'));
      req.once('error',error=>ended('request-error',{code:error.code||error.name}));
      res.once('error',error=>ended('response-error',{code:error.code||error.name}));
      res.once('close',()=>ended(res.writableFinished?'response-finished':'response-premature-close',{diagnostic:res.writableFinished}));
      socket.once('error',error=>ended('physical-socket-error',{code:error.code||error.name}));
      socket.once('close',hadError=>ended('physical-socket-close',{code:hadError?'had-error':null}));
      wake();return;
    }
    if(req.method==='GET' && req.url==='/pull') {
      if(downlink!=='poll'){res.writeHead(409);res.end('{}');return;}
      if(waiter){res.writeHead(409);res.end();return;}
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
            const p=net.connect({host:'127.0.0.1',port:reverseTargetPort,allowHalfOpen:true});if(!attach(p,e.id,'target')){res.writeHead(409);res.end('{}');return;}
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
    setDownlink:mode=>{if(!['poll','persistent'].includes(mode)||peers.size||activeUploads.size||persistent||waiter)throw new Error('Downlink change requires no live peers or requests');downlink=mode;record('downlink-mode',null,{mode});},
    setTransport:mode=>{if(!['legacy','stream','coalesced'].includes(mode)||peers.size||activeUploads.size)throw new Error('Transport change requires no live peers');transport=mode;record('transport-mode',null,{mode});},
    start:async()=>{if(!reverseTargetPort)await new Promise(r=>tcp.listen(tcpPort,'127.0.0.1',r));await new Promise(r=>server.listen(httpPort,'0.0.0.0',r));},
    stop:async()=>{stopping=true;record('relay-stop');if(persistent){const stream=persistent;endPersistent(stream,'relay-stop',{diagnostic:true});stream.res.end();}if(waiter){clearTimeout(waiter.timer);waiter.res.end('[]');waiter=null;}closePeers('Owned relay stopped');server.closeAllConnections();await Promise.all([new Promise(r=>server.close(r)),...(reverseTargetPort?[]:[new Promise(r=>tcp.close(r))])]);}};
}

if(process.argv[1]?.endsWith('/relay.mjs')) {
  const token=process.env.RELAY_TOKEN;if(!token)throw new Error('RELAY_TOKEN required');
  const r=relay({token,reverseTargetPort:process.env.REVERSE_TARGET_PORT?Number(process.env.REVERSE_TARGET_PORT):null,transport:process.env.RELAY_TRANSPORT||'legacy',downlink:process.env.RELAY_DOWNLINK||'poll'});await r.start();
  console.log('relay ready: HTTP8080 / sender TCP53318');
  const timer=setInterval(()=>{writeFileSync('relay-status.json',JSON.stringify(r.status()));writeFileSync('relay-trace.json',JSON.stringify(r.trace));},3000);
  process.on('SIGTERM',async()=>{clearInterval(timer);await r.stop();process.exit();});
}
