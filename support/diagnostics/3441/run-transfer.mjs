import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {writeFileSync} from 'node:fs';
assert(process.env.GITHUB_ACTIONS==='true'&&process.env.GITHUB_REPOSITORY==='ShlomoCode/localsend'&&process.env.ISSUE3441_ADMITTED==='1','Admitted fork Actions job required');
const cutoff=Date.parse(process.env.ISSUE3441_JOB_DEADLINE_UTC)-8*60000;
assert(Number.isFinite(cutoff)&&cutoff>Date.now(),'No transfer time remains before final cleanup steps');
const child=spawn(process.execPath,['support/diagnostics/3441/transfer.mjs'],{stdio:'inherit'});
let cutoffReached=false,killTimer;
const timer=setTimeout(()=>{
  cutoffReached=true;
  child.kill('SIGTERM');
  killTimer=setTimeout(()=>child.kill('SIGKILL'),1000);
},cutoff-Date.now());
const result=await new Promise(resolve=>{
  child.once('error',error=>resolve({error:error.message}));
  child.once('exit',(code,signal)=>resolve({code,signal}));
});
clearTimeout(timer);clearTimeout(killTimer);
writeFileSync('evidence/issue3441/transfer-supervisor.json',JSON.stringify({cutoffUtc:new Date(cutoff).toISOString(),cutoffReached,...result,classification:cutoffReached?'Infrastructure time budget exhausted; independent owned cleanup follows':'Child completion'},null,2));
if(result.error||result.code!==0||cutoffReached)process.exitCode=1;
