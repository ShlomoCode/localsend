"""Cloud-only real LocalSend UI automation. No app code instrumentation."""
import csv, io, json, os, subprocess, time, shutil, threading, hashlib, pwd
from pathlib import Path
out = Path('evidence'); out.mkdir(exist_ok=True)
def run(*args):
    print('INPUT', args, flush=True)
    return subprocess.check_output(args, text=True)
def screen(stage):
    p = out / (stage+'.png'); run('scrot',str(p))
    ocr = out / (stage+'-ocr.png'); run('convert',str(p),'-resize','200%',str(ocr))
    t = run('tesseract',str(ocr),'stdout','--psm','11','tsv')
    (out/(stage+'.tsv')).write_text(t)
    rows=list(csv.DictReader(io.StringIO(t),delimiter='\t'))
    for row in rows:
        for key in ['left','top','width','height']: row[key]=str(int(row[key])//2)
    return rows
def locate(label,stage,deadline=20):
    end=time.monotonic()+deadline; n=0
    while True:
        words=screen(stage+'-'+str(n)); n+=1
        matches=[w for w in words if w['text'].strip()==label]
        if matches:
            w=matches[0]; return int(w['left'])+int(w['width'])//2,int(w['top'])+int(w['height'])//2
        if time.monotonic()>end: raise RuntimeError('Visible label missing: '+label)
        time.sleep(.5)
def click(x,y): run('xdotool','mousemove',str(x),str(y),'click','1'); time.sleep(.3)
def focus(win):
    run('xdotool','windowactivate','--sync',win); time.sleep(.5)
def window(pid):
    end=time.monotonic()+25
    while time.monotonic()<end:
        try:
            ids=run('xdotool','search','--onlyvisible','--pid',str(pid)).split()
            for wid in ids:
                if run('xdotool','getwindowname',wid).strip()=='LocalSend':
                    run('xdotool','windowmove',wid,'0','0'); run('xdotool','windowsize',wid,'1000','700'); return wid
        except subprocess.CalledProcessError: pass
        time.sleep(1)
    raise RuntimeError('LocalSend window missing')
def metrics(pid,stop,path):
    with path.open('w') as f:
        f.write('monotonic,status,stat,meminfo\n')
        while not stop.is_set():
            try:
                status=Path('/proc/'+str(pid)+'/status').read_text()
                fields=';'.join(l for l in status.splitlines() if l.startswith(('VmRSS:','VmHWM:','VmSize:','Threads:','State:')))
                stat=Path('/proc/'+str(pid)+'/stat').read_text()
                mem=';'.join(l for l in Path('/proc/meminfo').read_text().splitlines() if l.startswith(('MemAvailable:','SwapFree:')))
                f.write(json.dumps([time.monotonic(),fields,stat,mem])+'\n'); f.flush()
            except FileNotFoundError: f.write('PROCESS_EXIT\n'); break
            stop.wait(.25)
results=[]
for count in [5,5000]:
    case='files-'+str(count); fixture=Path('/tmp/issue2414')/case; fixture.mkdir(parents=True,exist_ok=True)
    content=b'LocalSend issue 2414 fixed ordinary file content\n'
    for n in range(count): (fixture/('file-%05d.txt'%n)).write_bytes(content)
    dest=Path('/tmp/issue2414-received')/case; dest.mkdir(parents=True,exist_ok=True)
    apps=[]
    try:
        for role,port in [('Receiver2414',53317),('Sender2414',53317)]:
            bundle=Path('/tmp')/(case+'-'+role); shutil.copytree('released/base',bundle,dirs_exist_ok=True)
            settings={'flutter.ls_alias':role,'flutter.ls_port':port,'flutter.ls_locale':'en','flutter.ls_destination':str(dest),'flutter.ls_quick_save':False,'flutter.ls_minimize_to_tray':False}
            (bundle/'settings.json').write_text(json.dumps(settings))
            log=(out/(case+'-'+role+'.log')).open('w')
            command=[str(bundle/'localsend_app')]
            if role=='Sender2414': command=['sudo','-E','ip','netns','exec','issue2414-sender','runuser','-u',pwd.getpwuid(os.getuid()).pw_name,'--preserve-environment','--']+command
            p=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
            time.sleep(1)
            actual_pid=int(run('pgrep','-f','^'+str(bundle/'localsend_app')+'$').split()[0])
            apps.append((p,window(actual_pid)))
        receiver,rwin=apps[0]; sender,swin=apps[1]
        stop=threading.Event(); sampler=threading.Thread(target=metrics,args=(receiver.pid,stop,out/(case+'-metrics.jsonl'))); sampler.start()
        focus(swin); screen(case+'-send-observed'); click(96,188); click(*locate('Folder',case+'-folder'))
        screen(case+'-picker'); run('xdotool','key','ctrl+l'); run('xdotool','type','--clearmodifiers',str(fixture)); run('xdotool','key','Return'); time.sleep(1)
        # GTK directory picker enters the directory; select its Open button.
        words=screen(case+'-picker-entered')
        opens=[w for w in words if w['text'].strip() in ['Open','Select']]
        if opens:
            w=opens[-1]; click(int(w['left'])+int(w['width'])//2,int(w['top'])+int(w['height'])//2)
        click(*locate('Receiver2414',case+'-target',60)); time.sleep(2)
        focus(rwin); option_xy=locate('Options',case+'-receive',30)
        started=time.monotonic(); click(*option_xy)
        try:
            locate('Destination',case+'-options',30)
            render=time.monotonic()-started
            screen(case+'-options-visible')
            # Back arrow is visible in the retained Options screenshot; Flutter's native route toolbar.
            click(30,65); time.sleep(1)
            click(*locate('Accept',case+'-accept',10))
            end=time.monotonic()+180
            while time.monotonic()<end and len(list(dest.rglob('*.txt')))<count: time.sleep(1)
            files=list(dest.rglob('*.txt')); valid=len(files)==count and all(p.read_bytes()==content for p in files)
            screen(case+'-completed')
            result={'count':count,'options_response_seconds':render,'saved_files':len(files),'content_valid':valid,'failure':None if valid else 'save mismatch'}
        except Exception as e:
            screen(case+'-failure'); result={'count':count,'failure':str(e),'receiver_exit':receiver.poll()}
        stop.set(); sampler.join(); results.append(result); (out/'results.json').write_text(json.dumps(results,indent=2))
        if count==5 and not result.get('content_valid'): raise RuntimeError('Small directory control failed; do not interpret large case')
    finally:
        if 'stop' in locals(): stop.set()
        for p,w in apps:
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill()
