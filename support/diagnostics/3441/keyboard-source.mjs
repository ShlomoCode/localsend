import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
assert(process.env.GITHUB_ACTIONS==='true'&&process.env.GITHUB_REPOSITORY==='ShlomoCode/localsend'&&process.env.ISSUE3441_ADMITTED==='1'&&process.env.ISSUE3441_KEYBOARD_SOURCE_PROBE==='1','Admitted fork keyboard observation required');
const output='evidence/issue3441/android';mkdirSync(output,{recursive:true});
const cutoff=Date.parse(process.env.ISSUE3441_JOB_DEADLINE_UTC)-4*60000;
assert(Number.isFinite(cutoff)&&cutoff>Date.now(),'Observation/cleanup budget expired');
const child=spawn(process.execPath,['--input-type=module','-e',`
import {runAndroidSender} from './support/diagnostics/3441-android/controller.mjs';
await runAndroidSender({output:'evidence/issue3441/android',fixtureDirectory:process.env.FIXTURE_DIRECTORY});
`],{stdio:'inherit'});
let cutoffReached=false,killTimer;
const timer=setTimeout(()=>{cutoffReached=true;child.kill('SIGTERM');killTimer=setTimeout(()=>child.kill('SIGKILL'),1000);},cutoff-Date.now());
const result=await new Promise(resolve=>{child.once('error',error=>resolve({error:error.message}));child.once('exit',(code,signal)=>resolve({code,signal}));});
clearTimeout(timer);clearTimeout(killTimer);
writeFileSync(output+'/keyboard-supervisor.json',JSON.stringify({cutoffUtc:new Date(cutoff).toISOString(),cutoffReached,...result,productExperiments:0},null,2));
if(result.error||result.code!==0||cutoffReached)process.exitCode=1;
