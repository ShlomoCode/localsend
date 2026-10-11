import assert from 'node:assert/strict';
import {mkdirSync,readFileSync,symlinkSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import physicalControl from './2007-physical-control.mjs';

// Same allocated device: prove immediate name reuse failure, observe/purge the
// owned Trash item, retry through the real apps, then verify a fresh-name receive.
export default async function(context){
 const root=process.cwd(),run=process.env.GITHUB_RUN_ID;
 assert(/^[0-9]+$/.test(run),'Unique runner ownership is required');
 const summary={session:context.session,startedUtc:new Date().toISOString(),arms:[]};
 const summaryPath=join(root,'evidence/storage-session-summary.json');
 for(const [index,armName] of ['purge','fresh'].entries()){
  const directory=join(root,'.diagnostic-arms',`storage-${armName}`);
  const evidence=join(root,'evidence',`storage-${armName}`,'evidence');
  mkdirSync(directory,{recursive:true});mkdirSync(evidence,{recursive:true});
  symlinkSync(evidence,join(directory,'evidence'),'dir');
  for(const name of ['support','released'])symlinkSync(join(root,name),join(directory,name),'dir');
  Object.assign(process.env,{ISSUE_2007_FIXTURE_NAME:`2007-${run}-${armName}.txt`,ISSUE_2007_FIXTURE_SEED:run,ISSUE_2007_STORAGE_OBSERVER:'1',ISSUE_2007_OBSERVER_PREPARED:index===0?'0':'1',ISSUE_2007_REPEAT_RESEND:index===0?'1':'0',ISSUE_2007_BASELINE_ONLY:index===0?'0':'1',ISSUE_2007_RETRY_INTERVENTION:'purge',ISSUE_2007_DELETE_TIMING:'absence',ISSUE_2007_DELETE_ACTION:'trash',ISSUE_2007_VARIANT:'unchanged',ISSUE_2007_POST_DELETE_WAIT:'0',ISSUE_2007_RESTART_RECEIVER:'0',ISSUE_2007_PRESERVE_DESTINATION:index===0?'0':'1'});
  const arm={armName,fixtureName:process.env.ISSUE_2007_FIXTURE_NAME,startedUtc:new Date().toISOString(),evidenceDirectory:`storage-${armName}/evidence`};summary.arms.push(arm);
  writeFileSync(summaryPath,JSON.stringify(summary,null,2));
  process.chdir(directory);
  try{
   await physicalControl(context);
   arm.baseline=JSON.parse(readFileSync(join(evidence,'actual-app-control.json'),'utf8'));
   if(index===0)for(const [key,file] of [['firstResend','actual-resend-result.json'],['retry','actual-retry-result.json'],['intervention','retry-intervention.json']])arm[key]=JSON.parse(readFileSync(join(evidence,file),'utf8'));
   arm.completedUtc=new Date().toISOString();
  }catch(error){arm.error=String(error);throw error;}
  finally{process.chdir(root);writeFileSync(summaryPath,JSON.stringify(summary,null,2));}
 }
 assert.equal(summary.arms[0].baseline.sha256,summary.arms[1].baseline.sha256,'Fresh-name control must have the same content');
 summary.completedUtc=new Date().toISOString();writeFileSync(summaryPath,JSON.stringify(summary,null,2));
}
