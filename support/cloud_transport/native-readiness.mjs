import {writeFileSync} from "node:fs";

// Source and control RPCs are separate observations, never an atomic UI snapshot.
// Mutating clicks are performed once by callers; ambiguous transport errors stop.
export async function waitForNativeControl({wd,prefix,using,value,label,timeoutMs=10000,optional=false,sourceIncludes=[],requireClickable=true,requireEnabled=true,stable=true,choices}) {
 const started=Date.now(),deadline=started+timeoutMs,observations=[];
 const transient=error=>/no such element|stale element reference/.test(String(error));
 const targets=choices||[{using,value}];
 let previous=null,attempt=0;
 const save=()=>writeFileSync(`evidence/${label}-readiness.json`,JSON.stringify({started:new Date(started).toISOString(),deadline:new Date(deadline).toISOString(),timeoutMs,elapsedMs:Date.now()-started,targets,sourceIncludes,requireClickable,requireEnabled,stable,observations},null,2));
 async function rpc(method,path,body){
  const remaining=deadline-Date.now();
  if(remaining<=0)throw new Error(`Readiness deadline reached: ${label}`);
  const call={method,path:path.replace(/\/session\/[^/]+/,"/session/owned"),started:new Date().toISOString(),timeoutMs:remaining};
  observations.at(-1).rpcs.push(call);
  try{return await wd(method,path,body,{timeoutMs:remaining});}
  catch(error){call.error=String(error);throw error;}
  finally{call.elapsedMs=Date.now()-Date.parse(call.started);save();}
 }
 try {
  while(Date.now()<deadline){
   const record={utc:new Date().toISOString(),sourceFile:`evidence/${label}-readiness-${attempt++}.xml`,rpcs:[],found:false};observations.push(record);
   const xml=await rpc("GET",prefix+"/source");writeFileSync(record.sourceFile,xml);
   record.screenMatched=sourceIncludes.every(marker=>xml.includes(marker));
   let viewport=null;
   let candidate=null;
   if(record.screenMatched){
    viewport=await rpc("GET",prefix+"/window/rect");record.viewport={authority:"Appium window rect",...viewport};
    for(let choice=0;choice<targets.length;choice++){
     const target=targets[choice];
     if(!(target.sourceIncludes||[]).every(marker=>xml.includes(marker)))continue;
     try {
      const element=await rpc("POST",prefix+"/element",{using:target.using,value:target.value});
      const id=element["element-6066-11e4-a52e-4f735466cecf"],base=prefix+"/element/"+id;
      const enabled=await rpc("GET",base+"/enabled");
      const displayed=await rpc("GET",base+"/displayed");
      const clickable=await rpc("GET",base+"/attribute/clickable");
      const rect=await rpc("GET",base+"/rect");
      const inViewport=!!viewport&&rect.width>0&&rect.height>0&&rect.x>=viewport.x&&rect.y>=viewport.y&&rect.x+rect.width<=viewport.x+viewport.width&&rect.y+rect.height<=viewport.y+viewport.height;
      Object.assign(record,{found:true,choice,locator:target,enabled,displayed,clickable,rect,inViewport,elementId:id});
      if((!requireEnabled||enabled)&&displayed&&(!requireClickable||clickable===true||clickable==="true")&&inViewport){candidate={element,choice,rect};break;}
     }catch(error){if(!transient(error))throw error;record.transientError=String(error);}
    }
   }
   const key=candidate?JSON.stringify({choice:candidate.choice,rect:candidate.rect}):null;
   record.stable=!!key&&key===previous;save();
   if(candidate&&(!stable||record.stable)){candidate.element.readiness={label,choice:candidate.choice,rect:candidate.rect,sourceFile:record.sourceFile,observed:new Date().toISOString()};return candidate.element;}
   previous=key;
   await new Promise(resolve=>setTimeout(resolve,Math.min(200,Math.max(0,deadline-Date.now()))));
  }
 }catch(error){observations.at(-1).error=String(error);save();throw error;}
 save();
 if(optional)return null;
 throw new Error(`Actual native control did not become ready: ${label}`);
}
