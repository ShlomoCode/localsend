import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {join,resolve} from 'node:path';

// Cloud preflight runs before the single Appium session is allocated.
const directory=resolve(process.env.ISSUE_2007_BUILD_PAIR_DIR);
const pair=JSON.parse(readFileSync(join(directory,'build-pair.json'),'utf8'));
const tools=join(process.env.ANDROID_HOME,'build-tools/36.0.0');
assert.equal(pair.baseline.source_sha,'c1ce322fb3acf08e44f329b8b7208b8b0d91e244');
assert.notEqual(pair.baseline.source_sha,pair.candidate.source_sha);
assert(/^[0-9a-f]{40}$/.test(process.env.ISSUE_2007_EXPECTED_CANDIDATE_SHA),'Expected immutable candidate SHA is required');
assert.equal(pair.candidate.source_sha,process.env.ISSUE_2007_EXPECTED_CANDIDATE_SHA,'Source pair must contain the exact requested candidate before allocation');
const certificates=[];
for(const label of ['baseline','candidate']){
 const arm=pair[label],apk=join(directory,label,'app-arm64-v8a-release.apk');
 assert(/^[0-9a-f]{40}$/.test(arm.source_sha));assert(/^[0-9a-f]{64}$/.test(arm.apk_sha256));
 assert(/^bs:\/\/[0-9a-f]+$/.test(arm.browserstack_app_url));
 assert.equal(arm.tracked_source_unchanged,true);assert.equal(arm.post_build_source_or_bytecode_modification,false);
 assert.equal(arm.helper_scanner_required,false);
 assert.equal(readFileSync(join(directory,label,'post-build-tracked-source.diff'),'utf8'),'');
 assert.equal(createHash('sha256').update(readFileSync(apk)).digest('hex'),arm.apk_sha256);
 const signature=execFileSync(join(tools,'apksigner'),['verify','--verbose','--print-certs',apk],{encoding:'utf8'});
 const certificate=signature.match(/^Signer #1 certificate SHA-256 digest: ([a-f0-9]+)$/m)?.[1];
 assert(certificate,'Verified source signer certificate missing');certificates.push(certificate);
 const badging=execFileSync(join(tools,'aapt2'),['dump','badging',apk],{encoding:'utf8'});
 assert(/^package: name='org\.localsend\.localsend_app'/m.test(badging));
 assert(/^native-code: 'arm64-v8a'$/m.test(badging));
 writeFileSync(`evidence/source-${label}-preflight-signature.txt`,signature);
 writeFileSync(`evidence/source-${label}-preflight-badging.txt`,badging);
}
assert.equal(certificates[0],certificates[1],'Normal baseline/candidate signers must match');
writeFileSync('evidence/source-pair-preflight.json',JSON.stringify({pair,certificateSha256:certificates[0],validatedBeforeDeviceAllocation:true},null,2));
