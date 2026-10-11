// Derived review aids only; preserve raw cloud screenrecord files unchanged.
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
const out='evidence-cloud';
const timingPath=`${out}/input-timings.jsonl`;
if(!fs.existsSync(timingPath)) process.exit(0);
const timings=fs.readFileSync(timingPath,'utf8').trim().split('\n').map(line=>JSON.parse(line));
const labels={19:'UP',20:'DOWN',21:'LEFT',22:'RIGHT',23:'CENTER',61:'TAB',66:'ENTER',4:'BACK'};
for(const start of timings.filter(e=>e.type==='recording' && e.action==='start')) {
  const raw=`${out}/${start.name}.mp4`;
  if(!fs.existsSync(raw)) continue;
  const end=timings.find(e=>e.type==='recording' && e.action==='end' && e.name===start.name);
  if(!end) continue;
  const probe=execFileSync('ffprobe',['-v','error','-show_format','-show_streams','-of','json',raw],{encoding:'utf8'});
  fs.writeFileSync(`${out}/${start.name}-metadata.json`,probe);
  execFileSync('ffmpeg',['-v','error','-i',raw,'-f','null','-'],{timeout:60000});
  const events=timings.filter(e=>e.time>=start.time && e.time<=end.time && ['mouse','dpad','keyboard'].includes(e.type));
  const filters=["fps=30", "drawtext=text='Controller input log - approximate video offset':x=20:y=h-110:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.8"];
  for(const event of events) {
    const t=(event.time-start.time)/1000;
    const text=event.type==='mouse' ? `Mouse tap at ${event.x} ${event.y}` : `${event.type==='dpad' ? 'D-pad' : 'Keyboard'} ${labels[event.key] ?? event.key}`;
    const enable=`between(t,${t.toFixed(3)},${(t+.8).toFixed(3)})`;
    filters.push(`drawtext=text='${text}':x=20:y=h-70:fontsize=36:fontcolor=white:box=1:boxcolor=black@0.85:enable='${enable}'`);
    if(event.type==='mouse') filters.push(`drawbox=x=${event.x-24}:y=${event.y-24}:w=48:h=48:color=white@0.8:t=3:enable='${enable}'`);
  }
  fs.writeFileSync(`${out}/${start.name}-overlay-filter.txt`,filters.join(','));
  execFileSync('ffmpeg',['-v','error','-y','-i',raw,'-filter_script:v',`${out}/${start.name}-overlay-filter.txt`,
    '-c:v','libx264','-preset','fast','-crf','20','-an','-movflags','+faststart',`${out}/${start.name}-inputs.mp4`],{timeout:60000});
  execFileSync('ffmpeg',['-v','error','-i',`${out}/${start.name}-inputs.mp4`,'-f','null','-'],{timeout:60000});
}
fs.writeFileSync(`${out}/video-review-provenance.txt`,'Raw recordings are preserved. Derived overlays show controller log offsets from recording-start, without a calibrated video-clock alignment. Mouse markers are review aids, not recorded pointer pixels. Both raw and derived videos decoded successfully.\n');
