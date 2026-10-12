"""Cloud-only inputs and observation of two unmodified original applications."""
import csv, hashlib, io, json, os, shutil, subprocess, sys, threading, time
from pathlib import Path

OUT = Path(sys.argv[1])
SENDER = Path('/home/sender1425')
DEST = Path('/home/receiver1425/Downloads')
DISPLAYS = {'sender': ':81', 'receiver': ':82'}
COUNTERS = {'sender': 0, 'receiver': 0}
EVENTS = (OUT / 'inputs.jsonl').open('w')
LATEST = {}

def event(kind, **fields):
    item = {'wall_ns': time.time_ns(), 'monotonic_ns': time.monotonic_ns(), 'kind': kind, **fields}
    EVENTS.write(json.dumps(item) + '\n'); EVENTS.flush()
    print(json.dumps(item), flush=True)
    return item

def command(role, *args):
    return subprocess.check_output(args, env={**os.environ, 'DISPLAY': DISPLAYS[role]}, text=True, stderr=subprocess.STDOUT)

def capture(role, stage):
    COUNTERS[role] += 1
    stem = OUT / ('%s-%04d-%s' % (role, COUNTERS[role], stage))
    command(role, 'scrot', str(stem) + '.png')
    LATEST[role]=str(stem)
    native={}
    try:
        wid=command(role,'xdotool','getactivewindow').strip()
        native={'window':wid,'name':command(role,'xdotool','getwindowname',wid).strip(),
                'geometry':command(role,'xdotool','getwindowgeometry','--shell',wid),
                'pid':command(role,'xdotool','getwindowpid',wid).strip()}
    except subprocess.CalledProcessError as e:
        native={'unavailable':str(e)}
    Path(str(stem)+'-native-window.json').write_text(json.dumps(native,indent=2))
    words = []
    # Full-screen PSM11 omits small left-navigation labels in original retained wide-home pixels.
    # Keep those original pixels and separately OCR the observed navigation/footer regions.
    modes=[('full', ['-colorspace','Gray','-resize','200%','-threshold','70%','-negate'],2,0,0,11),
           ('nav', ['-crop','256x250+0+100','+repage','-resize','300%'],3,0,100,6),
           ('footer', ['-crop','600x400+500+400','+repage','-resize','300%'],3,500,400,6)]
    for name,filters,scale,offset_x,offset_y,psm in modes:
        variant=str(stem)+'-ocr-'+name+'.png'
        command(role,'convert',str(stem)+'.png',*filters,variant)
        ocr=subprocess.run(['tesseract',variant,'stdout','--psm',str(psm),'tsv'],
                           env={**os.environ,'DISPLAY':DISPLAYS[role]},text=True,capture_output=True,check=True)
        Path(str(stem)+'-ocr-'+name+'.log').write_text(ocr.stderr)
        Path(str(stem)+'-'+name+'.tsv').write_text(ocr.stdout)
        rows=list(csv.DictReader(io.StringIO(ocr.stdout),delimiter='\t',quoting=csv.QUOTE_NONE))
        for row in rows:
            if row.get('text','').strip() and float(row['conf'])>=45:
                words.append({'text':row['text'].strip(),'x':int(row['left'])/scale+offset_x,
                              'y':int(row['top'])/scale+offset_y,'w':int(row['width'])/scale,
                              'h':int(row['height'])/scale,'conf':float(row['conf']),'ocr_region':name})
    event('screen', role=role, stem=str(stem), native_window=native, words=words)
    return words

def locate(role, label, stage, timeout=25, bottom=False):
    end = time.monotonic() + timeout
    while True:
        words = capture(role, stage)
        matches = [w for w in words if w['text'].strip(':.,') == label]
        if matches:
            word = max(matches, key=lambda w: w['y']) if bottom else matches[0]
            return word['x'] + word['w']/2, word['y'] + word['h']/2
        if time.monotonic() >= end:
            raise RuntimeError('Visible label missing: ' + role + ' ' + label)
        time.sleep(.4)

def click(role, point, label):
    wid=command(role,'xdotool','getactivewindow').strip()
    pid=command(role,'xdotool','getwindowpid',wid).strip()
    uid=subprocess.check_output(['ps','-o','uid=','-p',pid],text=True).strip()
    expected_uid=subprocess.check_output(['id','-u',role+'1425'],text=True).strip()
    if uid!=expected_uid: raise RuntimeError('Foreground input target belongs to unexpected uid: '+uid)
    event('click', role=role, label=label, x=point[0], y=point[1], source_frame=LATEST.get(role),
          native_window=wid,native_pid=pid,native_uid=uid,geometry=command(role,'xdotool','getwindowgeometry','--shell',wid))
    command(role, 'xdotool', 'mousemove', '--sync', str(round(point[0])), str(round(point[1])), 'click', '1')
    time.sleep(.4)

