import {createRequire} from 'node:module';
import {writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawn} from 'node:child_process';
if(process.platform==='win32'){
 const args=['--key',process.env.BROWSERSTACK_ACCESS_KEY,'--local-identifier',process.env.BS_LOCAL_ID,'--force-local','--only-automate','--enable-logging-for-api'];
 const binary=spawn('C:/tmp/bs-local-bin/BrowserStackLocal.exe',args,{windowsHide:true});
 let output='',ready=false;
 function capture(data){
  let line=data.toString();
  for(const secret of [process.env.BROWSERSTACK_ACCESS_KEY,process.env.BROWSERSTACK_USERNAME])if(secret)line=line.replaceAll(secret,'[redacted]');
  process.stdout.write(line);output=(output+line).slice(-12000);
  if(!ready&&/You can now access your local|Local Testing successfully connected/i.test(output)){
   ready=true;writeFileSync('C:/tmp/helper/local-ready','ready');console.log('BrowserStack Local ready');
  }
 }
 binary.stdout.on('data',capture);binary.stderr.on('data',capture);
 binary.on('error',error=>{console.error(error.message);process.exit(1);});
 binary.on('exit',code=>{console.error('Foreground BrowserStack Local exited '+code);process.exit(code||1);});
 process.on('SIGTERM',()=>binary.kill());
}else{
const require=createRequire(resolve('/tmp/bs-local/package.json'));
const {Local}=require('browserstack-local');
const local=new Local();
local.start({key:process.env.BROWSERSTACK_ACCESS_KEY,localIdentifier:process.env.BS_LOCAL_ID,forceLocal:true,onlyAutomate:true},err=>{
 if(err){console.error('BrowserStack Local startup failed');process.exit(1);}
 writeFileSync('/tmp/helper/local-ready','ready');console.log('BrowserStack Local ready');
});
process.on('SIGTERM',()=>local.stop(()=>process.exit()));
}
