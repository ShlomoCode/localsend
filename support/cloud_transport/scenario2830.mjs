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
  await exec("pwsh",["-NoProfile","-File","support/diagnostics/windows2830-startup.ps1","-OutputDirectory","evidence","-ReleaseVersion","1.17.0","-AssetArchitecture","x86-64","-RunnerLabel","windows-11-arm","-DiagnosticPeerPort",String(senderPort),"-StartupOnly"]);
  await snapshot("receiver-before");
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
   if(!source.includes("Copy")||!source.includes("Close"))throw new Error(`${name}: actual receiver text preview did not become observable; classify UI/transport readiness before attributing failure`);
   const expected=readFileSync(`evidence/${name}.txt`,"utf8");
   if(name==="short"&&!source.includes(expected))throw new Error("Short control preview differs from Windows clipboard");
   await diagnostic(`${name}-processes`,"dumpsys activity -p org.localsend.localsend_app processes");
   await diagnostic(`${name}-memory`,"dumpsys meminfo org.localsend.localsend_app");
   await click("Copy");await pause(800);const after=await snapshot(`${name}-after-copy`);
   if(after.includes("Copy")&&after.includes("Close"))throw new Error(`${name}: receiver Copy did not dismiss the text page`);
   let copied=null;try{copied=await wd("POST",`/session/${session}/appium/device/get_clipboard`,{contentType:"plaintext"});writeFileSync(`evidence/${name}-clipboard.txt`,Buffer.from(copied,"base64"));}catch(e){writeFileSync(`evidence/${name}-clipboard-unavailable.txt`,String(e));}
   if(copied===null)throw new Error(`${name}: received clipboard content could not be verified`);
   if(Buffer.from(copied,"base64").toString()!==expected)throw new Error(`${name}: received clipboard content differs`);
   results.push({name,previewVisible:true,copyResponsive:true,sourceMatches:name==="short",clipboardVerified:copied!==null});
   if(name!==cases.at(-1))throw new Error("Additional cases require verified Windows selection reset; initial run intentionally stops after short control");
  }
 } finally {writeFileSync("evidence/scenario-results.json",JSON.stringify({results,transport:transportStatus()},null,2));}
}
