import {writeFileSync} from 'node:fs';

const helperPackage='org.localsend.cloudtransport';
const serviceName='org.localsend.cloudtransport/.RelayService';
let helperIdentity;

// Ordinary-service survival is a harness qualification, never a LocalSend
// reproduction. Observe without activating the helper during a pending receive.
export async function observeHelper({session,wd,label,transportSnapshot,expectBackground=true}) {
 const stem=`evidence/${label}-ordinary-helper`;
 const record={started:new Date().toISOString(),requiredMode:'ordinary',expectBackground};
 const save=()=>writeFileSync(`${stem}.json`,JSON.stringify(record,null,2));
 async function shell(name,command){
  const value=await wd('POST',`/session/${session}/execute/sync`,{script:'browserstack_executor: '+JSON.stringify({action:'adbShell',arguments:{command}}),args:[]},{timeoutMs:12000});
  if(typeof value!=='string')throw new Error(`Helper ${name} did not return native text`);
  writeFileSync(`${stem}-${name}.txt`,value);return value;
 }
 try{
  record.transportBefore=transportSnapshot();save();
  const processes=await shell('processes',`dumpsys activity -p ${helperPackage} processes`);
  const services=await shell('services',`dumpsys activity services ${helperPackage}`);
  // Require the exact single service's own block, not another app's foreground flag.
  const blocks=services.split(/(?=\* ServiceRecord\{)/).filter(block=>block.startsWith('* ServiceRecord{')&&block.split('\n',1)[0].includes(serviceName));
  if(blocks.length!==1)throw new Error('Ordinary helper service identity is missing or ambiguous');
  const serviceBlock=blocks[0];
  if(!/\bisForeground=false\b/.test(serviceBlock)||/\bisForeground=true\b/.test(serviceBlock))throw new Error('Helper is foreground or native foreground state is unavailable');
  if(!/\bstartRequested=true\b/.test(serviceBlock))throw new Error('Helper service has not recorded a requested start');
  const identity=processes.match(/\*APP\* UID (\d+) ProcessRecord\{[^\n]*? (\d+):org\.localsend\.cloudtransport\//);
  if(!identity)throw new Error('Helper native process identity is unavailable');
  const current={uid:Number(identity[1]),pid:Number(identity[2])};
  if(helperIdentity&&(helperIdentity.uid!==current.uid||helperIdentity.pid!==current.pid))throw new Error('Ordinary helper restarted; comparison is a harness failure');
  helperIdentity=current;
  if(!serviceBlock.includes(`${current.pid}:${helperPackage}/`))throw new Error('Helper service is not attached to the observed helper process');
  const state=processes.match(/\bcurProcState=(\d+)\b/);
  if(!state)throw new Error('Helper process state is unavailable');
  if(expectBackground&&Number(state[1])<=2)throw new Error('Helper still has a foreground activity during the comparison');
  if(!/\bisFrozen=false\b/.test(processes)||/\bisFrozen=true\b/.test(processes))throw new Error('Ordinary helper is frozen or native freeze state is unavailable');
  record.native={...current,curProcState:Number(state[1]),isForeground:false,isFrozen:false,startRequested:true};
  // Poll renewals and peer events are retained for independent health analysis;
  // pollPending by itself is deliberately not treated as proof of health.
  record.transportAfter=transportSnapshot();
  if(!record.transportAfter.trace.some(event=>event.origin==='poll-open'))throw new Error('No external helper poll has been observed');
  record.nativeQualified=true;
  record.transportHealthRequiresTraceReview=true;
  try{
   const startup=await shell('startup-log','logcat -d -s CloudTransport:I');
   record.relayStartupTraceMatched=startup.includes('service-start:mode=ordinary:target=53317');
  }catch(error){record.startupTraceUnavailable=String(error);}
 }catch(error){record.error=String(error);throw error;}
 finally{record.ended=new Date().toISOString();save();}
}