def key(role, *keys):
    event('key', role=role, keys=keys)
    command(role, 'xdotool', 'key', '--clearmodifiers', *keys)

def app_ready(role):
    end = time.monotonic() + 60
    window=None
    while time.monotonic() < end:
        if window is None:
            try:
                ids = command(role, 'xdotool', 'search', '--onlyvisible', '--name', '^LocalSend$').split()
            except subprocess.CalledProcessError:
                ids=[]
            if len(ids)>1: raise RuntimeError('Expected one LocalSend window: '+repr(ids))
            if len(ids)==1:
                window=ids[0]
                pid=command(role,'xdotool','getwindowpid',window).strip()
                owner=subprocess.check_output(['ps','-o','uid=','-p',pid],text=True).strip()
                expected_owner=subprocess.check_output(['id','-u',role+'1425'],text=True).strip()
                if owner!=expected_owner: raise RuntimeError('Window belongs to unexpected uid: '+owner)
                command(role, 'xdotool', 'windowactivate', '--sync', window)
                command(role, 'xdotool', 'windowmove', window, '0', '0')
                command(role, 'xdotool', 'windowsize', window, '1000', '700')
                event('app_window', role=role, id=window, owner=owner,
                      geometry=command(role, 'xdotool', 'getwindowgeometry', '--shell', window),pid=pid)
                time.sleep(1)
        words = capture(role, 'startup')
        confirm = next((w for w in words if w['text'] == 'Confirm'), None)
        if confirm:
            click(role, (confirm['x']+confirm['w']/2, confirm['y']+confirm['h']/2), 'first launch Confirm')
        else:
            if window and any(w['text'] == 'Settings' for w in words) and any(w['text'] == 'Send' for w in words):
                return window
        time.sleep(1)
    raise RuntimeError('Application startup did not reach normal home: ' + role)

def select(role, path, folder, stage):
    click(role, locate(role, 'Send', stage+'-send', bottom=True), 'Send tab')
    words = capture(role, stage+'-selection')
    if any(w['text'] == 'Edit' for w in words):
        # Single-send completed controls clear selection. A cancelled session can retain it.
        click(role, locate(role, 'Edit', stage+'-edit'), 'Edit selected files')
        click(role, locate(role, 'Delete', stage+'-delete-all'), 'Delete all retained selection (ordinary UI)')
        capture(role,stage+'-cleared-selection')
    click(role, locate(role, 'Folder' if folder else 'File', stage+'-picker'), 'Folder' if folder else 'File')
    time.sleep(1)
    capture(role, stage+'-native-picker')
    key(role, 'ctrl+l')
    command(role, 'xdotool', 'type', '--clearmodifiers', '--delay', '2', str(path))
    event('type', role=role, text=str(path), purpose='native chooser location')
    if folder:
        # GTK SELECT_FOLDER accepts a typed existing directory on Return as well.
        # Use its observed native Open button directly, avoiding a second response.
        click(role, locate(role, 'Open', stage+'-picker-open'), 'Open selected folder')
    else:
        key(role, 'Return')
    time.sleep(1)
    capture(role, stage+'-selected')

def send(path, folder, stage):
    select('sender', path, folder, stage)
    # Normal discovery: the exact historical release has no manual-IP sending action.
    click('sender', locate('sender', ALIAS_WORD, stage+'-receiver-target', timeout=60), 'actual discovered receiver ' + ALIAS_WORD)
    accept = locate('receiver', 'Accept', stage+'-request', timeout=30, bottom=True)
    words = capture('receiver', stage+'-before-accept')
    if not any(w['text'].strip('.,') == 'wants' for w in words):
        raise RuntimeError('Accept not anchored to an actual incoming request')
    click('receiver', accept, 'Accept real incoming transfer')
    event('accepted', stage=stage)

def file_state():
    files={}
    for p in DEST.rglob('*'):
        try:
            if p.is_file(): files[str(p.relative_to(DEST))]=p.stat().st_size
        except FileNotFoundError:
            pass  # A native unlink is a normal observation transition, not an assertion.
    return files

