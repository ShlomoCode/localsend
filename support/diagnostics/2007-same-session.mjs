import assert from 'node:assert/strict';
import {existsSync,mkdirSync,readFileSync,symlinkSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import physicalControl from './2007-physical-control.mjs';

// Both arms retain the same allocated Android device, installation, provider,
// and WebDriver session. Only the retry's receiver restart differs.
export default async function(context){
 assert.notEqual(process.platform,'win32','Same-session experiment requires the Linux GUI sender');
 const root=process.cwd();
 const summary={session:context.session,startedUtc:new Date().toISOString(),matchedDelayMs:45000,arms:[],fixtureBytes:'Existing fixed original-app fixture, with the same seed in both arms',resetBetweenArms:'Actual receiver Done returns to Ready; no reinstall, provider reset, or trash cleanup'};
 const variables=['ISSUE_2007_FIXTURE_NAME','ISSUE_2007_REPEAT_RESEND','ISSUE_2007_RETRY_INTERVENTION','ISSUE_2007_DELETE_TIMING','ISSUE_2007_DELETE_ACTION','ISSUE_2007_VARIANT','ISSUE_2007_POST_DELETE_WAIT','ISSUE_2007_RESTART_RECEIVER','ISSUE_2007_PRESERVE_DESTINATION','ISSUE_2007_FIXTURE_SEED'];
 const previous=Object.fromEntries(variables.map(key=>[key,process.env[key]]));
 mkdirSync(join(root,'evidence'),{recursive:true});
 const summaryPath=join(root,'evidence/same-session-summary.json');
 try{
  const fixtureSeed=previous.ISSUE_2007_FIXTURE_SEED||process.env.GITHUB_RUN_ID;
  assert(fixtureSeed,'Both arms require the same nonempty fixture seed');
  process.env.ISSUE_2007_FIXTURE_SEED=fixtureSeed;
  for(const [index,intervention] of ['wait','restart'].entries()){
   const fixtureName=`2007-${intervention}.txt`;
   const armDirectory=join(root,'.diagnostic-arms',`same-session-${intervention}`);
   const armEvidence=join(root,'evidence',`same-session-${intervention}`,'evidence');
   assert(!existsSync(armDirectory),'Arm output must be fresh; refuse to reuse stale milestones');
   assert(!existsSync(armEvidence),'Arm evidence must be fresh; refuse to reuse stale milestones');
   mkdirSync(armDirectory,{recursive:true});
   mkdirSync(armEvidence,{recursive:true});
   symlinkSync(armEvidence,join(armDirectory,'evidence'),'dir');
   for(const directory of ['support','released'])symlinkSync(join(root,directory),join(armDirectory,directory),'dir');
   Object.assign(process.env,{ISSUE_2007_FIXTURE_NAME:fixtureName,ISSUE_2007_REPEAT_RESEND:'1',ISSUE_2007_RETRY_INTERVENTION:intervention,ISSUE_2007_DELETE_TIMING:'absence',ISSUE_2007_DELETE_ACTION:'trash',ISSUE_2007_VARIANT:'unchanged',ISSUE_2007_POST_DELETE_WAIT:'0',ISSUE_2007_RESTART_RECEIVER:'0',ISSUE_2007_PRESERVE_DESTINATION:index===0?'0':'1'});
   const arm={intervention,fixtureName,session:context.session,startedUtc:new Date().toISOString(),evidenceDirectory:`same-session-${intervention}/evidence`};
   summary.arms.push(arm);
   writeFileSync(summaryPath,JSON.stringify(summary,null,2));
   process.chdir(armDirectory);
   try{
    await context.wd('POST',`/session/${context.session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});
    await physicalControl(context);
    for(const [field,file] of [['baseline','actual-app-control.json'],['firstResend','actual-resend-result.json'],['retry','actual-retry-result.json'],['timing','retry-intervention.json']])arm[field]=JSON.parse(readFileSync(join(armDirectory,'evidence',file),'utf8'));
    arm.completedUtc=new Date().toISOString();
   }catch(error){arm.error=String(error);throw error;}
   finally{process.chdir(root);writeFileSync(summaryPath,JSON.stringify(summary,null,2));}
  }
  assert.equal(summary.arms[0].baseline.sha256,summary.arms[1].baseline.sha256,'Arms must send identical fixed fixture bytes');
  summary.completedUtc=new Date().toISOString();
 }finally{
  process.chdir(root);
  for(const key of variables){if(previous[key]===undefined)delete process.env[key];else process.env[key]=previous[key];}
  writeFileSync(summaryPath,JSON.stringify(summary,null,2));
 }
}
