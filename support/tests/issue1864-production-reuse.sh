#!/usr/bin/env bash
# Cloud-only replay of immutable normal-release APKs and their original build proof.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ShlomoCode/localsend ]]
base=c1ce322fb3acf08e44f329b8b7208b8b0d91e244
candidate=c2e9a4b36bfc94034c7a0c27b0316bf3fc4e72d9
test "${ISSUE1864_CANDIDATE_COMMIT:?Reviewed candidate required}" = "$candidate"
run=38199760513
artifact=11725497911
head=e994cceb6a75f252f5f82004a2b2548edeb1d9a0
zip_sha256=bf61a05bd65249ff2941ebce7254c9bb34f17cc9816d911d1435e157011f6eea
root="$PWD"
evidence="$root/evidence-cloud"
receipt="$evidence/production-reuse"
mkdir -p "$receipt"
retained=$(mktemp -d "$RUNNER_TEMP/issue1864-production-reuse.XXXXXXXX")
trap 'rm -rf "$retained"' EXIT
gh api "repos/ShlomoCode/localsend/actions/runs/$run" > "$receipt/source-run.json"
gh api "repos/ShlomoCode/localsend/actions/artifacts/$artifact" > "$receipt/source-artifact.json"
jq -e --arg head "$head" --argjson run "$run" \
  '.id == $run and .head_sha == $head and .repository.full_name == "ShlomoCode/localsend" and .status == "completed"' \
  "$receipt/source-run.json"
jq -e --arg head "$head" --argjson run "$run" --argjson artifact "$artifact" \
  '.id == $artifact and .name == "issue1864-tv29-initial" and .expired == false and .workflow_run.id == $run and .workflow_run.head_sha == $head' \
  "$receipt/source-artifact.json"
gh api "repos/ShlomoCode/localsend/actions/artifacts/$artifact/zip" > "$retained/original.zip"
printf '%s  %s\n' "$zip_sha256" "$retained/original.zip" | sha256sum -c - | tee "$receipt/archive-verification.txt"
sha256sum "$retained/original.zip" > "$receipt/source-archive-sha256.txt"
unzip -Z1 "$retained/original.zip" > "$receipt/source-archive-files.txt"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$receipt/source-archive-files.txt"; then
  echo 'Artifact contains an unsafe archive path' >&2
  exit 1
