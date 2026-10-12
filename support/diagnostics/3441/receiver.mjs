import {execFileSync,spawn} from "node:child_process";
import {existsSync,mkdirSync,readFileSync,writeFileSync,readdirSync,statSync,appendFileSync} from "node:fs";
import {createHash} from "node:crypto";
import path from "node:path";
import {setTimeout as delay} from "node:timers/promises";
import {relay} from "./transport/relay.mjs";
const root=path.resolve("evidence/issue3441"),bundle=process.env.APP_BUNDLE;
const destination=process.env.RECEIVER_DESTINATION;
const ax=path.join(process.env.RUNNER_TEMP,"issue3441/ax");
const tabs=Object.freeze({receive:"Receive\nTab 1 of 3",send:"Send\nTab 2 of 3",settings:"Settings\nTab 3 of 3"});
let screenIndex, bridge, active;
const events=[];
const owned=[];
function register(child,purpose,target){owned.push({pid:child.pid,purpose,target});writeFileSync(root+"/owned-processes.json",JSON.stringify(owned,null,2));}
async function boundedExit(exited,ms){let timer;const result=await Promise.race([exited,new Promise(resolve=>{timer=setTimeout(()=>resolve({timedOut:true}),ms);})]);clearTimeout(timer);return result;}
async function terminate(child,exited){
 child.kill("SIGTERM");let result=await boundedExit(exited,5000);
 if(result.timedOut){child.kill("SIGKILL");result=await boundedExit(exited,5000);}
 if(result.timedOut)throw Error("Owned capture process did not exit after SIGKILL");
 return result;
}
function log(action,detail={}){events.push({utc:new Date().toISOString(),monotonicNs:process.hrtime.bigint().toString(),action,...detail});writeFileSync(root+"/inputs.json",JSON.stringify(events,null,2));}
export function snapshot(label){
 const out=path.join(root,label);mkdirSync(out,{recursive:true});
 execFileSync("screencapture",["-x",out+"/screen.png"],{timeout:10000});
 const tree=JSON.parse(execFileSync(ax,[bundle],{encoding:"utf8",timeout:10000}));writeFileSync(out+"/ax.json",JSON.stringify(tree,null,2));log("snapshot",{label});return tree;
}
export function press(label){const result=execFileSync(ax,[bundle,label],{encoding:"utf8",timeout:10000});log("AXPress",{label,result:result.trim()});}
function hasLabel(tree,label){return tree.elements.some(e=>[e.AXTitle,e.AXDescription,e.AXValue].includes(label));}
function assertMainReceive(tree){
 const exactTabs=Object.values(tabs).every(label=>tree.elements.filter(e=>e.AXRole==="AXButton"&&e.AXEnabled==="1"&&[e.AXTitle,e.AXDescription,e.AXValue].includes(label)).length===1);
 if(!tree.pid||!tree.elements.some(e=>e.AXRole==="AXWindow")||!exactTabs||!hasLabel(tree,"Receive via link"))throw Error("Actual app Receive page/window with exact observed qualified navigation buttons not exposed by semantic backend");
}
function recording(name){
 const stderr=[];
 const child=spawn("ffmpeg",["-hide_banner","-y","-f","avfoundation","-framerate","10","-i",`${screenIndex}:none`,"-c:v","libx264","-preset","ultrafast","-pix_fmt","yuv420p",root+"/"+name+".mp4"],{stdio:["pipe","ignore","pipe"]});
 register(child,"recording",root+"/"+name+".mp4");
 writeFileSync(root+"/"+name+"-ffmpeg.log","");
 child.stderr.on("data",d=>{stderr.push(d);appendFileSync(root+"/"+name+"-ffmpeg.log",d);});log("recording-start",{name});
 let stdinError=null;
 child.stdin.on("error",error=>{stdinError=error.message;appendFileSync(root+"/"+name+"-ffmpeg.log",`\nstdin-error: ${error.message}\n`);});
 let completed=false;
 const exited=new Promise(resolve=>{child.once("error",error=>{completed=true;resolve({error:error.message});});child.once("exit",code=>{completed=true;resolve({code});});});
 return {child,stop:async()=>{
   if(!completed){
     try{await new Promise(resolve=>child.stdin.write("q\n",error=>{if(error)stdinError=error.message;resolve();}));}catch(error){stdinError=error.message;}
   }
   let result=await boundedExit(exited,15000);
   if(result.timedOut){await terminate(child,exited);result={error:"Recording shutdown timed out; owned process terminated and exit awaited"};}
   writeFileSync(root+"/"+name+"-ffmpeg.log",Buffer.concat(stderr));
   if(result.error||result.code!==0||stdinError)throw Error(result.error??stdinError??"Recording failed: "+result.code);
   writeFileSync(root+"/"+name+"-probe.json",execFileSync("ffprobe",["-v","error","-show_format","-show_streams","-of","json",root+"/"+name+".mp4"]));
   execFileSync("ffmpeg",["-v","error","-i",root+"/"+name+".mp4","-f","null","-"],{stdio:"inherit"});
   execFileSync("ffmpeg",["-v","error","-y","-i",root+"/"+name+".mp4","-frames:v","1",root+"/"+name+"-first-frame.png"],{stdio:"inherit"});
   log("recording-stop",{name});
 }};
}
export async function ready(){
 mkdirSync(root,{recursive:true});
 let launched=false,lastLaunchError;
 for(let i=0;i<10;i++){
   try{const launch=snapshot("first-launch-before-permission");if(launch.pid&&launch.elements.some(e=>e.AXRole==="AXWindow")){launched=true;break;}lastLaunchError=Error("App process has no native window yet");}catch(error){lastLaunchError=error;}
   await delay(500);
 }
 if(!launched)throw lastLaunchError;
 writeFileSync(root+"/first-launch-system-ax.json",execFileSync(ax,["--system"],{timeout:20000,maxBuffer:32*1024*1024}));
 const permission=JSON.parse(execFileSync(ax,["--allow-local-network"],{timeout:20000,maxBuffer:4*1024*1024}));
 writeFileSync(root+"/first-launch-permission.json",JSON.stringify(permission,null,2));log("native-local-network-permission",permission);
 if(permission.pressed){await delay(1500);snapshot("first-launch-after-permission");}
 const initial=snapshot("before-semantic-enablement");
 if(!hasLabel(initial,"Receive via link")){
   const probe=JSON.parse(execFileSync(ax,[bundle,"--enhance"],{timeout:10000}));writeFileSync(root+"/enhanced-accessibility.json",JSON.stringify(probe,null,2));
   log("AXEnhancedUserInterface-probe",probe);await delay(1500);snapshot("after-semantic-enablement");
 }
 let tree, lastError;
 let mainReady=false;
 for(let i=0;i<20;i++){try{tree=snapshot("readiness");assertMainReceive(tree);mainReady=true;break;}catch(e){lastError=e;}await delay(1500);}
 if(!mainReady)throw lastError;
 const listed=spawn("ffmpeg",["-hide_banner","-f","avfoundation","-list_devices","true","-i",""],{stdio:["ignore","ignore","pipe"]});
 register(listed,"device-list",null);let listing="";writeFileSync(root+"/capture-devices.txt","");
 listed.stderr.on("data",d=>{listing+=d;appendFileSync(root+"/capture-devices.txt",d);});
 const listingExited=new Promise(resolve=>{listed.once("error",e=>resolve({error:e.message}));listed.once("exit",code=>resolve({code}));});
 const listingResult=await boundedExit(listingExited,10000);
 if(listingResult.timedOut){await terminate(listed,listingExited);throw Error("Screen device enumeration timed out; partial stderr retained");}
 if(listingResult.error)throw Error(listingResult.error);
 writeFileSync(root+"/capture-devices.txt",listing);const match=listing.match(/\[(\d+)\] Capture screen 0/);if(!match)throw Error("No AVFoundation screen capture device");screenIndex=match[1];
 const control=recording("readiness-continuous");
 try{
   await delay(1500);snapshot("readiness-before-send");press(tabs.send);await delay(1500);
   const send=snapshot("readiness-send");if(send.pid!==tree.pid||!hasLabel(send,"Selection")||!hasLabel(send,"File"))throw Error("Send AXPress did not reach actual Send selection page");
   press(tabs.receive);await delay(1500);const receive=snapshot("readiness-after-receive");assertMainReceive(receive);if(receive.pid!==tree.pid)throw Error("App process changed during navigation");
   await delay(1500);
 }finally{await control.stop();}
 execFileSync("ffmpeg",["-v","error","-i",root+"/readiness-continuous.mp4","-f","null","-"],{stdio:"inherit"});
 execFileSync("codesign",["--verify","--deep","--strict","/Applications/LocalSend.app"],{stdio:"inherit"});
 writeFileSync(root+"/readiness.json",JSON.stringify({status:"ready",bundle,pid:tree.pid,destination,app:"unmodified official 1.18.2 DMG",portableProfile:false,screenIndex,mainReceive:true,sendSelection:true,actualAXPress:[tabs.send,tabs.receive],proof:"Native app navigation, semantic assertions and continuous capture; raw pixels still require inspection and no app transfer yet"},null,2));
}
export async function startRelay(){if(!process.env.RELAY_TOKEN)throw Error("Missing private relay token");bridge=relay({token:process.env.RELAY_TOKEN,reverseTargetPort:53317,transport:"stream"});await bridge.start();log("relay-start",{httpPort:8080,reverseTargetPort:53317,androidPort:53318,transport:"stream"});}
export async function startCase(name){
 if(active)throw Error("Case already active");
 const manifest=JSON.parse(readFileSync(root+"/fixtures/manifest.json"));const names=manifest.cases.find(c=>c.id===name)?.names;if(!names)throw Error("Unknown case");
 const expected=manifest.files.filter(f=>names.includes(f.name));
 const before=inventory();
 log("case-start",{name,expectedFiles:expected.length,existingDestinationNames:before.map(f=>f.name)});
 snapshot(name+"-before");const capture=recording(name+"-continuous");
 active={name,expected,before,capture,accepted:false,acceptFailure:null};
 active.poll=setInterval(()=>{
   if(active.accepted||active.acceptFailure)return;
   try{const tree=JSON.parse(execFileSync(ax,[bundle],{encoding:"utf8",timeout:10000,maxBuffer:4*1024*1024}));const buttons=tree.elements.filter(e=>e.AXRole==="AXButton"&&e.AXEnabled==="1"&&(e.AXTitle==="Accept"||e.AXDescription==="Accept"||e.AXValue==="Accept"));
     if(buttons.length===1){snapshot(name+"-approval");press("Accept");active.accepted=true;}
   }catch(e){active.acceptFailure=e.message;log("approval-harness-error",{message:e.message});}
 },1000);
}
export async function finishCase(){
 if(!active)throw Error("No active case");const c=active;clearInterval(c.poll);
 snapshot(c.name+"-after");
 const after=inventory();const beforeNames=new Set(c.before.map(f=>f.name));const added=after.filter(f=>!beforeNames.has(f.name));
 const files=c.expected.map(row=>{const dot=row.name.lastIndexOf(".");const base=row.name.slice(0,dot),ext=row.name.slice(dot);const candidates=added.filter(f=>f.name===row.name||(f.name.startsWith(base+" (")&&f.name.endsWith(")"+ext)));const matched=candidates.find(f=>f.bytes===row.bytes&&f.sha256===row.sha256);return {...row,actual:matched??null,candidates,match:Boolean(matched)};});
 const result={case:c.name,actualUIAccept:c.accepted,acceptFailure:c.acceptFailure,files,inventory:after,beforeInventory:c.before,recordingStatus:"pending stop and decode",passed:false};
 const save=()=>writeFileSync(root+"/"+c.name+"-result.json",JSON.stringify(result,null,2));
 // Saved bytes survive interrupted video finalization; pending/failed capture cannot pass a control.
 save();
 try{await c.capture.stop();result.recordingStatus="stopped and decoded";result.passed=c.accepted&&!c.acceptFailure&&files.every(f=>f.match);}
 catch(error){result.recordingStatus="infrastructure failure";result.recordingError=error.message;save();active=null;log("case-evidence-failure",{name:c.name,error:error.message});throw error;}
 save();active=null;log("case-finish",{name:c.name,passed:result.passed});return result;
}
export async function stopRelay(){
 if(active){
   const interrupted=active;clearInterval(interrupted.poll);
   try{await finishCase();}catch(error){active=null;let cleanupError=null;try{await interrupted.capture.stop();}catch(e){cleanupError=e.message;}writeFileSync(root+"/interrupted-case.json",JSON.stringify({case:interrupted.name,error:error.message,cleanupError},null,2));}
 }
 if(bridge){writeFileSync(root+"/relay-status.json",JSON.stringify(bridge.status(),null,2));writeFileSync(root+"/relay-trace.json",JSON.stringify(bridge.trace,null,2));await bridge.stop();bridge=null;}
}
if(process.argv[1]?.endsWith("/receiver.mjs")){
 try{await ready();}catch(error){writeFileSync(root+"/readiness-failure.json",JSON.stringify({stage:"receiver-readiness",classification:"infrastructure, no transfer attempted",error:error.message},null,2));throw error;}
}
function inventory(){return readdirSync(destination).map(name=>{const p=path.join(destination,name),stat=statSync(p);return {name,bytes:stat.size,isFile:stat.isFile(),sha256:stat.isFile()?createHash("sha256").update(readFileSync(p)).digest("hex"):null};});}
