import {spawn, execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync, appendFileSync, writeFileSync} from 'node:fs';
import {createHash, randomBytes} from 'node:crypto';
import {createInterface} from 'node:readline';
import {performance} from 'node:perf_hooks';
import {resolve} from 'node:path';
import {relay} from './reused/relay.mjs';

// No Windows sender, LocalSend peer, media selection or receiver settings path.
export async function runWebSocketQualification({wd, save, redact, auth, token, appId, proxyId, root, setSession, setStage}) {
  const exec = promisify(execFile), pause = ms => new Promise(ok => setTimeout(ok, ms));
  const id = randomBytes(16).toString('hex'), receipt = {v:1,id,selector:'ws-qualification',startedUtc:new Date().toISOString(),commands:[],cleanup:[]};
  const ownershipName='issue1591-ws-'+(process.env.GITHUB_RUN_ID || 'unidentified')+'-'+(process.env.GITHUB_RUN_ATTEMPT || '1')+'-'+id;
  receipt.buildName=ownershipName;receipt.sessionName=ownershipName;receipt.creationAttempted=false;receipt.creationAmbiguous=false;
  let session, local, r, failure, ambiguous = false, armedAt, deadline;
  const prefix = () => '/session/' + session;
  const fail = error => {failure ||= redact(error);receipt.failure = failure;};
  const budget = (until, maximum) => {
    const remaining = Math.floor(until - performance.now());
    if (remaining <= 0) throw new Error('Owned operation deadline expired');
    return Math.min(maximum, remaining);
  };
  const setupDeadline = performance.now() + 600000;
  const setupWd = async (method,path,body,maximum=30000) => {
    try {return await wd(method,path,body,budget(setupDeadline,maximum));}
    catch(error) {
      if(method==='POST' && /\/activate_app$|\/(?:clear|value)$/.test(path)) ambiguous=true;
      throw error;
    }
  };
  const admissionWd = async (method,path,body,{input=false}={}) => {
    if (ambiguous) throw new Error('Native UI prohibited after ambiguous input');
    const started = performance.now(), command = {method,path:path.replace(/\/session\/[^/]+/,'/session/owned'),input,startedMs:started-armedAt};
    receipt.commands.push(command);
    try {
      const value = await wd(method,path,body,budget(deadline,3000));
      budget(deadline,3000); // A late response cannot renew admission.
      command.ok = true;
      return value;
    } catch (error) {
      command.ok = false;command.error = redact(error);
      if (input) {ambiguous = true;receipt.inputAmbiguous = true;}
      fail(error);
      if (r) void r.revokeQualification(input ? 'ambiguous-native-input' : 'driver-admission-failed').catch(error => fail(error));
      throw error;
    } finally {command.elapsedMs = performance.now()-started;}
  };
  const one = async name => {
    const matches = await setupWd('POST',prefix()+'/elements',{using:'accessibility id',value:name});
    if (matches.length !== 1) throw new Error('Owned helper control absent or ambiguous: '+name);
    const element = matches[0]['element-6066-11e4-a52e-4f735466cecf'];
    if (!await setupWd('GET',prefix()+'/element/'+element+'/displayed')) throw new Error('Owned helper control not visible: '+name);
    return element;
  };
  const pollHost = async predicate => {
    while (true) {
      budget(deadline,3000);
      const status = r.qualificationStatus();
      if (status.outcome === 'failed') throw new Error('Host qualification failed: '+status.failure);
      if (predicate(status)) return status;
      await pause(budget(deadline,50));
    }
  };
  try {
    for (const name of ['BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','PROXY_APP','RECEIVER_APP','RECEIVER_IDENTITY','BS_LOCAL_ID']) if (!process.env[name]) throw new Error('Missing required input '+name);
    for (const name of ['PROXY_APP','RECEIVER_APP']) if (!/^bs:\/\/[a-f0-9]{40}$/i.test(process.env[name])) throw new Error('Expected immutable BrowserStack app hash for '+name);
    const sourceFiles = ['run.mjs','ws-qualification.mjs','reused/relay.mjs','reused/ws-qualification.mjs','package.json','package-lock.json'];
    const sourceHashes = Object.fromEntries(sourceFiles.map(file => [file,createHash('sha256').update(readFileSync(resolve(root,file))).digest('hex')]));
    sourceHashes['.github/workflows/issue1591-realpair.yml'] = createHash('sha256').update(readFileSync('.github/workflows/issue1591-realpair.yml')).digest('hex');
    save('ws-source-identity.json',{revision:process.env.GITHUB_SHA,node:process.version,sourceHashes,helper:process.env.PROXY_APP,
      receiver:process.env.RECEIVER_APP,receiverIdentity:process.env.RECEIVER_IDENTITY,proxyId,appId,localIdentifier:process.env.BS_LOCAL_ID,
      endpoint:'ws://bs-local.com:8080/qualify-ws',sender:'none',localSendPeers:0,qualificationId:id});
    setStage('ws-local-setup');
    const localArgs = ['--key',process.env.BROWSERSTACK_ACCESS_KEY,'--local-identifier',process.env.BS_LOCAL_ID,'--force-local','--only-automate'];
    save('ws-local-configuration.json',{binary:'C:/tmp/bs-local-bin/BrowserStackLocal.exe',args:localArgs.map(value=>value===process.env.BROWSERSTACK_ACCESS_KEY?'[redacted]':value)});
    local = spawn('C:/tmp/bs-local-bin/BrowserStackLocal.exe',localArgs,{windowsHide:true});
    let output = '', localError;
    for (const [stream,name] of [[local.stdout,'local.stdout.txt'],[local.stderr,'local.stderr.txt']]) createInterface({input:stream}).on('line',line=>{
      const text = redact(line)+'\n';appendFileSync('evidence/'+name,text);output=(output+text).slice(-20000);
    });
    local.on('error',error=>{localError=error;});
    const localDeadline = Math.min(setupDeadline,performance.now()+120000);
    while (!/You can now access your local|Local Testing successfully connected/i.test(output) && performance.now()<localDeadline && !localError && local.exitCode===null) await pause(budget(localDeadline,200));
    if (localError || local.exitCode!==null || !/You can now access your local|Local Testing successfully connected/i.test(output)) throw new Error('Owned Local did not become ready');
    r = relay({token,qualificationOnly:true});await r.start();
    setStage('ws-capacity-admission');
    const response = await fetch('https://api-cloud.browserstack.com/app-automate/plan.json',{headers:{authorization:auth},signal:AbortSignal.timeout(budget(setupDeadline,30000))});
    if (!response.ok) throw new Error('Fresh global capacity check HTTP '+response.status);
    const plan = await response.json();save('capacity-before-session.json',{checkedUtc:new Date().toISOString(),plan});
    const running = plan.parallel_sessions_running==null?NaN:Number(plan.parallel_sessions_running), queued = plan.queued_sessions==null?NaN:Number(plan.queued_sessions);
    const limit = Math.min(5,...[plan.parallel_sessions_max_allowed,plan.team_parallel_sessions_max_allowed].filter(value=>value!==undefined && value!==null).map(Number));
    const teamRunning = Number(plan.team_parallel_sessions_running);
    if (!Number.isFinite(running)||!Number.isFinite(queued)||!Number.isFinite(limit)||running>=limit||queued>0||(Number.isFinite(teamRunning)&&teamRunning>=limit)) throw new Error('Global capacity unavailable or occupied; no session admitted');
    setStage('ws-owned-installation');
    const caps = {platformName:'iOS','appium:deviceName':'iPad 9th','appium:platformVersion':'18','appium:automationName':'XCUITest',
      'appium:app':process.env.RECEIVER_APP,'appium:otherApps':[process.env.PROXY_APP],'appium:autoAcceptAlerts':false,
      'bstack:options':{local:true,localIdentifier:process.env.BS_LOCAL_ID,projectName:'LocalSend diagnostic',buildName:ownershipName,
        sessionName:ownershipName,idleTimeout:120,debug:true,video:true,networkLogs:false}};
    save('requested-capabilities.json',caps);
    let created;
    receipt.creationAttempted=true;receipt.creationInvokedUtc=new Date().toISOString();
    try {
      created = await setupWd('POST','/session',{capabilities:{alwaysMatch:caps,firstMatch:[{}]}},120000);
      if(!/^[a-f0-9]{40}$/i.test(created?.sessionId || ''))throw new Error('Owned session ID missing or malformed');
      session=created.sessionId;setSession(session);receipt.creationConfirmed=true;
    } catch(error) {
      // Aborting the client request cannot establish that no remote session exists.
      receipt.creationAmbiguous=true;ambiguous=true;throw error;
    }
    save('owned-session.json',{session,capabilities:created.capabilities,createdUtc:new Date().toISOString()});
    await setupWd('POST',prefix()+'/appium/device/activate_app',{appId:proxyId});
    for (const [name,value] of [['relayURL','http://bs-local.com:8080'],['relayToken',token],['qualificationID',id]]) {
      const element = await one(name);
      await setupWd('POST',prefix()+'/element/'+element+'/clear',{});
      await setupWd('POST',prefix()+'/element/'+element+'/value',{text:value});
    }
    const start = await one('qualifyWebSocket');
    const helperState = await setupWd('POST',prefix()+'/execute/sync',{script:'mobile: queryAppState',args:[{bundleId:proxyId}]});
    if (helperState !== 4) throw new Error('Owned helper not foreground before arming');
    setStage('ws-qualification-admission');armedAt=performance.now();deadline=armedAt+20000;
    r.armQualification(id);receipt.armedUtc=new Date().toISOString();receipt.admissionLimitMs=20000;
    await admissionWd('POST',prefix()+'/element/'+start+'/click',{}, {input:true});
    receipt.foreground = await pollHost(status=>status.foregroundReady);
    await admissionWd('POST',prefix()+'/appium/device/activate_app',{appId},{input:true});
    receipt.background = await pollHost(status=>status.nativeBackgroundReady);
    const receiverState = await admissionWd('POST',prefix()+'/execute/sync',{script:'mobile: queryAppState',args:[{bundleId:appId}]});
    if (receiverState !== 4) throw new Error('Unchanged receiver not observed foreground');
    receipt.hostFinal = await pollHost(status=>status.outcome==='passed');
    if (!receipt.hostFinal.normalClose || receipt.hostFinal.forcedClose || receipt.hostFinal.activeChannels!==0 || receipt.hostFinal.pendingUpgrades!==0 || receipt.hostFinal.dropped!==0 || receipt.hostFinal.sendInFlight) throw new Error('Host close/ownership receipt incomplete');
    receipt.payloadAndHostClosePassed=true;receipt.admissionElapsedMs=performance.now()-armedAt;
  } catch (error) {fail(error);}
  finally {
    setStage('ws-owned-cleanup');const cleanupDeadline=performance.now()+45000;
    const cleanupWd = (method,path,body) => wd(method,path,body,budget(cleanupDeadline,3000));
    const clean = async (operation, action) => {
      const entry={operation,startedUtc:new Date().toISOString(),remainingMs:Math.max(0,Math.floor(cleanupDeadline-performance.now()))};receipt.cleanup.push(entry);
      try {budget(cleanupDeadline,3000);await action();entry.ok=true;}
      catch(error){entry.ok=false;entry.error=redact(error);fail('Cleanup failed: '+operation);}
      entry.finishedUtc=new Date().toISOString();
    };
    if (r) {receipt.hostBeforeCleanup=r.qualificationStatus();await clean('revoke owned qualification',()=>r.revokeQualification(failure?'controller-failure':'controller-cleanup'));}
    if(receipt.creationAmbiguous && !session) await clean('recover exact owned provider session',async()=>{
      const recoveryDeadline=Math.min(cleanupDeadline,performance.now()+10000);
      const get = async path=>{
        const response=await fetch('https://api-cloud.browserstack.com/app-automate'+path,{headers:{authorization:auth},signal:AbortSignal.timeout(budget(recoveryDeadline,3000))});
        if(!response.ok)throw new Error('Owned-session recovery HTTP '+response.status);
        const value=await response.json();if(!Array.isArray(value)||value.length>100)throw new Error('Owned-session recovery listing shape invalid');return value;
      };
      // One bounded page per supported listing. A missing or duplicated exact
      // identity remains unresolved; never substitute the newest account session.
      const builds=await get('/builds.json?limit=100&offset=0');
      const matches=builds.map(entry=>entry.automation_build).filter(build=>build?.name===ownershipName);
      receipt.creationRecovery={buildMatches:matches.length,maximumPages:1,maximumEntries:100};
      if(matches.length!==1||!/^[a-f0-9]{40}$/i.test(matches[0].hashed_id || ''))throw new Error('Exact owned build is absent or ambiguous');
      const build=matches[0];
      const sessions=await get('/builds/'+build.hashed_id+'/sessions.json?limit=100&offset=0');
      const owned=sessions.map(entry=>entry.automation_session).filter(value=>value?.name===ownershipName);
      receipt.creationRecovery.sessionMatches=owned.length;
      if(owned.length!==1||!/^[a-f0-9]{40}$/i.test(owned[0].hashed_id || '')||owned[0].build_name!==ownershipName||(owned[0].build_hashed_id!==undefined&&owned[0].build_hashed_id!==build.hashed_id)||owned[0].device!=='iPad 9th'||owned[0].os!=='ios'||!/^18(?:\.|$)/.test(owned[0].os_version))throw new Error('Exact owned session is absent, ambiguous or has mismatched ownership fields');
      session=owned[0].hashed_id;setSession(session);
      receipt.creationRecovery={...receipt.creationRecovery,buildId:build.hashed_id,sessionId:session,exactIdentityRecovered:true};
      save('owned-session-recovery.json',receipt.creationRecovery);
    });
    if (receipt.payloadAndHostClosePassed && !ambiguous) await clean('bounded native close callback grace',async()=>{
      // Host Close can precede delivery of the native delegate callback. This
      // grace is not proof; the original native terminal dump remains required.
      await pause(budget(cleanupDeadline,1000));
    });
    if (session && !ambiguous) await clean('original native terminal evidence',async()=>{
      try {await cleanupWd('POST',prefix()+'/appium/device/activate_app',{appId:proxyId});}
      catch(error){ambiguous=true;receipt.inputAmbiguous=true;throw error;}
      const logs=await cleanupWd('POST',prefix()+'/elements',{using:'accessibility id',value:'proxyLog'});
      if(logs.length!==1)throw new Error('Original helper log absent or ambiguous');
      const element=logs[0]['element-6066-11e4-a52e-4f735466cecf'];
      const text=await cleanupWd('GET',prefix()+'/element/'+element+'/attribute/value');save('ws-native-terminal.txt',text);
      receipt.nativeTerminal = parseNativeTerminal(text,id,receipt.hostBeforeCleanup);
      if(!receipt.nativeTerminal)throw new Error('Native terminal close/task/session/assertion proof incomplete');
    });
    if (session) await clean('DELETE exact owned provider session',async()=>{receipt.providerDeleteAttempted=true;await wd('DELETE',prefix(),undefined,budget(cleanupDeadline,8000));receipt.providerDeleteConfirmed=true;});
    if (r) await clean('owned relay stop',async()=>{
      let timer;try{await Promise.race([r.stop(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Relay cleanup deadline')),budget(cleanupDeadline,3000));})]);}finally{clearTimeout(timer);}
      receipt.hostAfterCleanup=r.qualificationStatus();save('ws-relay-final.json',receipt.hostAfterCleanup);save('relay-trace.json',r.trace);
      if(receipt.hostAfterCleanup.activeChannels!==0||receipt.hostAfterCleanup.pendingUpgrades!==0)throw new Error('Owned relay registry not empty');
    });
    if (local) await clean('owned Local process tree stop',async()=>{
      if(local.exitCode===null)await exec('taskkill',['/PID',String(local.pid),'/T','/F'],{timeout:budget(cleanupDeadline,5000)});
      receipt.localStop={pid:local.pid,exitCode:local.exitCode,treeTerminationCompleted:true};
    });
    let providerDetail;
    if (session) await clean('provider terminal metadata',async()=>{
      const metadata=await fetch('https://api-cloud.browserstack.com/app-automate/sessions/'+session+'.json',{headers:{authorization:auth},signal:AbortSignal.timeout(budget(cleanupDeadline,5000))});
      if(!metadata.ok)throw new Error('Terminal metadata HTTP '+metadata.status);
      const detail=(await metadata.json()).automation_session;
      providerDetail=detail;
      // Provider evidence URLs can contain signed credentials. Retain metadata
      // without those URLs; fetch originals directly without printing URLs.
      save('browserstack-session.json',Object.fromEntries(Object.entries(detail || {}).filter(([key])=>!key.endsWith('_url'))));
      receipt.providerTerminalStatus=detail?.status;
      if(!['done','passed','failed','error','timeout'].includes(detail?.status))throw new Error('Provider terminal state absent');
      if(receipt.creationAmbiguous && (detail?.hashed_id!==session||detail?.name!==ownershipName||detail?.build_name!==ownershipName||(detail?.build_hashed_id!==undefined&&detail.build_hashed_id!==receipt.creationRecovery?.buildId)))throw new Error('Recovered provider terminal identity differs');
      receipt.providerTerminalReconciled=true;
    });
    const originals=[];
    if (session) for(const [key,file] of [['device_logs_url','device-logs.txt'],['appium_logs_url','appium-logs.txt'],['video_url','original-browserstack-video.mp4']]) {
      await clean('original provider '+key,async()=>{
        if(!providerDetail?.[key])throw new Error('Original provider evidence omitted '+key);
        const url=new URL(providerDetail[key]);if(url.protocol!=='https:'||!(url.hostname==='browserstack.com'||url.hostname.endsWith('.browserstack.com')))throw new Error('Unexpected evidence origin');
        const response=await fetch(url,{headers:{authorization:auth},signal:AbortSignal.timeout(budget(cleanupDeadline,5000))});
        if(!response.ok)throw new Error('Original evidence HTTP '+response.status+': '+key);
        if(key==='video_url')writeFileSync('evidence/'+file,Buffer.from(await response.arrayBuffer()));else{const text=await response.text();if(!text.trim())throw new Error('Original evidence empty '+key);save(file,text);}
        originals.push(key);
      });
    }
    receipt.providerOriginalsRetained=originals.length===3;
    receipt.ownershipReconciled=!receipt.creationAttempted || !!(session&&receipt.providerTerminalReconciled);
    receipt.futureAdmissionBlocked=receipt.creationAttempted&&!receipt.ownershipReconciled;
    if(receipt.futureAdmissionBlocked){
      receipt.ownershipBlocker=session ?
        'Known owned provider session '+session+' has unreconciled teardown; no future admission until its exact terminal state is established' :
        'Ambiguous provider creation has no recovered owned session identity; no future admission until exact owned provider terminal state is established';
      fail(receipt.ownershipBlocker);
    }
    receipt.cleanupElapsedMs=45000-(cleanupDeadline-performance.now());receipt.inputAmbiguous=ambiguous;
    receipt.passed=!failure&&!ambiguous&&receipt.payloadAndHostClosePassed&&!!receipt.nativeTerminal&&receipt.providerOriginalsRetained&&receipt.cleanup.every(entry=>entry.ok);
    receipt.outcome=receipt.passed?'passed':'failed';receipt.failure=failure;
    save('ws-controller-receipt.json',receipt);save('cleanup.json',receipt.cleanup);
    save('evidence-admission.json',{failure,qualification:receipt.outcome,admission:'Requires parent inspection of original native, relay, controller, device logs and video. Synthetic route feasibility only; no LocalSend or Gallery conclusion.'});
  }
  if (!receipt.passed) {console.error(failure||'WebSocket qualification evidence incomplete');process.exitCode=1;}
}

function parseNativeTerminal(text,id,host) {
  const lines=String(text).split('\n');
  const fields=line=>Object.fromEntries(line.trim().split(/\s+/).map(field=>field.split('=')));
  for (const line of lines.reverse()) {
    const start=line.indexOf('ws-summary ');if(start<0)continue;
    const summary=fields(line.slice(start+'ws-summary '.length));
    const sameIdentity=summary.id===id&&summary.generation===host?.generation&&Number(summary.pid)===host?.pid;
    const records=lines.filter(line=>line.includes('ws-record ')).map(line=>fields(line.slice(line.indexOf('ws-record ')+'ws-record '.length)))
      .filter(record=>record.id===id&&record.generation===summary.generation);
    const closeRecord=records.some(record=>record.boundary==='close-receipt-code-1000');
    const allowanceEnded=records.some(record=>record.boundary==='allowance-ended');
    const openRecord=records.some(record=>record.boundary==='upgrade-open');
    const backgroundRecord=records.some(record=>record.boundary==='did-enter-background'&&record.state==='background'&&record.budgetState==='finite'&&Number(record.remainingBudgetSeconds)>=5);
    const hashes=[1,2,3,4].map(ordinal=>createHash('sha256').update(Buffer.alloc(1024,ordinal)).digest('hex'));
    const payloadProof=[1,2,3,4].every(ordinal=>['receive','send-completion'].every(boundary=>{
      const matching=records.filter(record=>record.boundary===boundary&&Number(record.ordinal)===ordinal);
      if(matching.length!==1)return false;
      const record=matching[0];
      return Number(record.bytes)===1024&&record.hash===hashes[ordinal-1]&&
        (ordinal===1 ? record.state==='active' : record.state==='background'&&record.budgetState==='finite'&&Number(record.remainingBudgetSeconds)>0);
    }));
    const recordProof=records.length===Number(summary.records)&&records.length<=128&&records.every(record=>Number.isFinite(Number(record.uptime))&&Number(record.uptime)>=Number(summary.originUptime)&&Number(record.uptime)-Number(summary.originUptime)<15);
    if(sameIdentity&&closeRecord&&allowanceEnded&&openRecord&&backgroundRecord&&payloadProof&&recordProof&&summary.outcome==='passed'&&summary.normalClose==='true'&&summary.forced==='false'&&summary.sentBinary==='4'&&summary.receivedBinary==='4'&&summary.task==='0'&&summary.session==='0'&&summary.queue==='0'&&summary.sendInFlight==='0'&&summary.receiveInFlight==='0'&&summary.assertionEnded==='true'&&summary.dropped==='0')return {...summary,records};
  }
  return null;
}
