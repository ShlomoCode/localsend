import {writeFileSync} from 'node:fs';
export default async function({session,wd}) {
 async function capture(label){await new Promise(resolve=>setTimeout(resolve,700));const xml=await wd('GET',`/session/${session}/source`);writeFileSync(`evidence/settings-${label}.xml`,xml);const image=await wd('GET',`/session/${session}/screenshot`);writeFileSync(`evidence/settings-${label}.png`,Buffer.from(image,'base64'));return xml;}
 async function intent(action,uri){await wd('POST',`/session/${session}/execute/sync`,{script:'mobile: startActivity',args:[{action,uri,wait:true,stop:false}]});}
 const observations=[];
 try{
  await intent('android.settings.APPLICATION_DETAILS_SETTINGS','package:org.localsend.localsend_app');
  const info=await capture('app-info');observations.push({screen:'app-info',settingsPackageObserved:info.includes('package="com.android.settings"'),settingValuesVerified:false});
  const batteryLabel=['App battery usage','Battery'].find(label=>info.includes(`text="${label}"`));
  if(batteryLabel){
   const item=await wd('POST',`/session/${session}/element`,{using:'xpath',value:`//*[@text="${batteryLabel}"]`});
   await wd('POST',`/session/${session}/element/${item['element-6066-11e4-a52e-4f735466cecf']}/click`,{});
   const usage=await capture('app-battery-usage');observations.push({screen:'app-battery-usage',settingsPackageObserved:usage.includes('package="com.android.settings"'),settingValuesVerified:false});
  }
 }catch(error){observations.push({screen:'app-info',error:String(error)});}
 try{
  await intent('android.settings.BATTERY_SAVER_SETTINGS');
  const saver=await capture('battery-saver');observations.push({screen:'battery-saver',settingsPackageObserved:saver.includes('package="com.android.settings"'),settingValuesVerified:false});
 }catch(error){observations.push({screen:'battery-saver',error:String(error)});}
 writeFileSync('evidence/settings-observations.json',JSON.stringify(observations,null,2));
 await wd('POST',`/session/${session}/appium/device/activate_app`,{appId:'org.localsend.localsend_app'});
}
