import {existsSync,readFileSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
const root=path.resolve('evidence/issue3441');
const file=root+'/owned-processes.json';
const result=[];
function signal(pid,name){try{globalThis.process.kill(pid,name);return true;}catch(error){if(error.code==='ESRCH')return false;throw error;}}
if(existsSync(file))for(const process of JSON.parse(readFileSync(file))){
 if(!Number.isSafeInteger(process.pid)||process.pid<=1)continue;
 let args;
 try{args=execFileSync('ps',['-p',String(process.pid),'-o','command='],{encoding:'utf8'}).trim();}catch{result.push({...process,status:'already exited'});continue;}
 const owned=args.includes('ffmpeg')&&(process.target?args.includes(process.target):process.purpose==='device-list'&&args.includes('-list_devices true'));
 if(!owned){result.push({...process,status:'identity no longer matches; preserved'});continue;}
 if(!signal(process.pid,'SIGTERM')){result.push({...process,status:'already exited before TERM'});continue;}
 let alive=true;for(let i=0;i<20;i++){try{globalThis.process.kill(process.pid,0);}catch{alive=false;break;}await delay(250);}
 if(alive){if(!signal(process.pid,'SIGKILL'))alive=false;for(let i=0;alive&&i<20;i++){try{globalThis.process.kill(process.pid,0);}catch{alive=false;break;}await delay(250);}}
 result.push({...process,status:alive?'did not exit':'terminated and exit observed'});
}
if(existsSync(root))writeFileSync(root+'/cleanup.json',JSON.stringify(result,null,2));
if(result.some(p=>p.status==='did not exit'))throw Error('Owned capture cleanup failed');
