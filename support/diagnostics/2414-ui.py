"""Cloud-only real LocalSend UI automation. No app code instrumentation."""
import csv, io, json, os, subprocess, time, shutil, threading, hashlib, pwd
from pathlib import Path
out = Path('evidence'); out.mkdir(exist_ok=True)
def run(*args):
    print('INPUT', time.monotonic(), args, flush=True)
    return subprocess.check_output(args, text=True)
def screen(stage):
    p = out / (stage+'.png'); run('scrot',str(p))
    ocr = out / (stage+'-ocr.png'); run('convert',str(p),'-resize','200%',str(ocr))
    t = run('tesseract',str(ocr),'stdout','--psm','11','tsv')
    (out/(stage+'.tsv')).write_text(t)
    rows=list(csv.DictReader(io.StringIO(t),delimiter='\t',quoting=csv.QUOTE_NONE))
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
                pss=';'.join(l for l in Path('/proc/'+str(pid)+'/smaps_rollup').read_text().splitlines() if l.startswith(('Rss:','Pss:','Private_Dirty:')))
                f.write(json.dumps([time.monotonic(),fields,stat,mem,pss])+'\n'); f.flush()
            except FileNotFoundError: f.write('PROCESS_EXIT\n'); break
            stop.wait(.25)
results=[]
for count in [5,5000]:
    case='files-'+str(count); fixture=Path.home()/('Case2414Files'+str(count)); fixture.mkdir(parents=True,exist_ok=True)
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
            if role=='Receiver2414': command=['sudo','-E','ip','netns','exec','issue2414-sender','runuser','-u',pwd.getpwuid(os.getuid()).pw_name,'--preserve-environment','--','dbus-run-session','--']+command
            p=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
            time.sleep(1)
            actual_pid=int(run('pgrep','-f','^'+str(bundle/'localsend_app')+'$').split()[0])
            apps.append((p,window(actual_pid),actual_pid))
        receiver,rwin,rpid=apps[0]; sender,swin,spid=apps[1]
        stop=threading.Event(); sampler=threading.Thread(target=metrics,args=(rpid,stop,out/(case+'-metrics.jsonl'))); sampler.start()
        focus(swin); screen(case+'-send-observed'); click(96,188); screen(case+'-folder-observed'); click(514,150)
        locate('Recent',case+'-picker-ready',10); chooser=run('xdotool','search','--onlyvisible','--name','Choose Directory').split()[-1]; focus(chooser);
        (out/(case+'-namespace-fixture.txt')).write_text(run('sudo','ip','netns','exec','issue2414-sender','find',str(fixture),'-maxdepth','2','-type','f'))
        screen(case+'-picker'); click(*locate('Home',case+'-picker-home',10)); time.sleep(2)
        click(*locate(fixture.name,case+'-picker-folder-row',10)); screen(case+'-picker-selected'); click(*locate('Open',case+'-picker-open',10)); time.sleep(2)
        screen(case+'-picker-accepted')
        click(*locate('Receiver2414',case+'-target',60)); time.sleep(2)
        focus(rwin); option_xy=locate('Options',case+'-receive',30)
        started=time.monotonic(); click(*option_xy)
        try:
            locate('Save',case+'-options',30)
            render=time.monotonic()-started
            screen(case+'-options-visible')
            # Back arrow is visible in the retained Options screenshot; Flutter's native route toolbar.
            focus(rwin); run('xdotool','getwindowgeometry','--shell',rwin)
            run('xdotool','mousemove','--window',rwin,'28','28','click','1'); time.sleep(1)
            focus(rwin); screen(case+'-returned-from-options')
            locate('Options',case+'-accept-ready',10)
            # Recorded returned-screen screenshot: Accept center is (669,670),
            # receiver client origin (150,120), hence client-relative (519,550).
            run('xdotool','mousemove','--window',rwin,'519','550','click','1'); time.sleep(1)
            screen(case+'-accepted')
            end=time.monotonic()+180
            while time.monotonic()<end and len(list(dest.rglob('*.txt')))<count: time.sleep(1)
            files=list(dest.rglob('*.txt')); valid=len(files)==count and all(p.read_bytes()==content for p in files)
            screen(case+'-completed')
            result={'count':count,'options_response_seconds':render,'saved_files':len(files),'content_valid':valid,'failure':None if valid else 'save mismatch'}
        except Exception as e:
            screen(case+'-failure'); result={'count':count,'failure':str(e),'receiver_exit':receiver.poll(),'options_response_seconds':locals().get('render')}
        stop.set(); sampler.join(); results.append(result); (out/'results.json').write_text(json.dumps(results,indent=2))
        if count==5 and not result.get('content_valid'): raise RuntimeError('Small directory control failed; do not interpret large case')
    finally:
        if 'stop' in locals(): stop.set()
        for p,w,pid in apps:
            subprocess.run(['kill',str(pid)],check=False)
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill()
