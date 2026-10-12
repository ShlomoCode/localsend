// Independently invoked by the sequential cleanup Actions job, even after controller failure.
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
if (process.env.GITHUB_ACTIONS !== 'true' || process.env.GITHUB_REPOSITORY !== 'ShlomoCode/localsend') throw new Error('Fork Actions only');
const folder = resolve('diagnostic-2973-cleanup');
await mkdir(folder, { recursive: true });
const user = process.env.BROWSERSTACK_USERNAME;
const key = process.env.BROWSERSTACK_ACCESS_KEY;
if (!user || !key) throw new Error('Missing BrowserStack credentials');
const authorization = `Basic ${Buffer.from(`${user}:${key}`).toString('base64')}`;
const buildName = `2973-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}`;
const deadline = Date.now() + 90000;
async function get(path) {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error('Independent cleanup deadline reached before management request');
  const response = await fetch(`https://api-cloud.browserstack.com${path}`, { headers: { Authorization: authorization }, signal: AbortSignal.timeout(Math.min(15000, remaining)) });
  if (!response.ok) throw new Error(`Management read failed (${response.status})`);
  return response.json();
}
let last = { buildName, confirmedOwnedSessions: [], unresolved: true, settingsRestoration: 'not-established-by-cleanup' };
try {
  for (let pass = 0; pass < 3 && Date.now() < deadline; pass++) {
    const builds = await get('/app-automate/builds.json?limit=100');
    if (!Array.isArray(builds)) throw new Error('Malformed build inventory');
    const matches = builds.map(item => item.automation_build).filter(item => item?.name === buildName);
    if (matches.length > 1) throw new Error('Ambiguous build identity; unrelated sessions untouched');
    if (matches.length === 1) {
      const list = await get(`/app-automate/builds/${encodeURIComponent(matches[0].hashed_id)}/sessions.json?limit=100`);
      if (!Array.isArray(list)) throw new Error('Malformed session inventory');
      const sessions = list.map(item => item.automation_session).filter(item => item?.name === `${buildName}-original` && item.build_name === buildName && item.project_name === 'LocalSend bug sprint');
      if (sessions.length > 1) throw new Error('Ambiguous session identity; no termination');
      if (sessions.length === 1) {
        const session = sessions[0];
        last.confirmedOwnedSessions = [{ id: session.hashed_id, status: session.status }];
        if (session.status === 'running') {
          const remaining = deadline - Date.now();
          if (remaining <= 0) throw new Error('Independent cleanup deadline reached before termination');
          const response = await fetch(`https://hub-cloud.browserstack.com/wd/hub/session/${encodeURIComponent(session.hashed_id)}`, {
            method: 'DELETE', headers: { Authorization: authorization }, signal: AbortSignal.timeout(Math.min(15000, remaining)),
          });
          last.quitResponseStatus = response.status;
        }
        const terminal = await get(`/app-automate/sessions/${encodeURIComponent(session.hashed_id)}.json`);
        const status = terminal.automation_session?.status;
        last.confirmedOwnedSessions[0].status = status;
        last.unresolved = !['done', 'failed', 'timeout'].includes(status);
        if (!last.unresolved) break;
      }
    }
    const remaining = deadline - Date.now();
    if (pass < 2 && remaining > 0) await new Promise(resolvePromise => setTimeout(resolvePromise, Math.min(10000, remaining)));
  }
} catch (error) {
  last.error = error.message;
} finally {
  await writeFile(resolve(folder, 'owned-cleanup-verdict.json'), JSON.stringify(last, null, 2));
}
if (last.unresolved) throw new Error('Owned session termination remains unresolved; block further 2973 dispatch and inspect cloud state');