def sample(stop):
    with (OUT / 'native-file-timeline.jsonl').open('w') as f:
        while not stop.is_set():
            f.write(json.dumps({'wall_ns':time.time_ns(), 'monotonic_ns':time.monotonic_ns(), 'files':file_state()})+'\n')
            f.flush(); stop.wait(.1)

def control(stage):
    payload = SENDER / (stage+'.txt')
    payload.write_bytes((stage+' real LocalSend sender selection and receiver approval\n').encode()*1024)
    subprocess.run(['chown','sender1425:sender1425',str(payload)], check=True)
    send(payload, False, stage)
    end = time.monotonic() + 30
    saved = DEST / payload.name
    while time.monotonic() < end and (not saved.exists() or saved.stat().st_size != payload.stat().st_size):
        time.sleep(.2)
    if not saved.exists() or saved.read_bytes() != payload.read_bytes():
        raise RuntimeError('Control actual saved bytes mismatch: ' + stage)
    event('control_pass', stage=stage, expected_sha256=hashlib.sha256(payload.read_bytes()).hexdigest(),
          saved_sha256=hashlib.sha256(saved.read_bytes()).hexdigest(), saved_path=str(saved), bytes=saved.stat().st_size)
    (OUT/(stage+'-saved.txt')).write_bytes(saved.read_bytes())
    for role in ['sender', 'receiver']:
        click(role, terminal_done(role,stage+'-done'), 'Done completed control')

def sha_file(path,limit=None):
    digest=hashlib.sha256()
    with path.open('rb') as f:
        remaining=limit
        while remaining is None or remaining>0:
            block=f.read(1024*1024 if remaining is None else min(1024*1024,remaining))
            if not block: break
            digest.update(block)
            if remaining is not None: remaining-=len(block)
    return digest.hexdigest()

def terminal_done(role,stage,timeout=15):
    end=time.monotonic()+timeout
    while True:
        words=capture(role,stage)
        advanced=[w for w in words if w['text']=='Advanced']
        if advanced:
            anchor=max(advanced,key=lambda w:w['y'])
            footer=[w for w in words if abs(w['y']-anchor['y'])<=14 and w['x']>anchor['x']+anchor['w']]
            done=next((w for w in footer if w['text']=='Done'),None)
            if done and not any(w['text']=='Cancel' for w in footer):
                event('terminal_footer_observed',role=role,stage=stage,words=footer)
                return done['x']+done['w']/2,done['y']+done['h']/2
        if time.monotonic()>=end: raise RuntimeError('No terminal footer Done; active sessions are preserved: '+role)
        time.sleep(.5)

def recording(stage):
    processes=[]
    for role in ['sender','receiver']:
        log=(OUT/(stage+'-'+role+'-ffmpeg.log')).open('w')
        p=subprocess.Popen(['ffmpeg','-y','-f','x11grab','-framerate','10','-video_size','1100x800','-i',DISPLAYS[role],
                            '-c:v','libx264','-preset','ultrafast','-crf','24','-pix_fmt','yuv420p',str(OUT/(stage+'-'+role+'-original.mp4'))],stdout=log,stderr=log)
        processes.append((p,log))
    return processes

def sockets(stage):
    for role in ['sender', 'receiver']:
        raw=subprocess.check_output(['ip','netns','exec',role+'1425','ss','-tinp'],text=True,stderr=subprocess.STDOUT)
        (OUT/(stage+'-'+role+'-sockets.txt')).write_text(raw)
    event('sockets_retained',stage=stage)

