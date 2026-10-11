import {createRequire} from 'node:module';
import {writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
const require=createRequire(resolve('/tmp/bs-local/package.json'));
const {Local}=require('browserstack-local');
const local=new Local();
local.start({key:process.env.BROWSERSTACK_ACCESS_KEY,localIdentifier:process.env.BS_LOCAL_ID,forceLocal:true,onlyAutomate:true},err=>{
 if(err){console.error('BrowserStack Local startup failed');process.exit(1);}
 writeFileSync('/tmp/helper/local-ready','ready');console.log('BrowserStack Local ready');
});
process.on('SIGTERM',()=>local.stop(()=>process.exit()));
