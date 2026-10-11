import {writeFileSync} from "node:fs";

// Read ordinary Settings UI only. Do not change OS, ROM, or any setting.
export default async function({session,wd}) {
 const result={method:"Android Settings → About phone UI",changedSettings:false};
 async function snapshot(label){
  const xml=await wd("GET",`/session/${session}/source`);
  writeFileSync(`evidence/${label}.xml`,xml);
  const png=await wd("GET",`/session/${session}/screenshot`);
  writeFileSync(`evidence/${label}.png`,Buffer.from(png,"base64"));
  return xml;
 }
 try {
  await wd("POST",`/session/${session}/appium/device/activate_app`,{appId:"com.android.settings"});
  const source=await snapshot("firmware-settings");
  const labels=[...source.matchAll(/\b(?:text|content-desc)="([^"]+)"/g)].map(match=>match[1]);
  const about=labels.find(label=>/^(About phone|My device|About device)$/i.test(label));
  if(!about){result.blocker="No About phone/My device/About device entry observed in the initial ordinary Settings UI";return;}
  result.observedEntry=about;
  const element=await wd("POST",`/session/${session}/element`,{using:"-android uiautomator",value:`new UiSelector().text(${JSON.stringify(about)})`});
  await wd("POST",`/session/${session}/element/${element["element-6066-11e4-a52e-4f735466cecf"]}/click`,{});
  const xml=await snapshot("firmware-about-phone");
  result.aboutPageObserved=true;
  result.labels=[...xml.matchAll(/\b(?:text|content-desc)="([^"]+)"/g)].map(match=>match[1]);
 } catch(error){result.blocker=String(error);await snapshot("firmware-ui-failure").catch(()=>{});}
 finally {writeFileSync("evidence/firmware-ui-result.json",JSON.stringify(result,null,2));}
}