fi
mkdir "$retained/extracted"
unzip -q "$retained/original.zip" -d "$retained/extracted"
export ISSUE1864_RETAINED="$retained/extracted"
node --input-type=module <<'JS' > "$receipt/build-proof-verification.txt"
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const root=process.env.ISSUE1864_RETAINED, proof=path.join(root,'production-pair');
const requireCondition=(ok,message)=>{if(!ok) throw new Error(message);};
const bytes=file=>{requireCondition(fs.lstatSync(file).isFile(),`Nonregular proof: ${file}`);return fs.readFileSync(file);};
const read=name=>bytes(path.join(proof,name));
const text=name=>read(name).toString('utf8');
const hash=value=>crypto.createHash('sha256').update(value).digest('hex');
function regularTree(dir){
 requireCondition(fs.lstatSync(dir).isDirectory(),`Nonregular directory: ${dir}`);
 for(const entry of fs.readdirSync(dir)){const file=path.join(dir,entry),stat=fs.lstatSync(file);
  if(stat.isDirectory()) regularTree(file);else requireCondition(stat.isFile(),`Nonregular artifact file: ${file}`);
 }
}
regularTree(root);
const manifest=JSON.parse(text('app-source-manifest.json'));
const expected={baseCommit:'c1ce322fb3acf08e44f329b8b7208b8b0d91e244',candidateCommit:'c2e9a4b36bfc94034c7a0c27b0316bf3fc4e72d9',baseApkSha256:'88e5e991d68710ffb2d908492bc4eabf260dcf87fccb3893943718a8a0bfa68a',candidateApkSha256:'a89761a3fff92ca30aef9e914e4c2deeade9dce0e456e7a69867e6f51b729818',flutter:'3.41.9',dart:'3.11.5',rust:'1.97.1',java:'17',build:'flutter build apk --release --target-platform android-arm64',diagnosticDefines:false};
for(const [key,value] of Object.entries(expected)) requireCondition(manifest[key]===value,`Manifest mismatch: ${key}`);
const cert=hash(read('signing-public-cert.der'));
requireCondition(text('signing-cert-sha256.txt').split(/\s+/)[0]===cert,'Public signing certificate receipt mismatch');
requireCondition(/^[0-9a-f]{64}\n$/.test(text('signing-keystore-sha256.txt')),'Missing keystore receipt');
for(const variant of ['baseline','candidate']){
 const prefix=variant+'/',apk=variant==='baseline'?'source-baseline.apk':'source-focus.apk';
 const apkHash=variant==='baseline'?expected.baseApkSha256:expected.candidateApkSha256;
 requireCondition(hash(bytes(path.join(root,apk)))===apkHash,`APK mismatch: ${variant}`);
 requireCondition(text(prefix+'apk-sha256.txt').split(/\s+/)[0]===apkHash,`APK build receipt mismatch: ${variant}`);
 requireCondition(text(prefix+'head.txt').trim()===(variant==='baseline'?expected.baseCommit:expected.candidateCommit),`Source head mismatch: ${variant}`);
 requireCondition(text(prefix+'build-status.txt')==='build_exit=0\nlog_exit=0\npipeline_exit=0\n',`Build failed: ${variant}`);
 for(const file of ['forbidden-app-source.txt','preflight-source.patch','pre-build-source.patch','post-build.patch']) requireCondition(read(prefix+file).length===0,`Modified source: ${variant}/${file}`);
 requireCondition(read(prefix+'Cargo-input.lock').equals(read(prefix+'Cargo.lock')),`Cargo resolution drift: ${variant}`);
 const normalization=JSON.parse(text(prefix+'cargokit-lock-normalization.json'));
 const raw=read(prefix+'cargokit-runner-pubspec.lock'),normalized=read(prefix+'cargokit-runner-normalized.lock');
 const checkout='/home/runner/work/_temp/issue1864-production-'+variant;
 const source=checkout+'/packages/localsend_isolates/rust_builder/cargokit/build_tool';
 requireCondition(normalization.variant===variant && normalization.checkout===checkout && normalization.expectedSource===source && normalization.generatedSourcePath===source && path.normalize(normalization.lockedSourcePath)===source,'Generated lock source receipt mismatch');
 requireCondition(normalization.replacementCount===1 && normalization.replacementContext==='packages.build_tool.description.path' && normalization.remainingBytesPreserved===true,'Generated lock normalization contract mismatch');
 requireCondition(normalization.rawSha256===hash(raw) && normalization.normalizedSha256===hash(normalized),'Generated lock hash receipt mismatch');
 const pubspecMatches=[...text(prefix+'cargokit-runner-pubspec.yaml').matchAll(/^dependencies:\n  build_tool:\n    path: (.+)$/gm)];
 requireCondition(pubspecMatches.length===1 && JSON.parse(pubspecMatches[0][1])===source,'Generated runner dependency receipt mismatch');
 const rawText=raw.toString('utf8');
 requireCondition(rawText.split(checkout).length===2 && Buffer.from(rawText.replace(checkout,'__ISSUE1864_CHECKOUT_ROOT__')).equals(normalized),'Generated lock normalization changed other bytes');
 const signerLines=text(prefix+'apk-signing.txt').split('\n').filter(line=>line.includes('certificate SHA-256 digest:'));
 requireCondition(signerLines.length>0 && signerLines.every(line=>/^(V2 Signer:|Signer #[1-9][0-9]*) certificate SHA-256 digest: [a-fA-F0-9]{64}$/.test(line) && line.split(': ').at(-1).toLowerCase()===cert),'APK signer receipt mismatch');
 requireCondition(text(prefix+'apk-signer-sha256.txt')===signerLines.map(()=>cert+'\n').join(''),'Parsed APK signer receipt mismatch');
 requireCondition(/^[0-9a-f]{64}\n$/.test(text(prefix+'signing-properties-sha256.txt')),'Missing signing input receipt');
}
for(const file of ['pubspec-input.lock','pubspec.lock','Cargo-input.lock','Cargo.lock','cargokit-runner-normalized.lock','apk-libraries.txt','apk-package.txt','apk-signing.txt','signing-properties-sha256.txt']) requireCondition(read('baseline/'+file).equals(read('candidate/'+file)),`Pair build proof differs: ${file}`);
console.log('Verified immutable APK identities, production manifest, successful build receipts, unchanged source, resolved locks and shared signing.');
JS
# Recheck the selected source identities and candidate scope without a toolchain.
git fetch --no-tags origin "$base" "$candidate"
test "$(git merge-base "$base" "$candidate")" = "$base"
git diff --name-status "$base" "$candidate" > "$receipt/candidate-paths.txt"
printf 'M\tapp/lib/util/native/file_picker.dart\nA\tapp/lib/util/ui/keyboard_asset_picker.dart\n' > "$receipt/expected-paths.txt"
cmp "$receipt/expected-paths.txt" "$receipt/candidate-paths.txt"
cmp "$receipt/candidate-paths.txt" "$retained/extracted/production-pair/candidate-paths.txt"
git diff --binary "$base" "$candidate" > "$receipt/candidate.patch"
cmp "$receipt/candidate.patch" "$retained/extracted/production-pair/candidate.patch"
git show "$candidate:app/lib/util/native/file_picker.dart" | sha256sum > "$receipt/candidate-file-picker-sha256.txt"
git show "$candidate:app/lib/util/ui/keyboard_asset_picker.dart" | sha256sum > "$receipt/candidate-helper-sha256.txt"
test "$(cut -d ' ' -f 1 "$receipt/candidate-file-picker-sha256.txt")" = 023e7d532e2e24685bc30615811b034924f6e33dc2df3196baa525ec5b014cef
test "$(cut -d ' ' -f 1 "$receipt/candidate-helper-sha256.txt")" = 9e6530f929986d7b10be48726ecb9c5a0d4d4aa48dc32e60836bb339dbda2d6d
for commit in "$base" "$candidate"; do
  if git grep -n -E 'ISSUE1864|diagnostic_asset_picker|diagnostic_picker_focus_trace' "$commit" -- app/lib > "$receipt/forbidden-$commit.txt"; then
    echo 'Diagnostic application source is forbidden' >&2
    exit 1
  fi
done
for variant in baseline candidate; do
  if [ "$variant" = baseline ]; then commit=$base; else commit=$candidate; fi
  for lock in pubspec Cargo; do
    git show "$commit:$lock.lock" > "$receipt/$variant-$lock-input.lock"
    cmp "$receipt/$variant-$lock-input.lock" "$retained/extracted/production-pair/$variant/$lock-input.lock"
  done
done
test ! -e "$evidence/production-pair"
cp -R "$retained/extracted/production-pair" "$evidence/production-pair"
cp "$retained/extracted/source-baseline.apk" "$retained/extracted/source-focus.apk" "$evidence/"
printf '%s\n' 'Original normal production APKs and production-pair build proof only; no prior runtime evidence copied. Fresh emulator, fixtures, permissions and full production replay required.' > "$receipt/reuse-contract.txt"
