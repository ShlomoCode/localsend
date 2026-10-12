"""Cloud-only inputs and observation of two unmodified original applications."""
import csv, hashlib, io, json, os, re, shutil, subprocess, sys, threading, time
from pathlib import Path

OUT = Path(sys.argv[1])
SENDER = Path('/home/sender1425')
# Original ReceiveController logs confirm the default save target is the receiver home.
DEST = Path('/home/receiver1425')
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
           ('full-color', ['-resize','300%'],3,0,0,11),
           ('nav', ['-crop','256x250+0+100','+repage','-resize','300%'],3,0,100,6),
           ('selection', ['-crop','650x250+300+60','+repage','-resize','300%'],3,300,60,6),
           ('footer-progress', ['-crop','980x120+10+600','+repage','-resize','300%'],3,10,600,6),
           ('footer-white', ['-crop','900x250+100+500','+repage','-colorspace','Gray','-resize','300%',
                             '-threshold','70%','-negate','-fill','white','-draw','color 0,0 floodfill'],3,100,500,11),
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
    geometry=command(role,'xdotool','getwindowgeometry','--shell',wid)
    source_native=json.loads(Path(LATEST[role]+'-native-window.json').read_text())
    if source_native.get('window')!=wid or source_native.get('pid')!=pid or source_native.get('geometry')!=geometry:
        raise RuntimeError('Native input mapping changed since source frame')
    mark=event('click', role=role, label=label, x=point[0], y=point[1], source_frame=LATEST.get(role),
               native_window=wid,native_pid=pid,native_uid=uid,geometry=geometry)
    command(role, 'xdotool', 'mousemove', '--sync', str(round(point[0])), str(round(point[1])), 'click', '1')
    time.sleep(.4)
    return mark

def modal_cancel_target(stage):
    # The retained failed attempt clicked dimmed footer Cancel outside the modal.
    # Derive the actual bright modal rectangle from this fresh original native viewport.
    words=capture('sender',stage+'-fresh-modal-target')
    stem=LATEST['sender']
    native=json.loads(Path(stem+'-native-window.json').read_text())
    if native.get('name')!='LocalSend': raise RuntimeError('Cancel modal is not in actual sender app')
    geometry=dict(line.split('=',1) for line in native['geometry'].splitlines() if '=' in line)
    x,y,width,height=(int(geometry[k]) for k in ['X','Y','WIDTH','HEIGHT'])
    mask=stem+'-modal-mask.png'
    command('sender','convert',stem+'.png','-crop','%dx%d+%d+%d'%(width,height,x,y),'+repage',
            '-colorspace','Gray','-threshold','90%','-depth','8',mask)
    raw=command('sender','convert',mask,'-define','connected-components:verbose=true','-connected-components','8','null:')
    Path(stem+'-modal-components.txt').write_text(raw)
    # Connected regions exclude the separate bright window-border strip, which broad trim would merge.
    regions=[]
    for line in raw.splitlines():
        match=re.fullmatch(r'\s*\d+: (\d+)x(\d+)\+(\d+)\+(\d+) \S+ ([\d.]+) gray\((255|100%)\)',line)
        if match:
            rw,rh,rx,ry=map(int,match.groups()[:4]);area=float(match.group(5))
            if 250<=rw<width*.9 and 100<=rh<height*.6 and area>rw*rh*.75:
                regions.append((rw,rh,rx,ry))
    if len(regions)!=1: raise RuntimeError('Expected one actual bright modal rectangle: '+str(regions))
    mw,mh,mx,my=regions[0];mx+=x;my+=y
    inside=lambda w: mx<=w['x'] and my<=w['y'] and w['x']+w['w']<=mx+mw and w['y']+w['h']<=my+mh
    modal=[w for w in words if inside(w)]
    descriptions=[w for w in modal if w['text'].strip('?,.')=='really']
    if not descriptions: raise RuntimeError('Modal cancellation description missing')
    titles=[w for w in modal if w['text']=='Cancel' and w['y']<min(d['y'] for d in descriptions)
            and all(any(t['text']==label and abs(t['y']-w['y'])<=14 for t in modal) for label in ['file','transfer'])]
    if not titles: raise RuntimeError('Actual Cancel file transfer modal title missing')
    continues=[w for w in modal if w['text']=='Continue']
    candidates=[w for w in modal if w['text']=='Cancel' and any(abs(w['y']-c['y'])<=14 and w['x']>c['x']+c['w'] for c in continues)]
    if not candidates: raise RuntimeError('Exact Cancel action inside actual modal missing')
    selected=max(candidates,key=lambda w:w['conf'])
    point=(selected['x']+selected['w']/2,selected['y']+selected['h']/2)
    if any(abs(w['x']+w['w']/2-point[0])>6 or abs(w['y']+w['h']/2-point[1])>6 for w in candidates):
        raise RuntimeError('Multiple distinct Cancel actions inside modal')
    event('modal_cancel_target_observed',stage=stage,source_frame=stem,native_window=native,
          bounds={'x':mx,'y':my,'width':mw,'height':mh},point=point,candidates=candidates,
          excluded_cancel_words=[w for w in words if w['text']=='Cancel' and not inside(w)])
    return point

