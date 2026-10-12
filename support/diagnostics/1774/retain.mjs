import assert from "node:assert/strict";
import {readFileSync,writeFileSync,mkdirSync,existsSync} from "node:fs";
import {createHash} from "node:crypto";
import path from "node:path";
import {retainProviderArtifacts} from "./provider-artifacts.mjs";
assert(process.env.GITHUB_ACTIONS==="true"&&process.env.GITHUB_REPOSITORY==="ShlomoCode/localsend","Only fork retention");
const output=path.resolve(process.env.EVIDENCE_DIR);mkdirSync(output,{recursive:true});
const file=path.join(output,"ownership.json");if(!existsSync(file))process.exit(0);
const owned=JSON.parse(readFileSync(file,"utf8")),buildName="issue1774-"+process.env.GITHUB_RUN_ID+"-attempt-"+process.env.GITHUB_RUN_ATTEMPT;
assert(owned.buildName===buildName&&owned.runId===process.env.GITHUB_RUN_ID&&owned.runAttempt===process.env.GITHUB_RUN_ATTEMPT,"Retention ownership mismatch");
if(!owned.session){writeFileSync(path.join(output,"retention-blocker.json"),JSON.stringify({missing:"exact owned session handle",noNewSession:true}));process.exit(0);}
const user=process.env.BROWSERSTACK_USERNAME,key=process.env.BROWSERSTACK_ACCESS_KEY,auth="Basic "+Buffer.from(user+":"+key).toString("base64");
const secrets=[user,key,auth,process.env.BASELINE_APP].filter(Boolean);
const redact=value=>{let text=String(value);for(const secret of secrets)text=text.replaceAll(secret,"[redacted]");return text.replace(/bs:\/\/[a-f0-9]+/gi,"[redacted app reference]");};
const save=(name,value)=>writeFileSync(path.join(output,name),redact(typeof value==="string"?value:JSON.stringify(value,null,2)));
const deadline=Math.min(Date.now()+150000,Date.parse(process.env.ISSUE1774_JOB_DEADLINE_UTC)-4*60000);
assert(deadline>Date.now(),"Provider retention reserve expired");
await retainProviderArtifacts({session:owned.session,auth,output,privatePrefix:buildName+"-",deadline,redact,save});
// Keep the entire decoded original. Short outcome clips are derived only after a
// reviewer correlates screenshots/actions with actual original video frames.
save("recording-evidence-limit.json",{continuousOriginalRetained:existsSync(path.join(output,"android-provider-original.mp4")),requestedClipSeconds:[5,10],clipPendingActualFrameCorrelation:true,clientInputClockIsNotProviderFrameClock:true,settingsAndMonitorPixelsRequireInspection:true});
const records=[];for(const name of ["android-provider-original.mp4","android-provider-device.log","android-provider-appium.log"]){const target=path.join(output,name);if(existsSync(target)){const bytes=readFileSync(target);records.push({name,bytes:bytes.length,sha256:createHash("sha256").update(bytes).digest("hex")});}}
save("retained-provider-manifest.json",records);
