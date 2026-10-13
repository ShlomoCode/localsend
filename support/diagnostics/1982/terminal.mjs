import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {existsSync,readFileSync,writeFileSync} from 'node:fs';
const intent = existsSync('evidence/allocation-intent.json') ? JSON.parse(readFileSync('evidence/allocation-intent.json', 'utf8')) : null;
const session = existsSync('evidence/browserstack-session.json') ? JSON.parse(readFileSync('evidence/browserstack-session.json', 'utf8')).session : intent?.session;
if (!session && intent) {
  writeFileSync('evidence/provider-terminal.json', JSON.stringify({terminal:false, unknownAllocation:true, intent, action:'Coordinator must reconcile this exact owned build/name; retain capacity slot'}, null, 2));
  throw new Error('Session creation outcome unknown; keep capacity held for reconciliation');
}
if (session) {
  assert(/^[0-9a-f]+$/.test(session), 'Invalid owned session identity');
  const auth = 'Basic ' + Buffer.from(process.env.BROWSERSTACK_USERNAME + ':' + process.env.BROWSERSTACK_ACCESS_KEY).toString('base64');
  const terminalStarted=Date.now();
  const report = {session, observations:[], cleanup:[], terminal:false};
  const qualification={session,state:'UNQUALIFIED',versionQualified:false,productAcceptanceAllowed:false};
  const saveQualification=()=>writeFileSync('evidence/final-version-qualification.json',JSON.stringify(qualification,null,2));
  saveQualification();
  let buildId;
  const save = () => writeFileSync('evidence/provider-terminal.json', JSON.stringify(report, null, 2));
  // This fallback runs even when the runner was canceled before finally could run.
  try {
    const response = await fetch('https://hub-cloud.browserstack.com/wd/hub/session/' + session, {method:'DELETE', headers:{authorization:auth}, signal:AbortSignal.timeout(20_000)});
    report.cleanup.push({operation:'delete-owned-session-fallback', status:response.status, completedUtc:new Date().toISOString()});
  } catch (error) { report.cleanup.push({operation:'delete-owned-session-fallback', unavailable:String(error)}); }
  save();
  for (let index=0;index<4;index++) {
    const response = await fetch('https://api-cloud.browserstack.com/app-automate/sessions/' + encodeURIComponent(session) + '.json', {headers:{authorization:auth}, signal:AbortSignal.timeout(20_000)});
    assert(response.ok, 'Owned session state query failed');
    const value = (await response.json()).automation_session;
    assert.equal(value?.hashed_id,session,'Terminal metadata belongs to another session');
    if(value?.status==='done'){
      buildId=value.build_hashed_id;
      assert(/^[a-f0-9]{40}$/.test(buildId),'Terminal provider build identity missing');
    }
    report.observations.push({checkedUtc:new Date().toISOString(), session, status:value?.status, reason:value?.reason, duration:value?.duration});
    // Test pass/fail labels are not lifecycle evidence. Require the explicit stopped receipt.
    report.terminal = value?.status === 'done' && value?.reason === 'CLIENT_STOPPED_SESSION';
    save();
    if (report.terminal) break;
    await new Promise(resolve => setTimeout(resolve, 5_000));
  }
  assert(report.terminal, 'Owned session terminal state remains unqualified; keep its capacity slot held');
  // Publication polling is after terminal cleanup, outside every product clock.
  const publicationDeadline=Math.min(terminalStarted+165_000,Date.now()+60_000);
  qualification.publicationAttempts=[];
  try {
    let qualifiedVersions=null;
    for(let attempt=0;attempt<12&&Date.now()<publicationDeadline;attempt++){
      const timeoutMs=Math.min(20_000,publicationDeadline-Date.now());
      const startedUtc=new Date().toISOString();
      const response=await fetch('https://api-cloud.browserstack.com/app-automate/builds/'+buildId+'/sessions/'+session+'/appiumlogs',{headers:{authorization:auth},signal:AbortSignal.timeout(timeoutMs)});
      const receipt={attempt,startedUtc,httpStatus:response.status,endpointKind:'App Automate owned build/session appiumlogs'};
      qualification.publicationAttempts.push(receipt);
      const chunks=[];let bytes=0;
      for await(const chunk of response.body){
        bytes+=chunk.byteLength;
        assert(bytes<=32*1024*1024,'Final Appium log exceeds retained body bound');
        chunks.push(chunk);
      }
      const original=Buffer.concat(chunks);
      let logs=original.toString('utf8');
      for(const secret of [process.env.BROWSERSTACK_USERNAME,process.env.BROWSERSTACK_ACCESS_KEY,process.env.RELAY_TOKEN])if(secret)logs=logs.replaceAll(secret,'[redacted]');
      Object.assign(receipt,{completedUtc:new Date().toISOString(),originalBytes:bytes,receivedBodySha256:createHash('sha256').update(original).digest('hex'),retainedBodySha256:createHash('sha256').update(logs).digest('hex'),retainedBytes:Buffer.byteLength(logs)});
      writeFileSync('evidence/appium-version-final-attempt-'+attempt+'.log',logs,{mode:0o600});
      saveQualification();
      if(response.ok&&bytes>0){
        const versions=[...logs.matchAll(/Appium v([0-9.]+) creating new AndroidUiautomator2Driver \(v([0-9.]+)\) session/g)];
        assert.equal(versions.length,1,'Final Appium creation record missing or ambiguous; all product observations unqualified');
        assert.deepEqual(versions[0].slice(1),['2.15.0','4.0.1'],'Final Appium or driver version mismatch; all product observations unqualified');
        qualifiedVersions=versions[0].slice(1);
        writeFileSync('evidence/appium-version-final-original.log',logs,{mode:0o600});
        Object.assign(qualification,{endpointKind:receipt.endpointKind,httpStatus:receipt.httpStatus,originalBytes:bytes,receivedBodySha256:receipt.receivedBodySha256,retainedBodySha256:receipt.retainedBodySha256,retainedBytes:receipt.retainedBytes});
        break;
      }
      assert(response.status===404||(response.ok&&bytes===0),'Final owned Appium log request failed; publication retry is not permitted for this response');
      const delay=Math.min(5_000,publicationDeadline-Date.now());
      if(delay>0)await new Promise(resolve=>setTimeout(resolve,delay));
    }
    assert(qualifiedVersions,'Final Appium publication deadline reached; all product observations unqualified');
    const pending=existsSync('evidence/automation-version-pending.json')?JSON.parse(readFileSync('evidence/automation-version-pending.json','utf8')):null;
    if(pending){assert.equal(pending.session,session);assert.equal(pending.buildId,buildId);}
    Object.assign(qualification,{buildId,state:'VERSION_QUALIFIED_REQUIRES_PRODUCT_REVIEW',versionQualified:true,appiumVersion:qualifiedVersions[0],driverVersion:qualifiedVersions[1],observedUtc:new Date().toISOString(),productAcceptanceAllowed:false});
    saveQualification();
  }catch(error){
    Object.assign(qualification,{buildId,state:'UNQUALIFIED',versionQualified:false,productAcceptanceAllowed:false,error:String(error),observedUtc:new Date().toISOString()});
    saveQualification();throw error;
  }
}