def cancel_case(stage):
    fixture=SENDER/stage; fixture.mkdir()
    block=(b'LocalSend original large folder fixture '+stage.encode()+b'\n')
    block=(block*((1024*1024)//len(block)+1))[:1024*1024]
    for i in range(6):
        with (fixture/('queued-%02d.bin'%i)).open('wb') as f:
            for _ in range(512): f.write(block)
    subprocess.run(['chown','-R','sender1425:sender1425',str(fixture)],check=True)
    expected_hash=sha_file(fixture/'queued-00.bin')
    event('fixture',stage=stage,files=6,bytes_each=512*1024*1024,source=str(fixture),sha256_each=expected_hash)
    movies=recording(stage)
    try:
        send(fixture,True,stage)
        total_expected=6*512*1024*1024
        end=time.monotonic()+600
        while time.monotonic()<end:
            state=file_state()
            active={p:n for p,n in state.items() if stage in p and 0<n<512*1024*1024}
            total=sum(n for p,n in state.items() if stage in p)
            if active and total_expected*.4 <= total <= total_expected*.6: break
            if total >= total_expected:
                event('nonqualifying_finished_before_cancel',stage=stage); return {'stage':stage,'qualifying':False}
            time.sleep(.1)
        else: raise RuntimeError('No native active upload reached midpoint deadline')
        event('midpoint_active',stage=stage,files=active,total_native_bytes=total,middle_window_fraction=[.4,.6])
        try:
            point=locate('sender','Cancel',stage+'-cancel',timeout=10,bottom=True)
        except RuntimeError:
            if sum(n for p,n in file_state().items() if stage in p)>=total_expected:
                event('nonqualifying_finished_during_cancel_location',stage=stage); return {'stage':stage,'qualifying':False}
            raise
        # Locate and native-size sampling can outlast a fast unbounded transfer.
        still_active={p:n for p,n in file_state().items() if stage in p and 0<n<512*1024*1024}
        if not still_active:
            event('nonqualifying_finished_during_cancel_location',stage=stage); return {'stage':stage,'qualifying':False}
        click('sender',point,'Cancel active sending session')
        words=capture('sender',stage+'-confirmation')
        if not any(w['text'].strip('?,.')=='really' for w in words):
            if sum(n for p,n in file_state().items() if stage in p)>=total_expected:
                event('nonqualifying_finished_before_confirmation',stage=stage); return {'stage':stage,'qualifying':False}
            raise RuntimeError('Real cancel confirmation not shown')
        confirmation=locate('sender','Cancel',stage+'-confirm-cancel',timeout=10,bottom=True)
        before=file_state()
        sockets(stage+'-before-confirmation')
        total_before=sum(n for p,n in before.items() if stage in p)
        if not any(stage in p and 0<n<512*1024*1024 for p,n in before.items()) or not total_expected*.4 <= total_before <= total_expected*.6:
            event('nonqualifying_midpoint_window_missed',stage=stage,total_native_bytes=total_before,total_expected=total_expected)
            return {'stage':stage,'qualifying':False,'reason':'midpoint window missed before actual confirmation'}
        click('sender',confirmation,'Confirm Cancel transfer')
        confirmation_state=file_state()
        if sum(n for p,n in confirmation_state.items() if stage in p) >= 6*512*1024*1024:
            event('nonqualifying_all_files_finished_at_confirmation',stage=stage)
            return {'stage':stage,'qualifying':False}
        mark=event('cancel_confirmed',stage=stage,before=before)
        time.sleep(3)
        quiet=file_state()
        quiet_mark=event('quiet_sample',stage=stage,elapsed_since_confirmation_s=(time.time_ns()-mark['wall_ns'])/1e9)
        sockets(stage+'-after-3s')
        capture('sender',stage+'-after-cancel'); capture('receiver',stage+'-after-cancel')
        time.sleep(12)
        after=file_state()
        after_mark=event('final_sample',stage=stage,elapsed_since_confirmation_s=(time.time_ns()-mark['wall_ns'])/1e9)
        sockets(stage+'-after-15s')
        newer={p:n for p,n in after.items() if stage in p and p not in quiet and n>0}
        growth={p:n-quiet.get(p,0) for p,n in after.items() if stage in p and n>quiet.get(p,0)}
        verified_prefix={}
        for p in set(newer)|set(growth):
            size=min(after[p],(DEST/p).stat().st_size)
            actual_hash=sha_file(DEST/p,size)
            source_hash=sha_file(fixture/Path(p).name,size)
            verified_prefix[p]={'bytes':size,'source_prefix_sha256':source_hash,'saved_prefix_sha256':actual_hash,'match':source_hash==actual_hash}
        result={'stage':stage,'qualifying':True,'cancel_wall_ns':mark['wall_ns'],'at_cancel':before,
                'quiet_sample':quiet,'quiet_elapsed_s':(quiet_mark['wall_ns']-mark['wall_ns'])/1e9,
                'final_sample':after,'final_elapsed_s':(after_mark['wall_ns']-mark['wall_ns'])/1e9,
                'nonzero_new_files_after_quiet':newer,'growth_after_quiet':growth,'prefix_checks':verified_prefix,
                'native_growth_observed':bool(newer or growth),'classification_requires_socket_and_timeline_review':True,'rate':RATE}
        event('cancel_result',**result)
        return result
    finally:
        for p,log in movies:
            p.send_signal(2)
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:p.kill();p.wait()
            log.close()

def dismiss_terminal_receiver(stage):
    # Historical source retains a terminal receive session until its normal Done action.
    # Do not cancel or restart a still-running receiver to make the next control pass.
    point=terminal_done('receiver',stage+'-receiver-terminal-done')
    click('receiver',point,'Done terminal cancelled/completed receiver session')
    event('terminal_session_dismissed_by_user',stage=stage,scope='Fresh control tests normal user completion, not automatic removal')

def finish_fast_transfer():
    for role in ['sender','receiver']:
        words=capture(role,'fast-transfer-final-state')
        if any(w['text'].strip('?,.')=='really' for w in words):
            key(role,'Escape');time.sleep(.5)
            capture(role,'fast-confirmation-dismissed')
    end=time.monotonic()+600
    while time.monotonic()<end:
        files={p:n for p,n in file_state().items() if 'cancel-unbounded' in p}
        if len(files)==6 and all(n==512*1024*1024 for n in files.values()):
            event('unbounded_native_folder_fully_completed',files=files)
            break
        time.sleep(.2)
    else: raise RuntimeError('Unbounded transfer has not fully completed; no normal-link completion or rate-fallback claim')
    for role in ['sender','receiver']:
        words=capture(role,'fast-native-completion-ui')
        done=[w for w in words if w['text'].strip('.,')=='Done']
        if done:
            click(role,terminal_done(role,'fast-terminal-footer'),'Done fast completed transfer')
        elif not (role=='sender' and any(w['text']=='Settings' for w in words)):
            raise RuntimeError('Fast transfer did not reach observed terminal/home UI: '+role)

RESULTS=[]
RATE='unbounded-veth'
stop=threading.Event(); sampler=threading.Thread(target=sample,args=(stop,));sampler.start()
try:
    app_ready('sender'); app_ready('receiver')
    receiver_words=capture('receiver','observed-alias')
    alias_candidates=[w for w in receiver_words if w['h']>=25 and w['text']!='LocalSend']
    if not alias_candidates: raise RuntimeError('Cannot read receiver alias from actual Receive pixels')
    ALIAS_WORD=max(alias_candidates,key=lambda w:w['h'])['text']
    event('receiver_alias_word',word=ALIAS_WORD,entire_large_alias_words=alias_candidates)
    control('initial-control')
    RESULTS.append(cancel_case('cancel-unbounded'))
    if not RESULTS[-1]['qualifying']:
        # A completed fast transfer is not a cancel trial. Close through real Done before applying a constant normal link rate.
        finish_fast_transfer()
        # Fully completed fast data is verified and retained as hashes before disk reclamation.
        fixture=SENDER/'cancel-unbounded'
        saved=DEST/'cancel-unbounded'
        comparisons=[]
        for source in sorted(fixture.iterdir()):
            target=saved/source.name
            source_hash=sha_file(source); saved_hash=sha_file(target)
            if source_hash!=saved_hash: raise RuntimeError('Completed fast folder content mismatch')
            comparisons.append({'name':source.name,'sha256':source_hash,'bytes':target.stat().st_size})
        event('completed_fast_folder_verified_before_fixture_cleanup',files=comparisons)
        shutil.rmtree(fixture);shutil.rmtree(saved)
        subprocess.run(['ip','netns','exec','sender1425','tc','qdisc','add','dev','send1425','root','tbf','rate','50mbit','burst','64kb','latency','50ms'],check=True)
        RATE='constant-50mbit-normal-network'
        event('network_rate_needed',reason='Original link missed active40–60% confirmation window; native3GiB completion, terminalUI and all saved hashes observed before fallback',rate=RATE)
        RESULTS.append(cancel_case('cancel-rate-1'))
    if not RESULTS[-1]['qualifying']:
        raise RuntimeError('Selected link conditions did not yield a genuine midpoint Cancel')
    # Preserve state if the original bug leaves an active transfer. A fresh control must be attempted in this same process pair.
    dismiss_terminal_receiver('post-cancel')
    control('post-cancel-control')
    RESULTS.append(cancel_case('cancel-replay-2'))
    if not RESULTS[-1]['qualifying']:
        raise RuntimeError('Second fixed replay did not reach genuine midpoint Cancel; no repeatability claim')
    dismiss_terminal_receiver('final-cancel')
    control('final-control')
    (OUT/'results.json').write_text(json.dumps(RESULTS,indent=2))
finally:
    stop.set();sampler.join()
    (OUT/'results-partial.json').write_text(json.dumps(RESULTS,indent=2))
    for role in ['sender','receiver']:
        capture(role,'final-observation')
    EVENTS.close()