def verified_sender_cancel_return(stage):
    end=time.monotonic()+10
    while True:
        words=capture('sender',stage+'-verify-confirmation-result')
        native=json.loads(Path(LATEST['sender']+'-native-window.json').read_text())
        if native.get('name')=='LocalSend' and all(any(w['text']==label for w in words) for label in ['Receive','Send','Settings']) \
                and not any(w['text']=='Sending' or w['text'].strip('?,.')=='really' for w in words):
            event('sender_cancel_returned_to_root',stage=stage,source_frame=LATEST['sender'])
            return
        if time.monotonic()>=end: raise RuntimeError('Cancel approval not verified: sender did not return to actual app root')
        time.sleep(.3)

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
    if folder:
        # The retained typed-folder chooser remained in Recent with disabled Open even after Return.
        # Navigate its visible Home sidebar and select the actual fixture directory row instead.
        if path.parent!=SENDER: raise RuntimeError('Folder fixture must be in actual sender home')
        click(role,locate(role,'Home',stage+'-folder-home'),'Native chooser Home')
        click(role,locate(role,path.name,stage+'-folder-row'),'Select actual folder row '+path.name)
    else:
        key(role, 'ctrl+l')
        command(role, 'xdotool', 'type', '--clearmodifiers', '--delay', '2', str(path))
        event('type', role=role, text=str(path), purpose='native chooser location')
    click(role, locate(role, 'Open', stage+'-picker-open', bottom=True), 'Open selected folder' if folder else 'Open selected file')
    locate(role, 'Edit', stage+'-selection-accepted', timeout=30)
    selected_window=command(role,'xdotool','getactivewindow').strip()
    if command(role,'xdotool','getwindowname',selected_window).strip()!='LocalSend':
        raise RuntimeError('Native chooser did not return to actual selected app')
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
            relative=p.relative_to(DEST)
            if p.is_file() and not any(part.startswith('.') for part in relative.parts): files[str(relative)]=p.stat().st_size
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

