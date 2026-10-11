import {readFileSync,writeFileSync} from 'node:fs';
import {waitForNativeControl} from './native-readiness.mjs';
export default async function({session,wd}) {
 const prefix=`/session/${session}`,observations=[];
 const settingsPackage='(@package="com.android.settings" or starts-with(@package,"com.oplus.") or starts-with(@package,"com.oneplus."))';
 const appIdentity=`//*[@text="LocalSend" and ${settingsPackage}]`;
 const heading=label=>`//*[@text="${label}" and ${settingsPackage} and (@heading="true" or contains(@resource-id,"toolbar") or contains(@resource-id,"title"))] | //*[@content-desc="${label}" and ${settingsPackage} and contains(@resource-id,"toolbar")]`;
 const appInfoHeading=`//*[${settingsPackage} and @text="App info" and (@heading="true" or contains(@resource-id,"toolbar") or contains(@resource-id,"title"))]`;
 const textTarget=(text,screen='true()')=>({using:'xpath',value:`//*[@text="${text}" and ${settingsPackage} and (${screen})]`});
 const appInfoScreen=`count(${appIdentity})>0 and count(${appInfoHeading})>0`;
 async function ready(label,targets,options={}){return await waitForNativeControl({wd,prefix,label:'settings-'+label,choices:targets,requireClickable:false,...options});}
 async function capture(label,element){
  const xml=readFileSync(element.readiness.sourceFile,'utf8');writeFileSync(`evidence/settings-${label}.xml`,xml);
  const image=await wd('GET',prefix+'/screenshot',undefined,{timeoutMs:10000});writeFileSync(`evidence/settings-${label}.png`,Buffer.from(image,'base64'));
  return xml;
 }
 async function unavailableSnapshot(label){
  try{const xml=await wd('GET',prefix+'/source',undefined,{timeoutMs:10000});writeFileSync(`evidence/settings-${label}-unavailable.xml`,xml);const image=await wd('GET',prefix+'/screenshot',undefined,{timeoutMs:10000});writeFileSync(`evidence/settings-${label}-unavailable.png`,Buffer.from(image,'base64'));}catch{}
 }
 async function intent(action,uri){await wd('POST',prefix+'/execute/sync',{script:'mobile: startActivity',args:[{action,uri,wait:true,stop:false}]},{timeoutMs:10000});}
 try{
  await intent('android.settings.APPLICATION_DETAILS_SETTINGS','package:org.localsend.localsend_app');
  const batteryLabels=['App battery usage','Battery usage','Battery'];
  const appInfo=await ready('app-info',batteryLabels.map(label=>textTarget(label,appInfoScreen)));
  const info=await capture('app-info',appInfo);observations.push({screen:'app-info',nativeBatteryRowObserved:true,settingValuesVerified:false});
  const batteryLabel=batteryLabels.find(label=>info.includes(`text="${label}"`));
  const item=await ready('app-battery-row',[{using:'xpath',value:`//*[@text="${batteryLabel}" and ${settingsPackage} and (${appInfoScreen})]/ancestor-or-self::*[@clickable="true" and ${settingsPackage}][1]`}],{requireClickable:true});
  await wd('POST',prefix+'/element/'+item['element-6066-11e4-a52e-4f735466cecf']+'/click',{}, {timeoutMs:10000});
  const policyLabels=['Allow background usage','Allow background activity','Allow foreground activity','Optimize battery use','Unrestricted','Optimized','Restricted'];
  const policyHeading=['App battery usage','Battery usage','Battery usage management'].map(heading).join(' | ');
  const uniquePolicyControl=['Allow background usage','Allow background activity','Allow foreground activity'].map(label=>`//*[@text="${label}" and ${settingsPackage}]/ancestor::*[${settingsPackage} and @clickable="true"][1]`).join(' | ');
  const policyScreen=`count(${appIdentity})>0 and count(${appInfoHeading})=0 and (count(${policyHeading})>0 or count(${uniquePolicyControl})>0)`;
  const usage=await ready('app-battery-usage',policyLabels.map(label=>textTarget(label,policyScreen)));
  await capture('app-battery-usage',usage);observations.push({screen:'app-battery-usage',policyLabelsObserved:policyLabels.filter(text=>readFileSync(usage.readiness.sourceFile,'utf8').includes(`text="${text}"`)),settingValuesVerified:false,requiresVisualPolicyReview:true});
 }catch(error){await unavailableSnapshot('app-policy');observations.push({screen:'app-info-or-battery-usage',unavailable:true,error:String(error)});}
 try{
  await intent('android.settings.BATTERY_SAVER_SETTINGS');
  const saverLabels=['Battery Saver','Power saving mode','Power saving','Super power saving mode'];
  const saver=await ready('battery-saver',saverLabels.map(label=>({using:'xpath',value:heading(label)})),{requireEnabled:false});
  await capture('battery-saver',saver);observations.push({screen:'battery-saver',settingValuesVerified:false,requiresVisualPolicyReview:true});
 }catch(error){await unavailableSnapshot('battery-saver');observations.push({screen:'battery-saver',unavailable:true,error:String(error)});}
 writeFileSync('evidence/settings-observations.json',JSON.stringify({device:process.env.BS_DEVICE,observations,settingsChanged:false},null,2));
 await wd('POST',prefix+'/appium/device/activate_app',{appId:'org.localsend.localsend_app'},{timeoutMs:10000});
 await ready('returned-localsend',[{using:'xpath',value:'//*[@package="org.localsend.localsend_app"][1]'}]);
}
