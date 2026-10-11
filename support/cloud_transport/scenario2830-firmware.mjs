import {writeFileSync} from "node:fs";

// Read ordinary Settings UI only. Do not change OS, ROM, or any setting.
export default async function({session,wd}) {
 const result={method:"Android standard About phone intent UI",intentAction:"android.settings.DEVICE_INFO_SETTINGS",changedSettings:false};
 async function snapshot(label){
  const png=await wd("GET",`/session/${session}/screenshot`);
  writeFileSync(`evidence/${label}.png`,Buffer.from(png,"base64"));
  const xml=await wd("GET",`/session/${session}/source`);
  writeFileSync(`evidence/${label}.xml`,xml);
  return xml;
 }
 try {
  await wd("POST",`/session/${session}/execute/sync`,{script:"mobile: startActivity",args:[{action:result.intentAction,wait:true,stop:false}]});
  const xml=await snapshot("firmware-about-direct");
  result.labels=[...xml.matchAll(/\b(?:text|content-desc)="([^"]+)"/g)].map(match=>match[1]);
  result.aboutPageObserved=result.labels.some(label=>/MIUI|Android version|About phone/i.test(label));
 } catch(error){result.blocker=String(error);await snapshot("firmware-ui-failure").catch(()=>{});}
 finally {writeFileSync("evidence/firmware-ui-result.json",JSON.stringify(result,null,2));}
}
