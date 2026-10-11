#!/usr/bin/env node

// Download and preserve BrowserStack App Automate video for existing sessions.
// Intended for GitHub Actions after the diagnostic run has produced its evidence.
// It does not create, stop, or otherwise change BrowserStack sessions.

import { createHash } from 'node:crypto';
import { readFile, readdir, writeFile, mkdir, rename } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';

const execFileAsync = promisify(execFile);
const root = path.resolve(process.argv[2] ?? process.env.EVIDENCE_ROOT ?? 'evidence');
const username = process.env.BROWSERSTACK_USERNAME;
const accessKey = process.env.BROWSERSTACK_ACCESS_KEY;

if (!username || !accessKey) throw new Error('BrowserStack credentials are required in the environment.');

const readJson = async file => JSON.parse(await readFile(file, 'utf8'));
const isoTime = value => {
  if (typeof value !== 'string') return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
};

async function walk(directory) {
  let entries;
  try { entries = await readdir(directory, { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  const files = [];
  for (const entry of entries) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(full));
    else if (entry.isFile()) files.push(full);
  }
  return files;
}

function redact(value, key = '') {
  if (/password|access.?key|credential|authorization|token|secret/i.test(key)) return '[REDACTED]';
  if (Array.isArray(value)) return value.map(item => redact(item));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, redact(v, k)]));
  }
  if (typeof value === 'string' && /^https?:\/\//i.test(value)) {
    try {
      const url = new URL(value);
      url.username = '';
      url.password = '';
      for (const key of [...url.searchParams.keys()]) {
        if (/key|token|auth|secret|signature|credential/i.test(key)) url.searchParams.set(key, '[REDACTED]');
      }
      return url.toString();
    } catch { return value; }
  }
  return value;
}

async function sha256(file) {
  const bytes = await readFile(file);
  return createHash('sha256').update(bytes).digest('hex');
}

async function probe(video) {
  const invoke = async args => {
    const { stdout } = await execFileAsync('ffprobe', ['-v', 'error', ...args, '-of', 'json', video], { maxBuffer: 8 * 1024 * 1024 });
    return JSON.parse(stdout);
  };
  const base = await invoke(['-show_format', '-show_streams']);
  const first = await invoke(['-select_streams', 'v:0', '-read_intervals', '%+#1', '-show_packets', '-show_entries', 'packet=pts_time,dts_time,duration_time']);
  const duration = Number(base.format?.duration);
  const tailStart = Number.isFinite(duration) && duration > 1 ? (duration - 1).toFixed(3) : '0';
  const last = await invoke(['-select_streams', 'v:0', '-read_intervals', `${tailStart}%`, '-show_packets', '-show_entries', 'packet=pts_time,dts_time,duration_time']);
  const packets = last.packets ?? [];
  const streams = base.streams ?? [];
  const videoStream = streams.find(stream => stream.codec_type === 'video') ?? null;
  return {
    format: { formatName: base.format?.format_name ?? null, startTime: base.format?.start_time ?? null, durationSeconds: base.format?.duration ?? null, tags: redact(base.format?.tags ?? {}) },
    videoStream: videoStream && { codecName: videoStream.codec_name, width: videoStream.width, height: videoStream.height, frameRate: videoStream.avg_frame_rate, timeBase: videoStream.time_base, startTime: videoStream.start_time ?? null, durationSeconds: videoStream.duration ?? null, tags: redact(videoStream.tags ?? {}) },
    firstVideoPacket: first.packets?.[0] ?? null,
    lastVideoPacket: packets.at(-1) ?? null,
  };
}

function asSessionId(value) {
  if (typeof value === 'string') return value.trim();
  if (value && typeof value === 'object') return String(value.session ?? value.sessionId ?? value.id ?? '').trim();
  return '';
}

function findEventTime(obj, predicate) {
  if (!obj || typeof obj !== 'object') return null;
  for (const [key, value] of Object.entries(obj)) {
    if (predicate(key) && typeof value === 'string') {
      const ms = isoTime(value);
      if (ms !== null) return { key, value, ms };
    }
    const nested = findEventTime(value, predicate);
    if (nested) return nested;
  }
  return null;
}

async function getSessionMetadata(sessionId) {
  const url = `https://api-cloud.browserstack.com/app-automate/sessions/${encodeURIComponent(sessionId)}.json`;
  const response = await fetch(url, { headers: { authorization: `Basic ${Buffer.from(`${username}:${accessKey}`).toString('base64')}` } });
  if (!response.ok) throw new Error(`BrowserStack session metadata request failed with HTTP ${response.status}.`);
  const body = await response.json();
  const session = body.automation_session ?? body;
  const videoUrl = session.video_url ?? session.videoUrl;
  if (!videoUrl) throw new Error('BrowserStack session metadata did not include a video URL.');
  return { body, videoUrl };
}

