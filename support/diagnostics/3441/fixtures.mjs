import {mkdirSync,readFileSync,writeFileSync,statSync} from "node:fs";
import {execFileSync} from "node:child_process";
import {createHash} from "node:crypto";
import path from "node:path";
const root=path.resolve("evidence/issue3441/fixtures");mkdirSync(root,{recursive:true});
const ff=(args)=>execFileSync("ffmpeg",["-hide_banner","-loglevel","error","-y",...args],{stdio:"inherit"});
ff(["-f","lavfi","-i","testsrc2=size=1280x720:rate=1","-frames:v","1","-q:v","5",root+"/seed.jpg"]);
ff(["-f","lavfi","-i","testsrc2=size=640x360:rate=10","-t","1","-c:v","libx264","-pix_fmt","yuv420p","-movflags","+faststart",root+"/seed.mp4"]);
const jpg=readFileSync(root+"/seed.jpg"),mp4=readFileSync(root+"/seed.mp4");
function jpeg(target){
  let extra=target-jpg.length;if(extra<4)throw new Error("JPEG target too short");const pieces=[jpg.subarray(0,2)];
  while(extra){let n=Math.min(extra,65537);if(extra-n>0&&extra-n<4)n-=4;const b=Buffer.alloc(n);b[0]=255;b[1]=254;b.writeUInt16BE(n-2,2);pieces.push(b);extra-=n;}
  pieces.push(jpg.subarray(2));return Buffer.concat(pieces);
}
function video(target){const n=target-mp4.length;if(n<8)throw new Error("MP4 target too short");const free=Buffer.alloc(n);free.writeUInt32BE(n);free.write("free",4);return Buffer.concat([mp4,free]);}
const sizes=Array.from({length:73},(_,i)=>238000+((i*7919)%1100000));sizes[72]=5300000;
// The screenshot reports rounded MB; 85,600,000 bytes is a declared approximation, not recovered original payload.
let missing=85600000-sizes.reduce((a,b)=>a+b,0);for(let i=1;missing>0;i=i===71?1:i+1){const add=Math.min(missing,50000);sizes[i]+=add;missing-=add;}
const rows=[];for(let i=0;i<207;i++){
 const isVideo=i<73?i>=61:i%7===0;const name=isVideo?`VID_20260401_${String(i).padStart(6,"0")}.mp4`:`${i<12?"Screenshot":"IMG"}_20260401_${String(i).padStart(6,"0")}.jpg`;
 const bytes=i<73?sizes[i]:238000+((i*7919)%1800000);const file=path.join(root,name);writeFileSync(file,isVideo?video(bytes):jpeg(bytes));
 ff(["-i",file,"-map","0:v:0","-f","null","-"]);
 const data=readFileSync(file);rows.push({name,bytes:statSync(file).size,sha256:createHash("sha256").update(data).digest("hex"),mimeType:isVideo?"video/mp4":"image/jpeg"});
}
writeFileSync(root+"/control.jpg",jpg);rows.push({name:"control.jpg",bytes:jpg.length,sha256:createHash("sha256").update(jpg).digest("hex"),mimeType:"image/jpeg"});
writeFileSync(root+"/manifest.json",JSON.stringify({schema:1,fixtureKind:"Generated playable media with legal JPEG COM / MP4 free-box padding; synthetic content is an explicit deviation from original camera files",cases:[{id:"control",names:["control.jpg"]},{id:"initial207",names:rows.slice(0,207).map(r=>r.name)},{id:"retry73",names:rows.slice(0,73).map(r=>r.name)}],files:rows},null,2));
