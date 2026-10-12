import assert from 'node:assert/strict';

const APP = 'org.localsend.localsend_app';
const HELPER = 'org.localsend.diagnose2096';
const FAVORITE = 'issue2096-cloud-receiver';
const MAX_READS = 40;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function decode(value) {
  return value.replace(/&#x([a-f0-9]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}
function nodes(xml) {
  return [...xml.matchAll(/<[^/!?][^>]*>/g)].map(tag => Object.fromEntries(
    [...tag[0].matchAll(/([\w.:-]+)=(["'])(.*?)\2/g)].map(a => [a[1], decode(a[3])])));
}
const labels = xml => nodes(xml).flatMap(n => [n.text || '', n['content-desc'] || '']).filter(Boolean);
const bounded = n => /^\[\d+,\d+\]\[\d+,\d+\]$/.test(n.bounds || '');
const visible = n => n.displayed !== 'false' && bounded(n);
const enabled = n => visible(n) && n.enabled === 'true';
function rect(n) {
  const [x, y, right, bottom] = n.bounds.match(/\d+/g).map(Number);
  assert(right > x && bottom > y, 'Observed control has empty bounds');
  return {x, y, width: right - x, height: bottom - y};
}
const named = (xml, name) => nodes(xml).filter(n => n.text === name || n['content-desc'] === name);
const has = (xml, name) => named(xml, name).some(enabled);
const picker = xml => nodes(xml).some(n => /(?:^|\.)documentsui$/.test(n.package || ''));
const selectionCount = xml => Number(labels(xml).join('\n').match(/Files: (\d+)/)?.[1] || 0);
const selectionNode = xml => nodes(xml).find(n => enabled(n) && /^Selection\nFiles: \d+\nSize: /.test(n['content-desc'] || ''));

/**
 * The controller owns installation/provenance, video/log retention, the session and cleanup.
 * ctx: session, wd(method,path,body), base(), source(absoluteDeadline), snap(name,xml),
 * touch(rect,label), activate(package), save(name,value), deadline (absolute, <=35 device minutes),
 * expectedSignerSha256 (array of exact official APK signer certificate SHA-256 digests),
 * transfer({caseName,manifest,observe,deadline,expectedNames?}, sendAction).
 * Hierarchy and native element metadata observations share a combined 40-observation case cap.
 * transfer must use observe() for every Android hierarchy read, retain real Windows Accept/save
 * receipts, and return saved-files-verified with androidFinished=true within 120 seconds.
 * Helper manifests are independent observations; original LocalSend tree/name logs remain
 * controller evidence and must be reconciled before making a naming or cause claim.
 */
export async function runScenario(ctx) {
  for (const key of ['wd', 'base', 'source', 'snap', 'touch', 'activate', 'save', 'transfer']) assert.equal(typeof ctx[key], 'function', key);
  assert(Number.isFinite(ctx.deadline) && ctx.deadline > Date.now(), 'Finite device deadline required');
  assert(ctx.deadline - Date.now() <= 35 * 60000, 'Device deadline exceeds 35-minute cap');
  assert(Array.isArray(ctx.expectedSignerSha256) && ctx.expectedSignerSha256.length > 0 &&
    ctx.expectedSignerSha256.every(value => /^[a-f0-9]{64}$/i.test(value)), 'Exact verified official APK signer array required');
  const report = {status: 'preparing', startedUtc: new Date().toISOString(), cases: [], events: [], manifests: {},
    limits: {deviceMinutes: 35, combinedUiObservationsPerCase: MAX_READS, pickerMs: 60000, transferMs: 120000,
      files: 20, bytes: 5 * 1024 * 1024, levels: 5, providerRows: 100},
    boundaries: ['Reporter Android version and document provider are unknown.',
      'Helper grants belong to the fixture helper and are never substituted for LocalSend grants.',
      'Cloud relay and Windows Server differ from an ordinary shared LAN.',
      'Staged filesystem nesting does not establish a provider hierarchy.'],
    appTreeUris: {status: 'requires-controller-original-app-log-reconciliation'}};
  let current;
  const persist = () => ctx.save('android-scenario.json', report);
  const event = (type, detail = {}) => {
    report.events.push({utc: new Date().toISOString(), monotonicMs: performance.now(), caseName: current?.name, type, ...detail}); persist();
  };
  const begin = name => {
    assert(Date.now() < ctx.deadline, 'Device deadline exhausted');
    current = {name, status: 'running', startedUtc: new Date().toISOString(), observations: 0, elementObservations: 0, route: [], snapshots: []};
    report.cases.push(current); persist();
  };
  const read = async (end = ctx.deadline) => {
    assert(current.observations + current.elementObservations < MAX_READS, current.name + ': combined 40-observation cap reached');
    end = Math.min(end, ctx.deadline, Date.now() + 10000);
    assert(end > Date.now(), 'UI observation deadline exhausted');
    const count = ++current.observations, start = Date.now();
    current.totalUiObservations = current.observations + current.elementObservations;
    const xml = await ctx.source(end);
    ctx.save(current.name + '-source-' + String(count).padStart(2, '0') + '.xml', xml);
    assert(Date.now() <= end, 'Hierarchy returned after deadline; original response retained');
    event('observation', {number: count, combinedCount: current.observations + current.elementObservations,
      elapsedMs: Date.now() - start, packages: [...new Set(nodes(xml).map(n => n.package).filter(Boolean))]});
    return xml;
  };
  const snap = async (name, xml) => {
    assert(xml, 'Snapshot must reuse a counted fresh hierarchy');
    const fullName = current.name + '-' + name;
    await ctx.snap(fullName, xml); current.snapshots.push(fullName); persist();
  };
  const until = async (predicate, end, reason) => {
    end = Math.min(end, ctx.deadline);
    while (Date.now() < end) {
      const xml = await read(end);
      if (predicate(xml)) return xml;
      await sleep(Math.min(2000, Math.max(0, end - Date.now())));
    }
    throw Error(reason);
  };
  const tapNode = async (node, label) => {
    assert(enabled(node), 'Visible enabled semantic control unavailable: ' + label);
    event('input-start', {label, package: node.package, resourceId: node['resource-id'], rect: rect(node)});
    await ctx.touch(rect(node), current.name + ': ' + label); event('input-return', {label});
  };
  const elementObservation = async (method, endpoint, body) => {
    assert(current.observations + current.elementObservations < MAX_READS, 'Combined 40-observation cap reached');
    current.elementObservations++;
    current.totalUiObservations = current.observations + current.elementObservations;
    const started = Date.now(), value = await ctx.wd(method, ctx.base() + endpoint, body);
    event('native-element-observation', {number: current.elementObservations, combinedCount: current.observations + current.elementObservations,
      method, endpoint, elapsedMs: Date.now() - started, value});
    return value;
  };
  const tap = async (xml, name) => {
    const options = named(xml, name).filter(enabled);
    assert(options.length === 1, 'Semantic control absent or ambiguous: ' + name);
    await tapNode(options[0], name);
  };
  const back = async label => {
    event('input-start', {label, nativeKey: 'BACK'});
    await ctx.wd('POST', ctx.base() + '/appium/device/press_keycode', {keycode: 4}); event('input-return', {label});
  };
  const treeJson = xml => {
    const marker = labels(xml).find(t => t.startsWith('DIAG2096_JSON:'));
    const raw = marker?.slice('DIAG2096_JSON:'.length) || nodes(xml).find(n => /:id\/result_json$/.test(n['resource-id'] || ''))?.text;
    return raw ? JSON.parse(raw) : null;
  };
  const rootRoute = async (xml, route, end) => {
    assert(picker(xml), 'Actual DocumentsUI package not observed');
    const observedPickerPackages = [...new Set(nodes(xml).filter(n => /(?:^|\.)documentsui$/.test(n.package || '')).map(n => n.package))];
    current.resolvedTreePicker = report.fixtures.resolvedTreePicker;
    current.observedPickerPackages = observedPickerPackages; persist();
    assert.deepEqual(observedPickerPackages, [report.fixtures.resolvedTreePicker.package], 'Actual picker package differs from PackageManager tree picker resolution');
    await snap('picker-before-roots', xml);
    await tap(xml, 'Show roots'); xml = await read(end);
    if (route === 'device-download') {
      let candidates = nodes(xml).filter(n => enabled(n) && n['resource-id']?.endsWith('/title') &&
        /^(?:Internal storage|Internal shared storage|Galaxy S20|SM-G981B|Samsung Galaxy S20|My phone|Device)$/.test(n.text || ''));
      if (!candidates.length) {
        // Show internal storage is a supported picker preference, only used when actually offered.
        await back('Close roots drawer'); xml = await read(end);
        await tap(xml, 'More options'); xml = await read(end);
        await snap('picker-storage-menu', xml);
        assert(has(xml, 'Show internal storage'), 'Visible Device/internal-storage root unavailable');
        await tap(xml, 'Show internal storage'); xml = await read(end);
        await tap(xml, 'Show roots'); xml = await read(end);
        candidates = nodes(xml).filter(n => enabled(n) && n['resource-id']?.endsWith('/title') &&
          /^(?:Internal storage|Internal shared storage|Galaxy S20|SM-G981B|Samsung Galaxy S20|My phone|Device)$/.test(n.text || ''));
      }
      await snap('visible-roots', xml); assert.equal(candidates.length, 1, 'Device root missing or ambiguous');
      current.route.push({label: candidates[0].text, resourceId: candidates[0]['resource-id'], package: candidates[0].package});
      await tapNode(candidates[0], candidates[0].text); xml = await read(end);
      const download = named(xml, 'Download').filter(n => enabled(n) && n['resource-id']?.endsWith('/title'));
      assert.equal(download.length, 1, 'Actual Device → Download directory unavailable');
      current.route.push({label: 'Download', resourceId: download[0]['resource-id'], package: download[0].package});
      await tapNode(download[0], 'Download'); xml = await read(end);
    } else {
      await snap('visible-roots', xml);
      const download = named(xml, 'Downloads').filter(n => enabled(n) && n['resource-id']?.endsWith('/title'));
      assert.equal(download.length, 1, 'Actual top-level Downloads root absent or ambiguous');
      current.route.push({label: 'Downloads', resourceId: download[0]['resource-id'], package: download[0].package});
      await tapNode(download[0], 'Downloads'); xml = await read(end);
    }
    await snap('exact-route-before-grant', xml); return xml;
  };
  const grant = async (xml, end, owner) => {
    const controls = nodes(xml).filter(n => /^(?:USE THIS FOLDER|Use this folder)$/i.test(n.text || n['content-desc'] || '') && visible(n));
    assert.equal(controls.length, 1, 'Actual USE THIS FOLDER control unavailable');
    current.grantControl = {...controls[0]}; persist();
    if (!enabled(controls[0])) {
      current.status = 'supported-root-disabled'; await snap('disabled-use-this-folder', xml);
      throw Error('Actual route has disabled USE THIS FOLDER; no forced grant permitted');
    }
    await tapNode(controls[0], 'USE THIS FOLDER');
    xml = await until(s => nodes(s).some(n => /^(?:ALLOW|Allow)$/.test(n.text || n['content-desc'] || '') && visible(n)), end,
      'Actual tree permission Allow dialog unavailable');
    await snap('permission-dialog', xml);
    current.permissionLabels = labels(xml); current.grantOwner = owner;
    const allow = nodes(xml).filter(n => /^(?:ALLOW|Allow)$/.test(n.text || n['content-desc'] || '') && enabled(n));
    assert.equal(allow.length, 1, 'Actual Allow missing, disabled or ambiguous');
    await tapNode(allow[0], 'Allow'); return read(end);
  };
  const inspectTree = async route => {
    begin('helper-' + route); await ctx.activate(HELPER);
    let xml = await read(); await tap(xml, route === 'downloads' ? 'INSPECT_DOWNLOADS_TREE' : 'INSPECT_DEVICE_DOWNLOAD_TREE');
    const end = Math.min(ctx.deadline, Date.now() + 60000);
    xml = await until(picker, end, 'Helper did not launch real tree picker');
    xml = await rootRoute(xml, route, end); await grant(xml, end, HELPER);
    xml = await until(s => ['TREE_ADMITTED', 'TREE_REJECTED', 'ERROR'].some(t => labels(s).includes(t)),
      Math.min(ctx.deadline, Date.now() + 60000), 'Helper tree inspection did not complete');
    await snap('manifest-result', xml);
    const rawManifest = treeJson(xml); assert(rawManifest, 'Helper tree JSON unavailable');
    current.helperManifest = rawManifest; report.manifests[route] = rawManifest; persist();
    const actualDevice = rawManifest.provider;
    current.actualDevice = actualDevice;
    if (actualDevice?.api !== 29 || actualDevice.release !== '10' ||
      !/^(?:SM-G98[01][A-Z0-9]*|Samsung Galaxy S20)$/.test(actualDevice.model || '')) {
      current.status = 'environment-invalid'; report.environmentClassification = 'environment-invalid'; persist();
      throw Error('Actual provider device identity differs from admitted Samsung Galaxy S20 / API29 / Android10 environment');
    }
    assert.equal(rawManifest.resolvedTreePicker?.package, current.observedPickerPackages[0], 'Helper manifest picker package differs from actual picker');
    current.grantFlags = {requested: rawManifest.requestedGrantFlags, returned: rawManifest.returnedGrantFlags,
      persisted: rawManifest.persistedGrantFlags, scope: rawManifest.grantScope}; persist();
    assert.equal(rawManifest.admitted, true, 'Entire real tree inventory did not meet admission limits');
    const manifest = validateManifest(rawManifest, route);
    current.status = 'admitted'; persist(); return manifest;
  };
  const openSend = async () => {
    await ctx.activate(APP); let xml = await read();
    if (has(xml, 'Done')) {await tap(xml, 'Done'); xml = await read();}
    const send = nodes(xml).filter(n => enabled(n) && /^Send\nTab 2 of 3$/.test(n['content-desc'] || ''));
    assert.equal(send.length, 1, 'Normal LocalSend Send tab unavailable');
    if (send[0].selected !== 'true') {await tapNode(send[0], 'Send tab'); xml = await read();}
    if (selectionCount(xml)) {
      const card = selectionNode(xml); assert(card, 'Normal Selection card unavailable');
      await tapNode(card, 'Selection'); xml = await read();
      await tap(xml, 'Delete all'); xml = await read();
    }
    assert(!selectionCount(xml) && has(xml, 'File') && has(xml, 'Folder'), 'Empty Send selection not established');
    await snap('empty-send', xml); return xml;
  };
  const recordSelection = async (xml, end) => {
    current.selectedCount = selectionCount(xml); await snap('selection-summary', xml);
    const card = selectionNode(xml); assert(card, 'Actual nonempty Selection card unavailable');
    await tapNode(card, 'Selection'); xml = await read(end);
    assert(has(xml, 'Delete all'), 'Actual Selection detail page unavailable');
    current.selectionFrames = []; const seen = new Set(); let last = null;
    for (let page = 0; page < 5; page++) {
      const values = labels(xml); current.selectionFrames.push({page, labels: values});
      values.forEach(value => seen.add(value)); await snap('selection-rows-' + page, xml);
      const scroll = nodes(xml).filter(n => n.scrollable === 'true' && visible(n));
      if (!scroll.length || values.join('\n') === last || current.selectedCount <= 3) break;
      assert.equal(scroll.length, 1, 'Selection scroll container ambiguous'); last = values.join('\n');
      const r = rect(scroll[0]); event('input-start', {label: 'Scroll actual Selection list', rect: r});
      await ctx.wd('POST', ctx.base() + '/actions', {actions: [{type: 'pointer', id: 'selection2096', parameters: {pointerType: 'touch'}, actions: [
        {type: 'pointerMove', duration: 0, origin: 'viewport', x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height * .8)},
        {type: 'pointerDown', button: 0}, {type: 'pointerMove', duration: 400, origin: 'viewport', x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height * .2)},
        {type: 'pointerUp', button: 0}]}]}); event('input-return', {label: 'Scroll actual Selection list'}); xml = await read(end);
    }
    current.selectedLabels = [...seen];
    current.nameEvidence = 'Raw actual Selection rows; original app logs must resolve complete per-file URI/name mapping.';
    await back('Return from Selection details'); xml = await read(end); persist(); return xml;
  };
  const sendFavorite = async () => {
    let xml = await read(); await tap(xml, 'Favorites'); xml = await read();
    let favorite = nodes(xml).filter(n => enabled(n) && n['content-desc'] === FAVORITE + '\n(127.0.0.1)');
    if (!favorite.length) {
      await tap(xml, 'Add'); xml = await read();
      assert(labels(xml).includes('Add to favorites') && has(xml, 'Confirm'), 'Actual favorite editor unavailable');
      const fields = nodes(xml).filter(n => n.class === 'android.widget.EditText' && enabled(n)).sort((a, b) => rect(a).y - rect(b).y);
      assert.equal(fields.length, 3, 'Favorite editor must expose name, IP and port');
      const elements = await elementObservation('POST', '/elements', {using: 'class name', value: 'android.widget.EditText'});
      assert.equal(elements.length, 3, 'Favorite editor field count changed');
      const observed = [];
      for (const element of elements) {
        const id = element['element-6066-11e4-a52e-4f735466cecf'] || element.ELEMENT;
        observed.push({id, rect: await elementObservation('GET', '/element/' + id + '/rect')});
      }
      observed.sort((a, b) => a.rect.y - b.rect.y);
      const values = [FAVORITE, '127.0.0.1', '53318'];
      for (const i of [2, 0, 1]) {
        assert.equal(await elementObservation('GET', '/element/' + observed[i].id + '/displayed'), true, 'Favorite field not displayed');
        const liveRect = await elementObservation('GET', '/element/' + observed[i].id + '/rect');
        assert(liveRect.width > 0 && liveRect.height > 0, 'Favorite field has no current bounds');
        event('input-start', {label: 'Favorite field ' + i, rect: liveRect, value: values[i]});
        await ctx.touch(liveRect, 'Favorite field ' + i);
        await ctx.wd('POST', ctx.base() + '/element/' + observed[i].id + '/clear', {});
        await ctx.wd('POST', ctx.base() + '/element/' + observed[i].id + '/value', {text: values[i], value: [...values[i]]});
        assert.equal(await elementObservation('GET', '/element/' + observed[i].id + '/text'), values[i], 'Favorite input changed');
        event('input-return', {label: 'Favorite field ' + i});
      }
      xml = await read(); await snap('favorite-filled', xml); await tap(xml, 'Confirm');
      xml = await until(s => nodes(s).some(n => enabled(n) && n['content-desc'] === FAVORITE + '\n(127.0.0.1)'),
        Math.min(ctx.deadline, Date.now() + 30000), 'Real favorite registration unavailable');
      favorite = nodes(xml).filter(n => enabled(n) && n['content-desc'] === FAVORITE + '\n(127.0.0.1)');
    }
    assert.equal(favorite.length, 1, 'Real favorite row unavailable or ambiguous'); await snap('favorite-before-send', xml);
    await tapNode(favorite[0], FAVORITE + ' (127.0.0.1:53318)');
  };
  const transfer = async manifest => {
    const end = Math.min(ctx.deadline, Date.now() + 120000);
    current.transfer = await ctx.transfer({caseName: current.name, manifest, observe: () => read(end), deadline: end,
      expectedNames: current.name.includes('control'),
      observationBudgetRemaining: MAX_READS - current.observations - current.elementObservations}, sendFavorite);
    assert(Date.now() <= end, 'Small transfer exceeded 120-second deadline');
    assert.equal(current.transfer.status, 'saved-files-verified', 'Actual Windows Accept/save/hash gate failed');
    assert.equal(current.transfer.androidFinished, true, 'Original Android Finished UI not observed');
    current.status = 'transferred'; persist();
  };
  try {
    begin('helper-stage'); await ctx.activate(HELPER); let xml = await read(); await tap(xml, 'STAGE_FIXTURES');
    xml = await until(s => labels(s).includes('STAGED') || labels(s).includes('ERROR'), Math.min(ctx.deadline, Date.now() + 60000), 'Owned fixture staging did not complete');
    await snap('fixtures-reopened', xml); report.fixtures = treeJson(xml); assert(report.fixtures, 'Reopened fixture JSON missing');
    assert(!labels(xml).includes('ERROR'), 'Owned MediaStore fixture staging failed');
    const installed = report.fixtures.installedLocalSend;
    report.installedLocalSend = installed;
    report.expectedSignerSha256 = [...ctx.expectedSignerSha256].map(s => s.toLowerCase()).sort(); persist();
    if (installed?.package !== APP || installed.versionName !== '1.16.1' || !Array.isArray(installed.signerSha256) ||
      JSON.stringify(installed.signerSha256.map(s => s.toLowerCase()).sort()) !== JSON.stringify(report.expectedSignerSha256)) {
      current.status = 'environment-invalid'; report.environmentClassification = 'environment-invalid'; persist();
      throw Error('Installed LocalSend package/version/current signer array differs from exact official 1.16.1 APK identity');
    }
    assert(report.fixtures.resolvedTreePicker?.package && report.fixtures.resolvedTreePicker?.versionName !== undefined,
      'Resolved tree picker package/version identity missing');
    assert.equal(report.fixtures.complete, true, 'Owned fixture staging incomplete');
    assert.equal(report.fixtures.fixtures?.length, 3, 'Exactly three owned fixtures required');
    assert(report.fixtures.fixtures.every(f => f.committed === true && f.bytes === f.sourceBytes && f.bytes === f.reopenedBytes &&
      /^[a-f0-9]{64}$/i.test(f.sha256 || '') && f.sha256 === f.sourceSha256 && f.uri?.startsWith('content://')),
      'Fixture reopened bytes/hash differ from retained source');
    current.status = 'staged'; persist();
    const device = await inspectTree('device-download'); const downloads = await inspectTree('downloads');
    begin('file-control'); xml = await openSend(); await tap(xml, 'File');
    let end = Math.min(ctx.deadline, Date.now() + 60000); xml = await until(picker, end, 'Actual File picker unavailable');
    xml = await rootRoute(xml, 'downloads', end);
    const file = device.files.find(f => f.displayName === 'ls2096-table.csv'); assert(file, 'Owned root File control missing from provider manifest');
    await tap(xml, file.displayName);
    xml = await until(s => !picker(s) && selectionCount(s) === 1, end, 'File control did not select exactly one file');
    await recordSelection(xml, end); await transfer({...device, files: [{...file, displayRelativePath: file.displayName}],
      caseRoute: 'Send → File → Downloads → ls2096-table.csv'});
    for (const [name, route, manifest] of [['device-download-control', 'device-download', device],
      ['downloads-first', 'downloads', downloads], ['downloads-repeat', 'downloads', downloads],
      ['device-download-final-control', 'device-download', device]]) {
      begin(name); xml = await openSend(); await tap(xml, 'Folder'); end = Math.min(ctx.deadline, Date.now() + 60000);
      xml = await until(picker, end, 'Actual Folder picker unavailable'); xml = await rootRoute(xml, route, end);
      await grant(xml, end, APP);
      xml = await until(s => !picker(s) && selectionCount(s) > 0, end, 'Original LocalSend did not return nonempty Selection');
      await recordSelection(xml, end);
      assert.equal(current.selectedCount, manifest.files.length, 'Selection count differs from independently admitted actual tree inventory');
      await transfer(manifest);
    }
    report.status = 'bounded-sequence-transferred-awaiting-original-log-and-video-audit';
  } catch (error) {
    if (current && current.status === 'running') current.status = 'unmet';
    report.status = 'incomplete'; report.error = String(error.stack || error);
    if (current && current.observations + current.elementObservations < MAX_READS && Date.now() < ctx.deadline) {
      try {await snap('terminal-failure', await read());} catch (captureError) {report.terminalCaptureError = String(captureError.message);}
    }
    throw error;
  } finally {
    report.finishedUtc = new Date().toISOString(); persist();
  }
  return report;
}

function validateManifest(manifest, route) {
  assert(typeof manifest.treeUri === 'string' && manifest.treeUri.startsWith('content://'), 'Real granted tree URI missing');
  assert.equal(manifest.inventoryComplete, true, 'Full provider inventory incomplete');
  assert(Array.isArray(manifest.rows), 'Full provider row inventory missing');
  assert.equal(manifest.ownedFixtureCount, 3, 'Entire tree did not expose all three owned fixtures');
  assert.equal(manifest.provider?.authority, route === 'downloads' ? 'com.android.providers.downloads.documents' : 'com.android.externalstorage.documents',
    'Selected tree is not the required native provider route');
  assert.equal(manifest.rootDocumentId, route === 'downloads' ? 'downloads' : 'primary:Download', 'Actual granted root document ID differs from required route');
  const files = manifest.rows.filter(row => row.mimeType !== 'vnd.android.document/directory')
    .map(row => ({...row, owned: Boolean(row.ownedAsset),
      displayRelativePath: manifest.rootDisplayName + '/' + row.relativePath}));
  assert.equal(files.length, manifest.fileCount, 'Retained provider rows do not cover the complete file inventory');
  assert(files.length > 0 && files.length <= 20, 'Entire inventory file cap exceeded');
  assert(files.every(f => f.owned === true), 'Fresh tree contains unrelated contents; transfer admission refused');
  assert(files.every(f => Number.isSafeInteger(f.bytes) && f.bytes >= 0 && f.hashedBytes === f.bytes && /^[a-f0-9]{64}$/i.test(f.sha256 || '')),
    'Every admitted file requires reopened bytes/hash');
  assert(files.every(f => typeof f.displayRelativePath === 'string' && f.displayRelativePath.length > 0), 'Traversed display-name paths missing');
  const total = files.reduce((sum, f) => sum + f.bytes, 0);
  assert.equal(total, manifest.totalBytes, 'Retained inventory byte sum differs from provider total');
  assert(total <= 5 * 1024 * 1024, 'Entire inventory byte cap exceeded');
  assert(manifest.rows.every(row => Number.isInteger(row.depth) && row.depth <= 5), 'Entire inventory depth cap unmet');
  assert(Number.isInteger(manifest.rowCount) && manifest.rowCount <= 100, 'Entire provider row cap unmet');
  assert.equal(manifest.rows.length + 1, manifest.rowCount, 'Retained provider row count including root differs');
  return {...manifest, files};
}
