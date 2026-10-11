// Derived review aids only; preserve raw cloud screenrecord files unchanged.
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
const out=process.env.ISSUE1864_VIDEO_DIR ?? 'evidence-cloud';
const timingPath=`${out}/input-timings.jsonl`;
if(!fs.existsSync(timingPath)) process.exit(0);
const timings=fs.readFileSync(timingPath,'utf8').trim().split('\n').map(line=>JSON.parse(line));
const labels={19:'UP',20:'DOWN',21:'LEFT',22:'RIGHT',23:'CENTER',61:'TAB',66:'ENTER',4:'BACK'};
let processed=0;
for(const start of timings.filter(e=>e.type==='recording' && e.action==='start' && (!process.env.ISSUE1864_VIDEO_CASE || e.name===process.env.ISSUE1864_VIDEO_CASE))) {
  const raw=`${out}/${start.name}.mp4`;
  if(!fs.existsSync(raw)) continue;
  const end=timings.find(e=>e.type==='recording' && e.action==='end' && e.name===start.name);
  if(!end) continue;
  const whole=start.stopMode==='whole-natural-expiry';
  const decodeTimeout=whole ? 180000 : 60000;
  const overlayTimeout=whole ? 300000 : 60000;
  const probe=execFileSync('ffprobe',['-v','error','-show_format','-show_streams','-of','json',raw],{encoding:'utf8'});
  fs.writeFileSync(`${out}/${start.name}-metadata.json`,probe);
  execFileSync('ffmpeg',['-v','error','-i',raw,'-f','null','-'],{timeout:decodeTimeout});
  const events=timings.filter(e=>e.time>=start.time && e.time<=end.time && ['mouse','dpad','keyboard'].includes(e.type));
  const filters=["fps=30", "drawtext=text='Input log - approximate video offset':x=w/2-270:y=h-98:fontsize=16:fontcolor=white:box=1:boxcolor=black@0.8"];
  const remoteButtons={19:['w/2','h-69','U'],20:['w/2','h-21','D'],21:['w/2-48','h-45','L'],22:['w/2+48','h-45','R'],23:['w/2','h-45','C']};
  if(events.some(event=>event.type==='dpad')) for(const [x,y,label] of Object.values(remoteButtons)) {
    filters.push(`drawbox=x=${x.replace('w','iw')}-14:y=${y.replace('h','ih')}-12:w=28:h=24:color=black@0.75:t=fill`);
    filters.push(`drawtext=text='${label}':x=${x}-7:y=${y}-10:fontsize=20:fontcolor=white`);
  }
  for(const event of events) {
    const t=(event.time-start.time)/1000;
    const text=event.type==='mouse' ? `Mouse tap at ${event.x} ${event.y}` : `${event.type==='dpad' ? 'D-pad' : 'Keyboard'} ${labels[event.key] ?? event.key}`;
    const enable=`between(t,${t.toFixed(3)},${(t+.8).toFixed(3)})`;
    filters.push(`drawtext=text='${text}':x=w/2+95:y=h-57:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.85:enable='${enable}'`);
    if(event.type==='dpad' && remoteButtons[event.key]) {
      const [x,y]=remoteButtons[event.key];
      filters.push(`drawtext=text='O':x=${x}-16:y=${y}-19:fontsize=40:fontcolor=yellow:alpha='1-(t-${t.toFixed(3)})/0.8':enable='${enable}'`);
    }
    if(event.type==='mouse') filters.push(`drawbox=x=${event.x-24}:y=${event.y-24}:w=48:h=48:color=white@0.8:t=3:enable='${enable}'`);
  }
  fs.writeFileSync(`${out}/${start.name}-overlay-filter.txt`,filters.join(','));
  execFileSync('ffmpeg',['-v','error','-y','-i',raw,'-vf',filters.join(','),
    '-c:v','libx264','-preset','fast','-crf','20','-an','-movflags','+faststart',`${out}/${start.name}-inputs.mp4`],{timeout:overlayTimeout});
  execFileSync('ffmpeg',['-v','error','-i',`${out}/${start.name}-inputs.mp4`,'-f','null','-'],{timeout:decodeTimeout});
  processed++;
}
fs.writeFileSync(`${out}/video-review-provenance.txt`,`Raw recordings are preserved. Derived overlays show controller log offsets from recording-start, without a calibrated video-clock alignment. Mouse markers are review aids, not recorded pointer pixels. Processed ${processed} recording(s); each processed raw and derived video decoded successfully.\n`);
