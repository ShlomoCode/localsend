import assert from 'node:assert/strict';
import {readFileSync,appendFileSync,mkdirSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import path from 'node:path';
const username=process.env.BROWSERSTACK_USERNAME||process.env.BS_SPRINT_USERNAME;
const key=process.env.BROWSERSTACK_ACCESS_KEY||process.env.BS_SPRINT_ACCESS_KEY;
assert(username&&key&&process.env.GITHUB_ENV&&process.env.GITHUB_RUN_ID,'Actions credentials/environment required');
const evidence=process.env.TRANSFER_EVIDENCE_DIRECTORY||'evidence/issue3441';mkdirSync(evidence,{recursive:true});
const records=[];
for(const [index,file] of process.argv.slice(2).entries()) {
 const bytes=readFileSync(file),form=new FormData();form.set('file',new Blob([bytes]),index?'transport.apk':'fixture.apk');
 const response=await fetch('https://api-cloud.browserstack.com/app-automate/upload',{
  method:'POST',headers:{authorization:'Basic '+Buffer.from(username+':'+key).toString('base64')},body:form,signal:AbortSignal.timeout(180000)});
 assert(response.ok,'Helper upload failed HTTP '+response.status);
 const result=await response.json();assert(/^bs:\/\/[a-f0-9]+$/.test(result.app_url),'Helper upload reference missing');
 console.log('::add-mask::'+result.app_url);
 const variable=index?'RELAY_APP':'HELPER_APP';appendFileSync(process.env.GITHUB_ENV,variable+'='+result.app_url+'\n');
 records.push({kind:index?'opaque-transport':'MediaStore-fixture',bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex'),
  uploadReferenceSha256:createHash('sha256').update(result.app_url).digest('hex'),uploadUtc:new Date().toISOString(),runId:process.env.GITHUB_RUN_ID,runAttempt:process.env.GITHUB_RUN_ATTEMPT});
}
writeFileSync(path.join(evidence,'helper-upload-provenance.json'),JSON.stringify(records,null,2));
