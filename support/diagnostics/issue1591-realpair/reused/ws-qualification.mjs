import {createHash} from 'node:crypto';
import {WebSocket, WebSocketServer} from 'ws';

// Immutable dependency/API provenance: ws 8.22.0, upstream commit
// 297202cdae9b0590629821373b3b679c407f3431/doc/ws.md; npm integrity in ../package-lock.json.
// Application buffers are bounded; these limits do not bound OS or library memory.
const challenges = [1, 2, 3, 4].map(ordinal => Buffer.alloc(1024, ordinal));
const hash = data => createHash('sha256').update(data).digest('hex');
const challengeHashes = challenges.map(hash);
const keys = ['v', 'id', 'kind', 'pid', 'generation', 'state', 'budgetState', 'remainingBudgetSeconds', 'assertionActive'];
const validID = value => typeof value === 'string' && /^[A-Za-z0-9:-]{1,128}$/.test(value);

export function qualification(server, token, enabled) {
  const wss = new WebSocketServer({noServer:true, clientTracking:true, maxPayload:8192, perMessageDeflate:false, autoPong:false});
  let stopped=false, armed=false, used=false, socket=null, pending=null, deadlineTimer=null, closeTimer=null, closeWait=null;
  let started=0n, deadline=0n, phase='idle', outcome='idle', failure=null, id=null, pid=null, generation=null;
  let inboundFrames=0, outboundFrames=0, inboundBytes=0, outboundBytes=0, receivedBinary=0, sentBinary=0, sendInFlight=false;
  let foregroundReady=false, nativeBackgroundReady=false, nativeComplete=false, normalClose=false, forcedClose=false, closeCode=null;
  let dropped=0, events=[], observed=null;
  let queuedMessages=[], queuedBytes=0;
  const elapsedMs=()=>started ? Number(process.hrtime.bigint()-started)/1e6 : 0;
  function record(kind, fields={}) {
    if(events.length >= 128) { dropped++; fail('metadata-overflow'); return false; }
    events.push({kind,elapsedMs:elapsedMs(),id,generation,...fields});
    return true;
  }
  const status=()=>({v:1,id,pid,generation,phase,outcome,failure,foregroundReady,nativeBackgroundReady,nativeComplete,
    sentBinary,receivedBinary,inboundFrames,outboundFrames,inboundBytes,outboundBytes,activeChannels:socket?1:0,pendingUpgrades:pending?1:0,
    normalClose,forcedClose,closeCode,queuedFrames:queuedMessages.length,queuedBytes,sendInFlight,dropped,elapsedMs:elapsedMs(),deadlineMs:20000,
    challengeHashes:[...challengeHashes],events:events.map(event=>({...event}))});
  function finishClose() {
    clearTimeout(closeTimer); closeTimer=null;
    if(closeWait) { const resolve=closeWait; closeWait=null; resolve(); }
  }
  function closeOwned() {
    armed=false;
    queuedMessages=[];queuedBytes=0;
    if(pending) { pending.destroy(); pending=null; }
    if(!socket) return Promise.resolve();
    if(closeWait) return new Promise(resolve=>{const previous=closeWait;closeWait=()=>{previous();resolve();};});
    return new Promise(resolve=>{
      closeWait=resolve;
      record('close-request',{code:outcome==='payload-passed'?1000:1008});
      try {socket.close(outcome==='payload-passed'?1000:1008,'qualification ended');} catch {forcedClose=true;socket.terminate();}
      closeTimer=setTimeout(()=>{
        if(socket) { forcedClose=true; record('close-forced'); socket.terminate(); socket=null; sendInFlight=false; }
        if(!failure) {failure='normal-close-missing';outcome='failed';}
        finishClose();
      },1000);
    });
  }
  function fail(reason) {
    if(!failure) { failure=reason; outcome='failed';phase='failed'; }
    armed=false; clearTimeout(deadlineTimer); deadlineTimer=null;
    void closeOwned();
  }
  function live() {
    if(!armed || failure || process.hrtime.bigint()>=deadline) {if(armed&&!failure)fail('host-deadline');return false;}
    return true;
  }
  function send(ordinal, nextPhase, done=()=>{}) {
    if(!live())return;
    if(sendInFlight || !socket || socket.readyState!==WebSocket.OPEN || socket.bufferedAmount>4096 || outboundFrames>=16) {fail('send-admission');return;}
    const ws=socket, payload=challenges[ordinal-1];
    if(outboundBytes+payload.length>65536) {fail('outbound-byte-admission');return;}
    sendInFlight=true;outboundFrames++;outboundBytes+=payload.length;phase=nextPhase;
    if(!record('binary-send',{ordinal,length:payload.length,sha256:challengeHashes[ordinal-1],...observed}))return;
    ws.send(payload,{binary:true,compress:false},error=>{
      if(socket!==ws)return;
      sendInFlight=false;
      if(!live())return;
      if(error) {fail('send-error');return;}
      sentBinary++;
      if(!record('binary-send-complete',{ordinal,...observed}))return;
      done();drainMessages();
    });
    if(ws.bufferedAmount>8192)fail('send-buffer-overflow');
  }
  function control(data) {
    if(data.length>1024) {fail('control-size');return;}
    let value;try {value=JSON.parse(data.toString('utf8'));}catch {fail('control-json');return;}
    const complete=phase==='await-complete';
    const expectedKeys=complete?[...keys,'sentBinary','receivedBinary','outcome']:keys;
    if(!value || Array.isArray(value) || Object.keys(value).length!==expectedKeys.length || !expectedKeys.every(key=>Object.hasOwn(value,key)) ||
      value.v!==1 || value.id!==id || !Number.isSafeInteger(value.pid) || value.pid<=0 || !validID(value.generation) || value.assertionActive!==true ||
      (pid!==null && (pid!==value.pid || generation!==value.generation))) {fail('control-identity-or-schema');return;}
    const finite=value.budgetState==='finite' && Number.isFinite(value.remainingBudgetSeconds) && value.remainingBudgetSeconds>0;
    let next;
    const active=value.state==='active' && (finite || value.budgetState==='foreground-unbounded' && value.remainingBudgetSeconds===null);
    if(phase==='await-foreground' && value.kind==='foreground-ready' && active) next='await-native1';
    else if(phase==='await-foreground-verified' && value.kind==='foreground-verified' && active && sentBinary===1 && receivedBinary===1) next='await-background';
    else if(phase==='await-background' && value.kind==='background-ready' && value.state==='background' && finite && value.remainingBudgetSeconds>=5) next='await-native2';
    else if(complete && value.kind==='native-complete' && value.state==='background' && finite && value.sentBinary===4 && value.receivedBinary===4 &&
      value.outcome==='passed' && sentBinary===4 && receivedBinary===4 && !sendInFlight) next='payload-complete';
    else {fail('control-phase-or-state');return;}
    if(next==='payload-complete' && queuedMessages.length) {fail('unexpected-extra-message');return;}
    pid=value.pid;generation=value.generation;
    observed={state:value.state,budgetState:value.budgetState,remainingBudgetSeconds:value.remainingBudgetSeconds,assertionActive:true};
    if(!record('control-receipt',{controlKind:value.kind,pid,...observed}))return;
    phase=next;
    if(next==='await-background')foregroundReady=true;
    if(next==='await-native2')nativeBackgroundReady=true;
    if(next==='payload-complete') {nativeComplete=true;outcome='payload-passed';void closeOwned();}
  }
  function transcriptMessage(data,isBinary) {
    if(!live())return;
    if(!isBinary) {control(data);return;}
    const ordinal={'await-native1':1,'await-native2':2,'await-host3':3,'await-host4':4}[phase];
    if(!ordinal || data.length!==1024 || !data.equals(challenges[ordinal-1])) {fail('binary-order-or-content');return;}
    receivedBinary++;
    if(!record('binary-receipt',{ordinal,length:data.length,sha256:hash(data),...observed}))return;
    if(ordinal===1)send(1,'await-foreground-verified');
    if(ordinal===2)send(2,'sending-echo2',()=>send(3,'await-host3'));
    if(ordinal===3)send(4,'await-host4');
    if(ordinal===4)phase='await-complete';
  }
  function drainMessages() {
    while(live() && !sendInFlight && queuedMessages.length) {
      const next=queuedMessages.shift();queuedBytes-=next.data.length;
      transcriptMessage(next.data,next.isBinary);
    }
  }
  function message(data,isBinary) {
    if(outcome==='payload-passed' && socket) {fail('unexpected-extra-message');return;}
    if(!live())return;
    // No native response is due between echo2 and the host's challenge3 send.
    if(phase==='sending-echo2') {fail('message-before-host-challenge');return;}
    if(++inboundFrames>16 || data.length>(isBinary?4096:1024) || inboundBytes+data.length>65536) {fail('message-admission');return;}
    inboundBytes+=data.length;
    // A peer receipt can precede the local send callback. Retain at most this
    // fixed transcript's four messages; the callback releases send ownership first.
    if(sendInFlight || queuedMessages.length) {
      if(queuedMessages.length>=4 || queuedBytes+data.length>16384) {fail('pending-message-overflow');return;}
      queuedMessages.push({data,isBinary});queuedBytes+=data.length;
      if(!record('message-held',{length:data.length,isBinary}))return;
      drainMessages();return;
    }
    transcriptMessage(data,isBinary);
  }
  function upgrade(req,raw,head) {
    raw.on('error',()=>{}); // Never dump request headers or token-bearing errors.
    if(!enabled || stopped || req.method!=='GET' || req.url!=='/qualify-ws' || req.headers.authorization!==`Bearer ${token}` ||
      req.headers['x-qualification-id']!==id || !live() || pending || socket || phase!=='armed' || head.length>8192) {raw.destroy();return;}
    pending=raw;record('authenticated-upgrade');
    const abandon=()=>{if(pending===raw){pending=null;fail('upgrade-aborted');}};
    raw.once('close',abandon);
    try {wss.handleUpgrade(req,raw,head,ws=>{
      raw.removeListener('close',abandon);pending=null;
      ws.on('error',()=>fail('websocket-error'));
      if(!live() || stopped) {ws.terminate();return;}
      socket=ws;phase='await-foreground';outcome='running';record('open');
      ws.on('message',message);
      ws.on('ping',()=>fail('unexpected-ping'));ws.on('pong',()=>fail('unexpected-pong'));
      ws.once('close',code=>{
        socket=null;sendInFlight=false;closeCode=code;
        normalClose=!forcedClose && code===1000;
        record('close',{code,normalClose,forcedClose});
        if(outcome==='payload-passed' && normalClose && !dropped && process.hrtime.bigint()<deadline) {outcome='passed';phase='complete';}
        else if(!failure) {failure='unexpected-close';outcome='failed';phase='failed';}
        armed=false;clearTimeout(deadlineTimer);deadlineTimer=null;finishClose();
      });
    });}catch {pending=null;raw.destroy();fail('upgrade-error');}
  }
  server.on('upgrade',upgrade);
  wss.on('error',()=>fail('websocket-server-error'));
  return {
    armQualification(value) {
      if(!enabled || stopped || used || !validID(value))throw new Error('Qualification admission unavailable');
      used=true;id=value;started=process.hrtime.bigint();deadline=started+20_000_000_000n;armed=true;phase='armed';outcome='armed';
      record('armed');deadlineTimer=setTimeout(()=>fail('host-deadline'),20000);return status();
    },
    qualificationStatus:status,
    revokeQualification(reason='controller-revoke') {
      if(outcome!=='passed' && !failure)fail(/^[a-z0-9-]{1,128}$/.test(reason)?reason:'controller-revoke');
      armed=false;clearTimeout(deadlineTimer);deadlineTimer=null;return closeOwned();
    },
    async stop() {
      stopped=true;armed=false;clearTimeout(deadlineTimer);deadlineTimer=null;
      if(outcome!=='passed'&&!failure)fail('relay-stop');
      await closeOwned();server.removeListener('upgrade',upgrade);
      await new Promise(resolve=>wss.close(()=>resolve()));
      token=null;
    },
  };
}
