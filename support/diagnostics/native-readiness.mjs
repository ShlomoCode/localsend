import {writeFileSync} from 'node:fs';

// Read a fresh page and query an enabled, visible control after native navigation.
// Retry only transient element absence/staleness; transport errors remain errors.
export async function waitForNativeControl({wd,prefix,using,value,label,timeoutMs=10000,optional=false,stableRect=false}) {
 const deadline=Date.now()+timeoutMs;
 const observations=[];
 const transient=error=>/no such element|stale element reference/.test(String(error));
 let attempt=0;
 let previousRect=null;
 do {
  const source=await wd('GET',prefix+'/source');
  const sourceFile=`evidence/${label}-readiness-${attempt++}.xml`;
  writeFileSync(sourceFile,source);
  let element=await wd('POST',prefix+'/element',{using,value}).catch(error=>{
   if(!transient(error))throw error;
   return null;
  });
  let enabled=false,displayed=false,rect=null;
  if(element){
   const id=element['element-6066-11e4-a52e-4f735466cecf'];
   const state=await Promise.all([
    wd('GET',prefix+'/element/'+id+'/enabled'),
    wd('GET',prefix+'/element/'+id+'/displayed'),
    ...(stableRect?[wd('GET',prefix+'/element/'+id+'/rect')]:[]),
   ]).catch(error=>{
    if(!transient(error))throw error;
    element=null;
    return [false,false,null];
   });
   [enabled,displayed,rect]=state;
  }
  const key=element&&enabled&&displayed&&rect?JSON.stringify(rect):null;
  const stable=!stableRect||(key!==null&&key===previousRect);
  previousRect=key;
  observations.push({utc:new Date().toISOString(),sourceFile,found:element!==null,enabled,displayed,rect,stable});
  writeFileSync(`evidence/${label}-readiness.json`,JSON.stringify({using,value,observations},null,2));
  if(element&&enabled&&displayed&&stable)return element;
  await new Promise(resolve=>setTimeout(resolve,200));
 }while(Date.now()<deadline);
 if(optional)return null;
 throw new Error('Actual native control did not become ready: '+label+' ('+value+')');
}
