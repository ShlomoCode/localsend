#!/usr/bin/env bash
# Cloud Actions only; reviewed source is never injected into the application.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]]
mkdir -p evidence-cloud/production-observation
mkdir -p evidence-cloud/production-observation/original-fixtures
cp /tmp/issue1864-photos/*.jpg evidence-cloud/production-observation/original-fixtures/
sha256sum support/tests/issue1864-production.mjs support/tests/issue1864-production-whole.mjs support/tests/issue1864-production-replay.sh > evidence-cloud/production-observation/observer-source-sha256.txt
adb shell wm density > evidence-cloud/production-observation/device-density.txt
adb shell wm size > evidence-cloud/production-observation/device-size.txt
adb shell getprop persist.sys.locale > evidence-cloud/production-observation/device-locale.txt
export ISSUE1864_APP_SOURCE_MANIFEST="$PWD/evidence-cloud/production-pair/app-source-manifest.json"
export ISSUE1864_APPIUM_LOG="$PWD/evidence-cloud/appium.log"
export ISSUE1864_MOUSE=w3c-native ISSUE1864_TRACE=false
export ISSUE1864_CORE_BASE_DIR="$PWD/evidence-cloud/production-observation/production-base/core"
export ISSUE1864_FIXTURE_MANIFEST="$PWD/evidence-cloud/production-observation/fixture-manifest.json"
adb shell content query --uri content://media/external/file --projection _id:_display_name:_data:mime_type:date_added > evidence-cloud/production-observation/mediastore-before.txt
# These are the existing six source JPEGs; no rescan/replacement between variants.
node --input-type=module <<'JS'
import fs from 'node:fs';import crypto from 'node:crypto';import {execFileSync} from 'node:child_process';
const text=fs.readFileSync('evidence-cloud/production-observation/mediastore-before.txt','utf8');
const names=['red.jpg','green.jpg','blue.jpg','yellow.jpg','purple.jpg','orange.jpg'];
const files=names.map(name=>{
 const path=`/sdcard/Pictures/issue1864/${name}`;
 const line=text.split('\n').find(l=>l.includes(`_display_name=${name},`) && l.includes(`/Pictures/issue1864/${name}`));
 if(!line) throw new Error(`Exact fixture MediaStore row missing ${name}`);
 const bytes=execFileSync('adb',['exec-out','cat',path]);const local=fs.readFileSync(`/tmp/issue1864-photos/${name}`);
 if(!bytes.equals(local)) throw new Error(`Device fixture differs from original JPEG ${name}`);
 return {name,path,id:line.match(/_id=(\d+)/)?.[1],mimeType:'image/jpeg',size:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),mediaStoreRow:line};
});
fs.writeFileSync(process.env.ISSUE1864_FIXTURE_MANIFEST,JSON.stringify({files,ordering:'Observer must establish actual tile order from original before-input frames; MediaStore IDs are recorded, never assumed equal after rescan',boundary:'Exact device JPEG hash/size, not internal returned bytes'},null,2));
JS
phase() {
  local variant="$1" control="$2" apk
  # Reserve a complete natural recording, exact-file read/decode and evidence flush.
  [[ ${ISSUE1864_HOST_DEADLINE_EPOCH_MS:-} =~ ^[0-9]+$ ]]
  [[ $(( ISSUE1864_HOST_DEADLINE_EPOCH_MS - $(date +%s%3N) )) -gt 600000 ]]
  if [[ "$variant" == production-base ]]; then apk=evidence-cloud/source-baseline.apk; else apk=evidence-cloud/source-focus.apk; fi
  export ISSUE1864_APK="$variant" ISSUE1864_PHASE="$control"
  export ISSUE1864_EVIDENCE_DIR="$PWD/evidence-cloud/production-observation/$variant/$control"
  mkdir -p "$ISSUE1864_EVIDENCE_DIR"
  sha256sum "$apk" > "$ISSUE1864_EVIDENCE_DIR/apk-sha256.txt"
  ISSUE1864_PHASE_APK_PATH="$apk" node --input-type=module <<'JS'
import fs from 'node:fs';import crypto from 'node:crypto';
const source=JSON.parse(fs.readFileSync(process.env.ISSUE1864_APP_SOURCE_MANIFEST,'utf8'));
const key=process.env.ISSUE1864_APK==='production-base' ? 'baseApkSha256' : 'candidateApkSha256';
const hash=crypto.createHash('sha256').update(fs.readFileSync(process.env.ISSUE1864_PHASE_APK_PATH)).digest('hex');
if(hash!==source[key] || source.diagnosticDefines!==false) throw new Error('Phase APK/source identity mismatch or diagnostic build');
JS
  adb install --abi arm64-v8a -r "$apk" > "$ISSUE1864_EVIDENCE_DIR/install.txt" 2>&1
  adb shell pm clear org.localsend.localsend_app > "$ISSUE1864_EVIDENCE_DIR/data-clear.txt"
  adb shell dumpsys package org.localsend.localsend_app > "$ISSUE1864_EVIDENCE_DIR/package-before.txt"
  grep -q 'primaryCpuAbi=arm64-v8a' "$ISSUE1864_EVIDENCE_DIR/package-before.txt"
  if [[ "$control" != permission-denial-grant ]]; then
    # This occurs only after both actual OS denial/grant controls complete.
    for permission in READ_MEDIA_IMAGES READ_MEDIA_VIDEO; do adb shell pm grant org.localsend.localsend_app "android.permission.$permission" >> "$ISSUE1864_EVIDENCE_DIR/phase-restored-permissions.txt" 2>&1; done
  fi
  if [[ "$control" == theme-dark ]]; then adb shell cmd uimode night yes > "$ISSUE1864_EVIDENCE_DIR/system-night.txt"; else adb shell cmd uimode night no > "$ISSUE1864_EVIDENCE_DIR/system-night.txt"; fi
  adb shell cmd uimode night >> "$ISSUE1864_EVIDENCE_DIR/system-night.txt"
  adb shell content query --uri content://media/external/file --projection _id:_display_name:_data:mime_type:date_added > "$ISSUE1864_EVIDENCE_DIR/mediastore-before.txt"
  node support/tests/issue1864-production-whole.mjs
  adb shell content query --uri content://media/external/file --projection _id:_display_name:_data:mime_type:date_added > "$ISSUE1864_EVIDENCE_DIR/mediastore-after.txt"
}
# Fresh initial OS denial followed by visible Settings UI grant for BOTH APKs.
# No automatic grants occur before either permission control.
phase production-base permission-denial-grant
phase production-candidate permission-denial-grant
# Both causal core variants precede any video seeding. The JPEG files/rows stay intact.
phase production-base core
phase production-candidate core
for control in picker-cancel pointer-count folders theme-light theme-dark; do phase production-base "$control"; phase production-candidate "$control"; done
mkdir -p /tmp/issue1864-mixed
cp /tmp/issue1864-photos/green.jpg /tmp/issue1864-mixed/mixed-image.jpg
ffmpeg -v error -f lavfi -i color=c=blue:s=640x480:r=24 -t 2 -c:v libx264 -pix_fmt yuv420p -an /tmp/issue1864-mixed/mixed-video.mp4
mkdir -p evidence-cloud/production-observation/mixed-original-fixtures
cp /tmp/issue1864-mixed/* evidence-cloud/production-observation/mixed-original-fixtures/
adb shell mkdir -p /sdcard/Pictures/issue1864-mixed
adb push /tmp/issue1864-mixed/. /sdcard/Pictures/issue1864-mixed/
for name in mixed-image.jpg mixed-video.mp4; do adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file:///sdcard/Pictures/issue1864-mixed/$name"; done
sleep 3
export ISSUE1864_MIXED_MANIFEST="$PWD/evidence-cloud/production-observation/mixed-manifest.json"
node --input-type=module <<'JS'
import fs from 'node:fs';import crypto from 'node:crypto';import {execFileSync} from 'node:child_process';
const rows=execFileSync('adb',['shell','content','query','--uri','content://media/external/file','--projection','_id:_display_name:_data:mime_type'],{encoding:'utf8'});
fs.writeFileSync('evidence-cloud/production-observation/mixed-mediastore.txt',rows);
const files=['mixed-image.jpg','mixed-video.mp4'].map(name=>{
 const path=`/sdcard/Pictures/issue1864-mixed/${name}`,bytes=execFileSync('adb',['exec-out','cat',path]);
 const row=rows.split('\n').find(l=>l.includes(`_display_name=${name},`) && l.includes(path));if(!row) throw new Error('Mixed fixture missing');
 const mimeType=name.endsWith('.jpg') ? 'image/jpeg' : 'video/mp4';if(!row.includes(`mime_type=${mimeType}`)) throw new Error('Mixed MediaStore type mismatch');
 return {name,path,size:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),mimeType,mediaStoreRow:row};
});fs.writeFileSync(process.env.ISSUE1864_MIXED_MANIFEST,JSON.stringify({files},null,2));
JS
phase production-base mixed
phase production-candidate mixed
node --input-type=module <<'JS'
import fs from 'node:fs';
const root='evidence-cloud/production-observation';
const read=(v,p)=>JSON.parse(fs.readFileSync(`${root}/${v}/${p}/outcome.json`));
const base=read('production-base','core'),candidate=read('production-candidate','core');
if(base.controls.core.shortCount!==0 || base.controls.core.freshCount!==0 || candidate.controls.core.shortCount!==1 || candidate.controls.core.freshCount!==1) throw new Error('Clean pair core result mismatch');
fs.writeFileSync(`${root}/pair-verdict.json`,JSON.stringify({base,candidate,automatedCorePairPassed:true,shippingAcceptance:'PENDING independent original-frame review of focus outline, native Settings/mouse events, preview, folder focus confinement, actual dark/light palette, denial/grant/cancel controls; no physical Sony TV or 999 saturation claim'},null,2));
JS
