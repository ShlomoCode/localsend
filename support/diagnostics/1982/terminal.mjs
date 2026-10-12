import assert from 'node:assert/strict';
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
    report.observations.push({checkedUtc:new Date().toISOString(), session, status:value?.status, reason:value?.reason, duration:value?.duration});
    // Test pass/fail labels are not lifecycle evidence. Require the explicit stopped receipt.
    report.terminal = value?.status === 'done' && value?.reason === 'CLIENT_STOPPED_SESSION';
    save();
    if (report.terminal) break;
    await new Promise(resolve => setTimeout(resolve, 5_000));
  }
  assert(report.terminal, 'Owned session terminal state remains unqualified; keep its capacity slot held');
}
