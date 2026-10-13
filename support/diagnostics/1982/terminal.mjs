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
  // Final logs bind this session's creation environment; pending observations are not verdicts.
  try {
    const response=await fetch('https://api-cloud.browserstack.com/app-automate/builds/'+buildId+'/sessions/'+session+'/appiumlogs',{headers:{authorization:auth},signal:AbortSignal.timeout(20_000)});
    qualification.endpointKind='App Automate owned build/session appiumlogs';
    qualification.httpStatus=response.status;
    assert(response.ok,'Final owned Appium log unavailable');
    const chunks=[];let bytes=0;
    for await(const chunk of response.body){
      bytes+=chunk.byteLength;
      assert(bytes<=32*1024*1024,'Final Appium log exceeds retained body bound');
      chunks.push(chunk);
    }
    const original=Buffer.concat(chunks);
    qualification.receivedBodySha256=createHash('sha256').update(original).digest('hex');
    let logs=original.toString('utf8');
    for(const secret of [process.env.BROWSERSTACK_USERNAME,process.env.BROWSERSTACK_ACCESS_KEY,process.env.RELAY_TOKEN])if(secret)logs=logs.replaceAll(secret,'[redacted]');
    qualification.retainedBodySha256=createHash('sha256').update(logs).digest('hex');
    qualification.retainedBytes=Buffer.byteLength(logs);
    writeFileSync('evidence/appium-version-final-original.log',logs,{mode:0o600});
    const versions=[...logs.matchAll(/Appium v([0-9.]+) creating new AndroidUiautomator2Driver \(v([0-9.]+)\) session/g)];
    assert.equal(versions.length,1,'Final Appium creation record missing or ambiguous; all product observations unqualified');
    assert.deepEqual(versions[0].slice(1),['2.15.0','4.0.1'],'Final Appium or driver version mismatch; all product observations unqualified');
    const pending=existsSync('evidence/automation-version-pending.json')?JSON.parse(readFileSync('evidence/automation-version-pending.json','utf8')):null;
    if(pending){assert.equal(pending.session,session);assert.equal(pending.buildId,buildId);}
    Object.assign(qualification,{buildId,state:'VERSION_QUALIFIED_REQUIRES_PRODUCT_REVIEW',versionQualified:true,appiumVersion:versions[0][1],driverVersion:versions[0][2],originalBytes:bytes,observedUtc:new Date().toISOString(),productAcceptanceAllowed:false});
    saveQualification();
  }catch(error){
    Object.assign(qualification,{buildId,state:'UNQUALIFIED',versionQualified:false,productAcceptanceAllowed:false,error:String(error),observedUtc:new Date().toISOString()});
    saveQualification();throw error;
  }

}
