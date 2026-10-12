import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync} from 'node:fs';

// Read the normally compiled APK. Never retain or print its capability value.
const apk = '/tmp/helper/cloud-transport-helper.apk';
const raw = execFileSync('unzip', ['-p', apk, 'assets/config.json'], {timeout:15000,maxBuffer:64*1024});
const config = JSON.parse(raw.toString('utf8'));
const expected = process.env.RELAY_TOKEN;
const hash = value => createHash('sha256').update(value).digest('hex');
const proof = {
  observedUtc:new Date().toISOString(), normalBuild:true, inspected:'APK assets/config.json',
  apkSha256:hash(readFileSync(apk)), configSha256:hash(raw),
  expectedCapabilityPresent:typeof expected === 'string' && /^[0-9a-f]{48}$/.test(expected),
  compiledCapabilityPresent:typeof config.token === 'string' && /^[0-9a-f]{48}$/.test(config.token),
  capabilityMatches:config.token === expected,
  expectedCapabilitySha256:expected ? hash(expected) : null,
  compiledCapabilitySha256:typeof config.token === 'string' ? hash(config.token) : null,
  endpoint:config.endpoint,
};
writeFileSync('evidence/helper-config-proof.json', JSON.stringify(proof,null,2));
assert(proof.expectedCapabilityPresent && proof.compiledCapabilityPresent && proof.capabilityMatches, 'Normal helper APK capability differs from the expected runner capability; no device allocation');
assert.equal(proof.endpoint, 'http://bs-local.com:8080');
