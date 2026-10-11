import net from 'node:net';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

// Paired with MainActivity's TC1 protocol. Every header, payload, challenge,
// acknowledgement and final reply participates in an exact byte/hash record.
const definitions={duplex:{seed:11,length:32768+65537},slow:{seed:29,length:8*1024*1024},
 cancel:{seed:43,length:65536},concurrent:{seed:61,length:1024*1024},sparse:{seed:79,length:13*64}};
function payload(seed,offset,length){
 const data=Buffer.alloc(length);for(let i=0;i<length;i++)data[i]=((offset+i)*31+seed)&255;return data;
}
function expected(name){
 const hash=createHash('sha256'),header=Buffer.from(`TC1 ${name}\n`),spec=definitions[name];hash.update(header);
 for(let offset=0;offset<spec.length;offset+=65536)hash.update(payload(spec.seed,offset,Math.min(65536,spec.length-offset)));
 return {count:header.length+spec.length,sha256:hash.digest('hex')};
}
function nativeResult(xml,labels){
 const value=labels(xml).find(v=>v.startsWith('TRANSPORT_CONTROLS_RESULT\n'));
 return value?JSON.parse(value.slice('TRANSPORT_CONTROLS_RESULT\n'.length)):null;
}

export async function runTransportControls({r,snap,click,waitFor,labels,save,sleep,output}) {
 const mode=r.status().transport,stem=`transport-controls-${mode}`;
 const report={status:'running',transport:mode,memoryBefore:process.memoryUsage(),scope:'Physical helper transport controls; LocalSend app is unchanged',
  protocol:'TC1 header plus deterministic payload; SHA-256 covers all bytes including frames',metricsBefore:r.status(),android:null,cases:[],trace:[]};
 const live=new Set();let server,timer,lastXml,serverFailure,cancelEntry,concurrentEntry;
 report.memoryPeak={...report.memoryBefore};
 const now=()=>Date.now();const trace=(event,detail={})=>report.trace.push({utc:new Date().toISOString(),event,...detail});
 const correlate=entry=>{
  const status=r.status();
  const found=Object.entries(status.uploads||{}).find(([,upload])=>upload.targetLocalPort===entry.remotePort);
  const connected=[...r.trace].reverse().find(e=>e.localPort===entry.remotePort&&e.id);
  entry.peerId=found?.[0]||connected?.id||entry.peerId;
  if(entry.peerId&&status.uploads?.[entry.peerId]){
   entry.upload=structuredClone(status.uploads[entry.peerId]);
   entry.uploadSamples??=[];
   // Bounded samples retain the entire 310 second span without logging payloads.
   if(!entry.closedMs&&entry.uploadSamples.length<600&&(!entry.lastSampleMs||now()-entry.lastSampleMs>=1000)){
    entry.uploadSamples.push({elapsedMs:now()-entry.openedMs,...entry.upload});entry.lastSampleMs=now();
   }
  }
 };
 function abort(entry,message){entry.failure=message;serverFailure??=new Error(message);entry.socket.destroy();}
 function send(entry,frame){const bytes=Buffer.from(frame);entry.responseHash.update(bytes);entry.responseCount+=bytes.length;entry.socket.write(bytes);}
 function finish(entry){
  if(entry.finalSent||entry.case==='cancel')return;
  if(entry.case==='concurrent'&&!cancelEntry?.cancelledByTarget)return;
  entry.finalSent=true;const reply=JSON.stringify({count:entry.count,sha256:entry.sha256})+'\n';
  send(entry,reply);entry.responseSha256=entry.responseHash.digest('hex');
  entry.socket.end(()=>{entry.replyFlushed=true;trace('reply-flushed',{case:entry.case,peerId:entry.peerId});});
 }
 function cancelWhenOverlapping(){
  if(!cancelEntry||!concurrentEntry||cancelEntry.cancelledByTarget||cancelEntry.bodyCount<65536)return;
  if(concurrentEntry.socket.destroyed)return abort(cancelEntry,'Concurrent peer closed before cancellation overlap');
  cancelEntry.cancelledByTarget=true;cancelEntry.overlappingPeer=concurrentEntry.peerId;cancelEntry.sha256=cancelEntry.hash.digest('hex');
  cancelEntry.responseSha256=cancelEntry.responseHash.digest('hex');
  trace('target-cancel-one-peer',{case:'cancel',peerId:cancelEntry.peerId,concurrentPeerId:concurrentEntry.peerId});
  cancelEntry.socket.destroy();
  if(concurrentEntry.readHalfClosed)finish(concurrentEntry);
 }
 try {
  server=net.createServer({allowHalfOpen:true},socket=>{
   live.add(socket);const openedMs=now();
   const entry={socket,openedMs,openedUtc:new Date().toISOString(),remotePort:socket.remotePort,count:0,bodyCount:0,
    hash:createHash('sha256'),responseHash:createHash('sha256'),responseCount:0,header:Buffer.alloc(0),case:null,heartbeatAcks:0};
   report.cases.push(entry);correlate(entry);trace('socket-open',{remotePort:entry.remotePort});
   let deadline=setTimeout(()=>abort(entry,'Control socket absolute deadline exceeded'),180000);
   socket.setTimeout(45000,()=>abort(entry,'Control socket progress deadline exceeded'));
   socket.on('data',data=>{
    entry.hash.update(data);entry.count+=data.length;
    let body=data;
    if(!entry.case){
     entry.header=Buffer.concat([entry.header,data]);const newline=entry.header.indexOf(10);
     if(newline<0){if(entry.header.length>64)abort(entry,'Control header exceeded 64 bytes');return;}
     const header=entry.header.subarray(0,newline+1).toString('ascii');
     const match=/^TC1 (duplex|slow|cancel|concurrent|sparse)\n$/.exec(header);
     if(!match)return abort(entry,'Unknown control header');
     entry.case=match[1];entry.headerCount=newline+1;entry.expected=expected(entry.case);body=entry.header.subarray(newline+1);entry.header=null;
     correlate(entry);trace('case-header',{case:entry.case,peerId:entry.peerId,remotePort:entry.remotePort});
     if(entry.case==='slow'){
      socket.pause();entry.slowPauseMs=5000;
      setTimeout(()=>{if(!socket.destroyed)socket.resume();},entry.slowPauseMs);
     }
     if(entry.case==='cancel')cancelEntry=entry;
     if(entry.case==='concurrent')concurrentEntry=entry;
     if(entry.case==='sparse'){
      clearTimeout(deadline);deadline=setTimeout(()=>abort(entry,'Sparse control absolute deadline exceeded'),370000);
      send(entry,'SPARSE_OPEN\n');entry.openAcknowledgedBeforeEof=true;
     }
    } else if(entry.case==='slow'){
     socket.pause();setTimeout(()=>{if(!socket.destroyed)socket.resume();},25);
    }
    const spec=definitions[entry.case];
    if(entry.bodyCount+body.length>spec.length)return abort(entry,'Control payload exceeded expected count');
    for(let i=0;i<body.length;i++)if(body[i]!==(((entry.bodyCount+i)*31+spec.seed)&255))return abort(entry,'Control payload differs');
    entry.bodyCount+=body.length;entry.lastProgressMs=now();correlate(entry);
    if(entry.case==='duplex'&&entry.bodyCount>=32768&&!entry.challengeSent){
     if(entry.bodyCount!==32768)return abort(entry,'Duplex suffix arrived before challenge');
     entry.challengeSent=true;entry.challengeBeforeEof=!entry.readHalfClosed;
     entry.deviceEofBeforeChallenge=r.trace.some(e=>e.id===entry.peerId&&e.origin==='device-eof');
     entry.uploadAtChallenge=entry.upload?structuredClone(entry.upload):null;send(entry,'CHALLENGE\n');
     trace('duplex-challenge-before-eof',{peerId:entry.peerId,count:entry.count,upload:entry.uploadAtChallenge});
    }
    if(entry.case==='sparse'){
     while(entry.heartbeatAcks<Math.floor(entry.bodyCount/64)){
      const index=entry.heartbeatAcks++;send(entry,`ACK ${index}\n`);
      entry.heartbeatTimes??=[];entry.heartbeatTimes.push(now()-openedMs);
      trace('sparse-heartbeat-ack',{index,peerId:entry.peerId,elapsedMs:now()-openedMs,requestEof:entry.upload?.requestEof});
     }
    }
    cancelWhenOverlapping();
   });
   socket.once('end',()=>{
    entry.readHalfClosed=true;entry.eofElapsedMs=now()-openedMs;correlate(entry);
    if(entry.case==='cancel')return abort(entry,'Cancelled sender unexpectedly half-closed before target cancellation');
    entry.sha256=entry.hash.digest('hex');trace('readable-eof',{case:entry.case,peerId:entry.peerId,count:entry.count});
    if(!entry.expected||entry.count!==entry.expected.count||entry.sha256!==entry.expected.sha256)return abort(entry,'Control final hash/count differs');
    finish(entry);
   });
   socket.on('error',error=>{entry.socketErrorCode=error.code||'SOCKET_ERROR';trace('socket-error',{case:entry.case,code:entry.socketErrorCode});});
   socket.once('close',()=>{clearTimeout(deadline);live.delete(socket);entry.closedMs=now();correlate(entry);});
  });
  await new Promise((ok,no)=>{server.once('error',no);server.listen(53317,'127.0.0.1',ok);});
  timer=setInterval(()=>{
   const memory=process.memoryUsage();for(const key of Object.keys(memory))report.memoryPeak[key]=Math.max(report.memoryPeak[key],memory[key]);
   for(const entry of report.cases){
    correlate(entry);if(entry.closedMs)continue;entry.memoryBefore??={...memory};entry.memoryPeak??={...memory};
    for(const key of Object.keys(memory))entry.memoryPeak[key]=Math.max(entry.memoryPeak[key],memory[key]);
    if(!entry.lastMemorySampleMs||now()-entry.lastMemorySampleMs>=1000){
     entry.memorySamples??=[];if(entry.memorySamples.length<600)entry.memorySamples.push({elapsedMs:now()-entry.openedMs,...memory});entry.lastMemorySampleMs=now();
    }
   }
  },100);
  trace('server-listening',{port:53317});await snap(stem+'-before');await click('Run transport controls');
  lastXml=await waitFor(xml=>{
   lastXml=xml;const result=nativeResult(xml,labels);if(!result)return false;
   report.android=result;
   if(result.status!=='passed'){
    const error=new Error('Native transport control failed: '+result.failedPhase);
    error.failedPhase=result.failedPhase;error.nativeErrorType=result.errorType;error.nativeResult=result;throw error;
   }
   return true;
  },600000,'Native transport controls exceeded suite deadline');
  await snap(stem+'-result',lastXml);
  await sleep(1000);for(const entry of report.cases)correlate(entry);
  if(serverFailure)throw serverFailure;
  assert.deepEqual(report.android.cases.map(c=>c.case),['duplex','slow','cancel','concurrent','sparse']);
  assert.equal(report.cases.length,5,'Unexpected target peer count');
  for(const name of Object.keys(definitions)){
   const entry=report.cases.find(c=>c.case===name),native=report.android.cases.find(c=>c.case===name),want=expected(name);
   assert(entry&&native,'Missing physical case: '+name);assert(entry.peerId,'Missing relay peer correlation: '+name);
   assert.deepEqual({count:entry.count,sha256:entry.sha256},want,'Target dataset differs: '+name);
   assert.deepEqual({count:native.count,sha256:native.sha256},want,'Native dataset differs: '+name);
   if(name==='cancel'){
    assert(entry.cancelledByTarget&&native.remoteClosed,'Cancellation was not observed');
    assert.equal(native.receivedCount,entry.responseCount);assert.equal(native.receivedSha256,entry.responseSha256);continue;
   }
   assert(entry.readHalfClosed&&entry.replyFlushed&&native.shutdownOutput&&native.replyReadThroughEof,'Half-close/reply incomplete: '+name);
   assert.equal(native.receivedCount,entry.responseCount,'Response count differs: '+name);
   assert.equal(native.receivedSha256,entry.responseSha256,'Response SHA-256 differs: '+name);
  }
  const duplex=report.cases.find(c=>c.case==='duplex'),slow=report.cases.find(c=>c.case==='slow'),sparse=report.cases.find(c=>c.case==='sparse');
  assert(duplex.challengeBeforeEof&&report.android.cases[0].challengeBeforeShutdownOutput,'Duplex challenge did not precede Android half-close');
  assert(!duplex.deviceEofBeforeChallenge,'Relay device EOF preceded duplex challenge');
  assert(duplex.uploadAtChallenge,'Duplex upload metrics missing at challenge');
  if(mode==='stream')assert(!duplex.uploadAtChallenge.requestEof,'Upload had EOF before duplex challenge');
  assert(slow.upload?.paused>0,'Slow target did not exercise relay upload backpressure');
  assert(slow.upload.peakWritableLength<=slow.upload.socketWritableHighWaterMark+65536,'Target write buffer exceeded high-water mark plus one 64 KiB chunk');
  assert(slow.upload.peakRequestReadableLength<=128*1024,'HTTP readable buffer exceeded 128 KiB');
  slow.backpressureEvents=r.trace.filter(e=>e.id===slow.peerId&&e.origin==='upload-backpressure-first-pause');
  assert(slow.backpressureEvents.some(e=>e.writableLength>=slow.upload.socketWritableHighWaterMark),'Slow receiver did not pause upload at socket high-water mark');
  slow.memoryDelta=Object.fromEntries(Object.keys(slow.memoryPeak).map(key=>[key,slow.memoryPeak[key]-slow.memoryBefore[key]]));
  assert(r.status().peak<=512*1024+65536,'Relay reverse queue exceeded high-water mark plus one 64 KiB chunk');
  assert(sparse.eofElapsedMs>=305000,'Sparse target lifespan did not exceed 300 seconds');
  assert.equal(sparse.heartbeatAcks,13);assert(sparse.openAcknowledgedBeforeEof);
  for(let i=1;i<sparse.heartbeatTimes.length;i++)assert(sparse.heartbeatTimes[i]-sparse.heartbeatTimes[i-1]<=30000,'Sparse heartbeat gap exceeded 30 seconds');
  assert(sparse.upload,'Sparse relay HTTP metrics missing');
  const opened=sparse.upload.streamStartedElapsedMs??sparse.upload.openedElapsedMs;
  const eof=sparse.upload.requestEofElapsedMs;
  if(mode==='stream'){
   assert(sparse.upload.requestEof,'Sparse streaming HTTP request did not end');
   assert(typeof opened==='number'&&typeof eof==='number'&&eof-opened>300000,'Streaming HTTP request did not remain open >300 seconds');
   report.sparseRequestProof={kind:'one HTTP request',openElapsedMs:opened,eofElapsedMs:eof,durationMs:eof-opened};
  }else report.sparseRequestProof={kind:'coalesced binary requests across one logical peer',peerDurationMs:sparse.eofElapsedMs};
  const helper=report.android.helper;
  assert(helper?.running&&helper.transport===mode,'Native helper transport metrics missing or mode differs');
  assert.equal(helper.maxQueueBytes,1024*1024);assert.equal(helper.readBufferBytes,65536);
  for(const entry of report.cases){
   const owned=helper.peers?.[entry.peerId];assert(owned,'Native helper peer metrics missing: '+entry.case);
   assert.equal(owned.bytes,entry.count,'Native helper upload count differs: '+entry.case);
   assert(owned.peakQueuedBytes<=(mode==='stream'?helper.readBufferBytes:helper.maxQueueBytes),'Native helper queue exceeded mode buffer limit: '+entry.case);
   entry.helper=owned;
  }
  report.status='passed';return report;
 }catch(error){
  report.status='failed';report.failedPhase=error.failedPhase||'transport-control-verification';
  report.failure=error.failedPhase?'Native control failed in '+error.failedPhase:'Transport control verification failed';
  throw error;
 }finally{
  clearInterval(timer);
  if(lastXml){try{report.android??=nativeResult(lastXml,labels);}catch{trace('native-result-unparseable');}save(stem+'-last.xml',lastXml);}
  try{const finalXml=await snap(stem+'-final');report.android??=nativeResult(finalXml,labels);}catch{trace('final-snapshot-unavailable');}
  for(const socket of live)socket.destroy();
  if(server?.listening)await new Promise(ok=>server.close(ok));
  report.metricsAfter=r.status();report.relayTrace=r.trace.slice();
  for(const entry of report.cases){
   entry.sha256??=entry.hash.digest('hex');entry.responseSha256??=entry.responseHash.digest('hex');
  }
  // Strip Node sockets, digest instances and transient buffers before saving or returning.
  report.cases=report.cases.map(({socket,hash,responseHash,header,lastSampleMs,lastMemorySampleMs,...entry})=>entry);
  save(stem+'.json',report);save(stem+'-trace.json',report.trace);save(stem+'-relay-trace.json',report.relayTrace);
 }
}