def cancel_case(stage, file_count=6, bytes_each=512*1024*1024, fixture_seed=None):
    fixture=SENDER/stage; fixture.mkdir()
    block=(b'LocalSend original large folder fixture '+(fixture_seed or stage).encode()+b'\n')
    block=(block*((1024*1024)//len(block)+1))[:1024*1024]
    for i in range(file_count):
        with (fixture/('queued-%02d.bin'%i)).open('wb') as f:
            for _ in range(bytes_each//(1024*1024)): f.write(block)
    subprocess.run(['chown','-R','sender1425:sender1425',str(fixture)],check=True)
    expected_hash=sha_file(fixture/'queued-00.bin')
    event('fixture',stage=stage,files=file_count,bytes_each=bytes_each,source=str(fixture),sha256_each=expected_hash,
          fixture_seed=fixture_seed or stage)
    movies=recording(stage)
    try:
        send(fixture,True,stage)
        total_expected=file_count*bytes_each
        end=time.monotonic()+600
        while time.monotonic()<end:
            state=file_state()
            active={p:n for p,n in state.items() if stage in p and 0<n<bytes_each}
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
        still_active={p:n for p,n in file_state().items() if stage in p and 0<n<bytes_each}
        if not still_active:
            event('nonqualifying_finished_during_cancel_location',stage=stage); return {'stage':stage,'qualifying':False}
        click('sender',point,'Cancel active sending session')
        words=capture('sender',stage+'-confirmation')
        if not any(w['text'].strip('?,.')=='really' for w in words):
            if sum(n for p,n in file_state().items() if stage in p)>=total_expected:
                event('nonqualifying_finished_before_confirmation',stage=stage); return {'stage':stage,'qualifying':False}
            raise RuntimeError('Real cancel confirmation not shown')
        sockets(stage+'-before-confirmation')
        confirmation=modal_cancel_target(stage)
        before=file_state()
        total_before=sum(n for p,n in before.items() if stage in p)
        if not any(stage in p and 0<n<bytes_each for p,n in before.items()) or not total_expected*.4 <= total_before <= total_expected*.6:
            event('nonqualifying_midpoint_window_missed',stage=stage,total_native_bytes=total_before,total_expected=total_expected)
            return {'stage':stage,'qualifying':False,'reason':'midpoint window missed before actual confirmation'}
        mark=click('sender',confirmation,'Confirm Cancel transfer inside actual modal')
        confirmation_state=file_state()
        if sum(n for p,n in confirmation_state.items() if stage in p) >= total_expected:
            event('nonqualifying_all_files_finished_at_confirmation',stage=stage)
            return {'stage':stage,'qualifying':False}
        verified_sender_cancel_return(stage)
        event('cancel_confirmed',stage=stage,before=before,input_wall_ns=mark['wall_ns'],source_frame=mark['source_frame'])
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
    # Threshold OCR can interpret the large logo as a word; use clear body text from original color pixels.
    alias_candidates=[w for w in receiver_words if w.get('ocr_region')=='full-color' and w['conf']>=90
                      and w['h']>=25 and w['x']>256 and w['text'].isalpha() and w['text']!='LocalSend']
    if not alias_candidates: raise RuntimeError('Cannot read receiver alias from actual Receive pixels')
    ALIAS_WORD=max(alias_candidates,key=lambda w:w['h'])['text']
    event('receiver_alias_word',word=ALIAS_WORD,entire_large_alias_words=alias_candidates)
    control('initial-control')
    # Root-selected unmodified-app discriminator: only remove queued successors, preserving the original 3 GiB payload bytes.
    event('causal_discriminator',baseline_run=38249423969,baseline_files=6,baseline_bytes_each=512*1024*1024,
          selected_files=1,selected_bytes_each=3*1024*1024*1024,total_bytes=3*1024*1024*1024,
          artifact='unmodified official 1.14 AppImage',native_action='Folder then actual midpoint modal Cancel',rate=RATE)
    RESULTS.append(cancel_case('cancel-single-file',file_count=1,bytes_each=3*1024*1024*1024,fixture_seed='cancel-unbounded'))
    if not RESULTS[-1]['qualifying']:
        raise RuntimeError('Selected link conditions did not yield a genuine midpoint Cancel')
    # Preserve actual state; the control follows normal terminal Done in this unchanged process pair.
    dismiss_terminal_receiver('post-cancel')
    control('post-cancel-control')
    (OUT/'results.json').write_text(json.dumps(RESULTS,indent=2))
finally:
    stop.set();sampler.join()
    (OUT/'results-partial.json').write_text(json.dumps(RESULTS,indent=2))
    for role in ['sender','receiver']:
        capture(role,'final-observation')
    EVENTS.close()
