import {execFile} from "node:child_process";
import {promisify} from "node:util";
import {readFileSync,writeFileSync,appendFileSync} from "node:fs";
const exec=promisify(execFile), pause=ms=>new Promise(r=>setTimeout(r,ms));
export default async function({session,wd,senderPort,transportStatus}) {
 const results=[];
 const event=(name,detail={})=>appendFileSync("evidence/timeline.jsonl",JSON.stringify({utc:new Date().toISOString(),name,...detail})+"\n");
 async function ui(action,x,y,label){await exec("pwsh",["-NoProfile","-File","support/diagnostics/windows2830-ui.ps1","-Action",action,"-X",String(x),"-Y",String(y),"-Label",label]);event("windows-ui",{action,x,y,label});}
 async function snapshot(label){
  const start=Date.now();
  event("receiver-source-start",{label});
  const xml=await wd("GET",`/session/${session}/source`);writeFileSync(`evidence/${label}.xml`,xml);event("receiver-source",{label,ms:Date.now()-start,chars:xml.length,copy:xml.includes("Copy"),close:xml.includes("Close")});
  const png=await wd("GET",`/session/${session}/screenshot`);writeFileSync(`evidence/${label}.png`,Buffer.from(png,"base64"));return xml;
 }
 async function click(label){const e=await wd("POST",`/session/${session}/element`,{using:"accessibility id",value:label});event("receiver-input",{label});await wd("POST",`/session/${session}/element/${e["element-6066-11e4-a52e-4f735466cecf"]}/click`,{});}
 async function diagnostic(label,command){try{const result=await wd("POST",`/session/${session}/execute/sync`,{script:"browserstack_executor: "+JSON.stringify({action:"adbShell",arguments:{command}}),args:[]});writeFileSync(`evidence/${label}.txt`,typeof result==="string"?result:JSON.stringify(result));}catch(e){writeFileSync(`evidence/${label}-unavailable.txt`,String(e));}}
 try {
  await exec("pwsh",["-NoProfile","-File","support/diagnostics/windows2830-startup.ps1","-OutputDirectory","evidence","-ReleaseVersion","1.17.0","-AssetArchitecture","x86-64","-RunnerLabel","windows-11-arm","-DiagnosticPeerPort",String(senderPort),"-DiagnosticDiscoveryTimeout",process.env.DISCOVERY_TIMEOUT_MS||"500","-StartupOnly"]);
  await snapshot("receiver-before");
  await diagnostic("receiver-miui","getprop ro.miui.ui.version.name");
  await diagnostic("receiver-build","getprop ro.build.fingerprint");
  await diagnostic("receiver-before-processes","dumpsys activity -p org.localsend.localsend_app processes");
  await diagnostic("receiver-before-memory","dumpsys meminfo org.localsend.localsend_app");
  const cases=(process.env.CLIPBOARD_CASES||"short").split(",");
  for(const name of cases){
   await exec("pwsh",["-NoProfile","-STA","-File","support/diagnostics/windows2830-clipboard.ps1","-Case",name]);
   event("clipboard-ready",{name,...JSON.parse(readFileSync(`evidence/${name}-fixture.json`,"utf8").replace(/^\uFEFF/,""))});
   await ui("click",380,85,`${name}-windows-clipboard`);
   await ui("click",246,266,`${name}-windows-favorites`);
   event("send-target",{name,transportBefore:transportStatus()});await ui("click",145,205,`${name}-windows-target`);
   let source="";
   for(let attempt=0;attempt<12;attempt++){
    source=await snapshot(`${name}-receiver-${attempt}`);
    if(source.includes("Copy")&&source.includes("Close")){event("preview-visible",{name,attempt,transport:transportStatus()});break;}
    await pause(1000);
   }
   if(!source.includes("Copy")||!source.includes("Close")){
    await ui("click",136,259,`${name}-windows-error-details`);
    throw new Error(`${name}: actual receiver text preview did not become observable; classify UI/transport readiness before attributing failure`);
   }
   const expected=readFileSync(`evidence/${name}.txt`,"utf8");
   if(name==="short"&&!source.includes(expected))throw new Error("Short control preview differs from Windows clipboard");
   await diagnostic(`${name}-processes`,"dumpsys activity -p org.localsend.localsend_app processes");
   await diagnostic(`${name}-memory`,"dumpsys meminfo org.localsend.localsend_app");
   const interaction=process.env.RECEIVER_INTERACTION||"none";
   if(interaction!=="none"){
    const scrollNode=source.match(/<android.widget.ScrollView[^>]*>/)?.[0];
    const bounds=scrollNode?.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
    if(!bounds)throw new Error("Receiver text ScrollView bounds unavailable for requested interaction");
    const [,left,top,right,bottom]=bounds.map(Number), x=Math.round((left+right)/2);
    const yStart=bottom-30,yEnd=top+30;
    const actions=[{type:"pointerMove",duration:0,x,y:interaction==="scroll"?yStart:Math.round((top+bottom)/2)},{type:"pointerDown",button:0}];
    if(interaction==="scroll")actions.push({type:"pointerMove",duration:600,x,y:yEnd});
    else if(interaction==="select")actions.push({type:"pause",duration:1200});
    else throw new Error("Unsupported receiver interaction "+interaction);
    actions.push({type:"pointerUp",button:0});
    event("receiver-gesture",{name,interaction,bounds:[left,top,right,bottom],actions});
    await wd("POST",`/session/${session}/actions`,{actions:[{type:"pointer",id:"receiver-touch",parameters:{pointerType:"touch"},actions}]});
    await pause(800);await snapshot(`${name}-after-${interaction}`);
    if(interaction==="select"){
     const dismiss=[{type:"pointerMove",duration:0,x,y:top-120},{type:"pointerDown",button:0},{type:"pointerUp",button:0}];
     event("receiver-selection-dismiss",{name,x,y:top-120});
     await wd("POST",`/session/${session}/actions`,{actions:[{type:"pointer",id:"receiver-touch",parameters:{pointerType:"touch"},actions:dismiss}]});
     await snapshot(`${name}-selection-dismissed`);
    }
   }
   if(interaction==="none")await click("Copy");
   else {
    const copyNode=source.match(/<android.widget.Button[^>]*content-desc="Copy"[^>]*>/)?.[0];
    const b=copyNode?.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
    if(!b)throw new Error("Original message Copy button bounds unavailable");
    const [,left,top,right,bottom]=b.map(Number),x=Math.round((left+right)/2),y=Math.round((top+bottom)/2);
    event("receiver-main-copy",{name,x,y});
    await wd("POST",`/session/${session}/actions`,{actions:[{type:"pointer",id:"receiver-touch",parameters:{pointerType:"touch"},actions:[{type:"pointerMove",duration:0,x,y},{type:"pointerDown",button:0},{type:"pointerUp",button:0}]}]});
   }
   await pause(800);const after=await snapshot(`${name}-after-copy`);
   if(after.includes("Copy")&&after.includes("Close"))throw new Error(`${name}: receiver Copy did not dismiss the text page`);
   let copied=null;try{copied=await wd("POST",`/session/${session}/appium/device/get_clipboard`,{contentType:"plaintext"});writeFileSync(`evidence/${name}-clipboard.txt`,Buffer.from(copied,"base64"));}catch(e){writeFileSync(`evidence/${name}-clipboard-unavailable.txt`,String(e));}
   if(copied===null)throw new Error(`${name}: received clipboard content could not be verified`);
   if(Buffer.from(copied,"base64").toString()!==expected)throw new Error(`${name}: received clipboard content differs`);
   results.push({name,receiverInteraction:interaction,previewVisible:true,copyResponsive:true,sourceMatches:name==="short"?true:null,clipboardVerified:copied!==null});
   if(name!==cases.at(-1))throw new Error("Additional cases require verified Windows selection reset; initial run intentionally stops after short control");
  }
 } finally {writeFileSync("evidence/scenario-results.json",JSON.stringify({results,transport:transportStatus()},null,2));}
}