async function downloadVideo(videoUrl, destination) {
  const url = new URL(videoUrl);
  // App Automate's video URL is an API asset. Send Basic Auth only to BrowserStack hosts.
  const headers = {};
  if (url.hostname === 'api-cloud.browserstack.com' || url.hostname.endsWith('.browserstack.com')) {
    headers.authorization = `Basic ${Buffer.from(`${username}:${accessKey}`).toString('base64')}`;
  }
  let response;
  try { response = await fetch(url, { headers, redirect: 'follow' }); }
  catch { throw new Error('BrowserStack video download failed before receiving an HTTP response; URL omitted.'); }
  if (!response.ok) throw new Error(`BrowserStack video download failed with HTTP ${response.status}.`);
  const temp = `${destination}.partial`;
  await writeFile(temp, Buffer.from(await response.arrayBuffer()));
  await rename(temp, destination);
}

const sessionCache = new Map();

async function processEvidenceDir(evidenceDir) {
  const files = await walk(evidenceDir);
  const sessionFile = files.find(file => path.basename(file) === 'browserstack-session.json');
  if (!sessionFile) return;
  const sessionId = asSessionId(await readJson(sessionFile));
  if (!sessionId) throw new Error(`No session ID in ${sessionFile}`);
  let shared = sessionCache.get(sessionId);
  if (!shared) {
    const api = await getSessionMetadata(sessionId);
    const sharedDir = path.join(root, 'browserstack-sessions', sessionId.replace(/[^a-zA-Z0-9_-]/g, '_'));
    await mkdir(sharedDir, { recursive: true });
    const video = path.join(sharedDir, 'browserstack-video.mp4');
    await downloadVideo(api.videoUrl, video);
    const media = await probe(video);
    await writeFile(path.join(sharedDir, 'browserstack-session-metadata.redacted.json'), `${JSON.stringify(redact(api.body), null, 2)}\n`);
    shared = { video, media, sharedDir, body: api.body };
    sessionCache.set(sessionId, shared);
  }
  const { video, media, sharedDir } = shared;
  const currentFiles = await walk(evidenceDir);
  const deletionFile = currentFiles.find(file => path.basename(file) === 'actual-deletion.json');
  const resultFile = currentFiles.find(file => /actual-(?:resend-)?(?:result|accept).*\.json$/i.test(path.basename(file)));
  let clip = { status: 'not-created', reason: 'No visually verified clip interval was supplied.' };

  // A reviewer may add this manifest after visually matching a frame/PTS to
  // the deletion and result timestamps. Never derive an offset from session
  // created_at or from an assumed relationship between API and video clocks.
  const intervalFile = path.join(evidenceDir, 'video-clip-interval.json');
  try {
    const interval = await readJson(intervalFile);
    const start = Number(interval.startOffsetSeconds);
    const end = Number(interval.endOffsetSeconds);
    const duration = Number(media.format.durationSeconds);
    const mappingSource = typeof interval.mappingSource === 'string' ? interval.mappingSource.trim() : '';
    const deletion = deletionFile ? await readJson(deletionFile) : null;
    const result = resultFile ? await readJson(resultFile) : null;
    const deletedAt = findEventTime(deletion, key => /^(?:utc|deleteUtc|deletionUtc)$/i.test(key));
    const acceptedAt = findEventTime(result, key => /^(?:acceptUtc|resultUtc|completedUtc)$/i.test(key));
    const eventTimesMatch = deletedAt && acceptedAt && interval.deletionUtc === deletedAt.value && interval.resultUtc === acceptedAt.value;
    if (!Number.isFinite(start) || !Number.isFinite(end) || !Number.isFinite(duration) || !mappingSource || !eventTimesMatch || start < 0 || end <= start || end > duration) {
      clip = { status: 'not-created', reason: 'video-clip-interval.json must provide valid in-range offsets and a non-empty mappingSource.' };
    } else {
      const clipPath = path.join(evidenceDir, 'browserstack-deletion-to-result.mp4');
      await execFileAsync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-ss', start.toFixed(3), '-i', video, '-t', (end - start).toFixed(3), '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '18', clipPath], { maxBuffer: 8 * 1024 * 1024 });
      clip = { status: 'created', file: path.basename(clipPath), startOffsetSeconds: start, endOffsetSeconds: end, durationSeconds: end - start, mappingSource, deletionUtc: interval.deletionUtc, resultUtc: interval.resultUtc };
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const manifest = {
    sessionId,
    evidenceDirectory: path.relative(root, evidenceDir),
    sourceSessionFile: path.relative(root, sessionFile),
    metadataFile: path.relative(evidenceDir, path.join(sharedDir, 'browserstack-session-metadata.redacted.json')),
    videoFile: path.relative(evidenceDir, video),
    videoSha256: await sha256(video),
    videoBytes: (await readFile(video)).byteLength,
    mediaTiming: media,
    clip,
    note: 'The complete BrowserStack recording is retained once per session under browserstack-sessions/. A clip is created only from an explicit video-clip-interval.json with visually verified offsets and mappingSource. Session creation time is not treated as video start time. No playback speed change is applied.',
  };
  await writeFile(path.join(evidenceDir, 'browserstack-video-evidence.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`Saved BrowserStack video evidence for ${path.relative(root, evidenceDir)} (${manifest.videoSha256}).`);
}

await mkdir(root, { recursive: true });
const allFiles = await walk(root);
const sessionFiles = allFiles.filter(file => path.basename(file) === 'browserstack-session.json');
if (!sessionFiles.length) throw new Error(`No browserstack-session.json files found under ${root}.`);
for (const file of sessionFiles) await processEvidenceDir(path.dirname(file));
