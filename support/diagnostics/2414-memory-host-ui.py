"""Real host/guest UI sequence for the 1 GiB pre-Accept memory experiment."""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import threading
import time

OUT = Path('evidence')
OUT.mkdir(exist_ok=True)
VM = Path('/tmp/issue2414-memory-pair')
CONTENT = b'LocalSend issue 2414 fixed ordinary file content\n'
SOURCE_PAIR = os.environ.get('ISSUE2414_SOURCE_PAIR') == '1'
SSH = ['ssh', '-i', str(VM/'id'), '-p', '2222', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile='+str(VM/'known'), '-o', 'ConnectTimeout=5', 'probe@127.0.0.1']
SCP = ['scp', '-i', str(VM/'id'), '-P', '2222', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile='+str(VM/'known'), '-o', 'ConnectTimeout=5']


def write(name, value):
    (OUT/name).write_text(json.dumps(value, indent=2))


def run(argv, timeout=30):
    with (OUT/'memory-host-input.jsonl').open('a') as log:
        log.write(json.dumps({'host_monotonic': time.monotonic(), 'utc_ns': time.time_ns(), 'argv': argv})+'\n')
    return subprocess.check_output(argv, text=True, timeout=timeout).strip()


def guest(action, *args):
    argv = ['python3', '/home/probe/2414-memory-receiver-driver.py', action, *map(str,args)]
    result = json.loads(run(SSH + ['source /home/probe/desktop-env.sh; '+shlex.join(argv)], 60))
    if action == 'stage' and not result['pss_valid']:
        raise RuntimeError('PSS stage unavailable or process identity changed: '+str(args))
    return result


def desktop(side, *argv):
    if side == 'guest': return guest('desktop', *argv)
    started = time.monotonic()
    return {'output': run(list(map(str,argv))), 'started': started, 'completed': time.monotonic()}


def capture(side, name):
    if side == 'guest':
        return guest('capture', name)
    path = OUT/(name+'.png')
    started = time.monotonic()
    run(['scrot', str(path)])
    return {'path': str(path), 'started': started, 'completed': time.monotonic()}


def ocr(path):
    enlarged = path.with_name(path.stem+'-ocr.png')
    run(['convert', str(path), '-resize', '200%', str(enlarged)])
    tsv = run(['tesseract', str(enlarged), 'stdout', '--psm', '11', 'tsv'])
    path.with_suffix('.tsv').write_text(tsv)
    words = list(csv.DictReader(io.StringIO(tsv), delimiter='\t', quoting=csv.QUOTE_NONE))
    for word in words:
        word['text'] = word.get('text') or ''
        for field in ('left','top','width','height'):
            word[field] = int(word[field])//2
    return words


def host_frame(name):
    capture('host', name)
    return ocr(OUT/(name+'.png'))


def approval_button(count, label, words, source):
    match = next((word for word in words if word['text'].strip()==label), None)
    if match is None:
        # Full-frame PSM 11 misses the action labels. Whole-button PSM 7 also
        # includes the icon/rounded border on the retained Debian Back frame;
        # inspect only its observed text bounds, still requiring the exact label.
        left, top, width, height = (558,658,60,24) if label=='Accept' else (420,658,66,24)
        crop = OUT/f'files-{count}-back-{label.lower()}-ocr.png'
        run(['convert',str(source),'-crop',f'{width}x{height}+{left}+{top}','+repage','-resize','300%',str(crop)])
        tsv = run(['tesseract',str(crop),'stdout','--psm','7','tsv'])
        crop.with_suffix('.tsv').write_text(tsv)
        for word in csv.DictReader(io.StringIO(tsv),delimiter='\t',quoting=csv.QUOTE_NONE):
            if (word.get('text') or '').strip()==label:
                match = {'left':int(word['left'])//3+left,'top':int(word['top'])//3+top,
                         'width':int(word['width'])//3,'height':int(word['height'])//3}
                break
    if match is None: raise RuntimeError(label+' button not observed after Back')
    return match['left']+match['width']//2,match['top']+match['height']//2


def locate_host(label, name, deadline=30):
    end = time.monotonic()+deadline
    index = 0
    while time.monotonic() < end:
        words = host_frame(name+'-'+str(index))
        index += 1
        for word in words:
            if word['text'].strip() == label:
                return word['left']+word['width']//2, word['top']+word['height']//2
        time.sleep(.5)
    raise RuntimeError('Host UI label not observed: '+label)


def guest_frame(name):
    if name.startswith('receiver-ready'):
        normalized = guest('normalize')
        if not normalized['valid']:
            raise RuntimeError('Receiver measured geometry not established')
    remote = guest('capture', name)
    local = OUT/Path(remote['path']).name
    run(SCP+['probe@127.0.0.1:'+remote['path'], str(local)], 45)
    words = ocr(local)
    tokens = {word['text'].strip() for word in words}
    if 'Receiver2414' in tokens:
        # Full-frame PSM 11 omits these small sidebar labels on the Debian
        # retained frame. Require actual label OCR in their observed bounds.
        for label, top in (('Receive', 125), ('Send', 170)):
            if label in tokens:
                continue
            crop = local.with_name(local.stem+'-sidebar-'+label.lower()+'.png')
            run(['convert',str(local),'-crop',f'110x35+70+{top}','+repage','-resize','400%',str(crop)])
            tsv = run(['tesseract',str(crop),'stdout','--psm','7','tsv'])
            crop.with_suffix('.tsv').write_text(tsv)
            for word in csv.DictReader(io.StringIO(tsv),delimiter='\t',quoting=csv.QUOTE_NONE):
                if (word.get('text') or '').strip() == label:
                    observed = {'text':label,'left':int(word['left'])//4+70,'top':int(word['top'])//4+top,
                                'width':int(word['width'])//4,'height':int(word['height'])//4}
                    words.append(observed)
    return words, remote


def check_guest(name, required, deadline=45):
    end = time.monotonic()+deadline
    index = 0
    while time.monotonic() < end:
        words, shot = guest_frame(name+'-'+str(index))
        index += 1
        tokens = {word['text'].strip() for word in words}
        if set(required).issubset(tokens): return words, shot
        if not guest('status')['alive']: raise RuntimeError('Receiver exited before '+name)
        time.sleep(.5)
    raise RuntimeError('Guest UI observation deadline; cause unknown: '+name)


def click(side, point, window=None):
    argv = ['xdotool','mousemove']
    if window: argv += ['--window', str(window)]
    result = desktop(side, *argv, *map(str,point), 'click','1')
    desktop(side, 'xdotool','mousemove','1190','790')
    time.sleep(.3)
    return result


def focus(side, window):
    desktop(side, 'xdotool','windowactivate','--sync',str(window))
    time.sleep(.5)


def host_window(pid):
    end=time.monotonic()+30
    while time.monotonic()<end:
        try:
            for window in desktop('host','xdotool','search','--onlyvisible','--pid',str(pid))['output'].split():
                if desktop('host','xdotool','getwindowname',window)['output']=='LocalSend':
                    desktop('host','xdotool','windowmove',window,'0','0')
                    desktop('host','xdotool','windowsize',window,'1000','700')
                    return window
        except subprocess.CalledProcessError: pass
        time.sleep(1)
    raise RuntimeError('Sender window missing')


def normalize_host(window, case):
    # Apply after the rendered alias is observed: Flutter startup restores its
    # default size after the native window first becomes visible.
    desktop('host','xdotool','windowsize',window,'1000','700')
    desktop('host','xdotool','windowmove',window,'0','0')
    focus('host',window)
    geometry=desktop('host','xdotool','getwindowgeometry','--shell',window)['output']
    (OUT/(case+'-sender-normalized-geometry.txt')).write_text(geometry)
    fields=dict(line.split('=',1) for line in geometry.splitlines() if '=' in line)
    if (fields.get('WIDTH'),fields.get('HEIGHT')) != ('1000','700') or fields.get('X') not in ('0','1','2') or fields.get('Y') not in ('0','20','40'):
        raise RuntimeError('Sender measured geometry not established: '+geometry)
    capture('host',case+'-sender-normalized')
    return geometry


def sender_sample(pid, stop, path):
    with path.open('w', buffering=1) as log:
        while not stop.wait(.5):
            record={'host_monotonic':time.monotonic(),'pid':pid}
            for key,source in [('stat',f'/proc/{pid}/stat'),('status',f'/proc/{pid}/status')]:
                try: record[key]=Path(source).read_text()
                except OSError as error: record[key]=str(error)
            log.write(json.dumps(record)+'\n')


def metadata_fixture(count):
    fixture=Path.home()/('Case2414Files'+str(count)+('Flat' if SOURCE_PAIR else ''))
    fixture.mkdir(exist_ok=True)
    manifest=[]
    for index in range(count):
        leaf=f'file-{index:05d}-'+('a'*65)+'.txt' if SOURCE_PAIR else f'file-{index:05d}.txt'
        if SOURCE_PAIR and len(leaf.encode('ascii')) != 80:
            raise RuntimeError('Fixture leaf length differs from plan')
        path=fixture/leaf
        path.write_bytes(CONTENT)
        manifest.append({'name':path.name,'relative_path':fixture.name+'/'+path.name,'size':len(CONTENT),'sha256':hashlib.sha256(CONTENT).hexdigest()})
    if {path.name for path in fixture.iterdir()} != {entry['name'] for entry in manifest}:
        raise RuntimeError('Fixture directory contains unexpected entries')
    write(f'files-{count}-manifest.json',manifest)
    return fixture


def run_case(count):
    case='files-'+str(count)
    result={'count':count,'classification':'running','stage':'setup','failure':None}
    sender=None
    receiver_started=False
    stop=threading.Event()
    sampler=None
    try:
        fixture=metadata_fixture(count)
        bundle=Path('/tmp')/(case+'-memory-host-sender')
        shutil.copytree('released/base',bundle)
        (bundle/'settings.json').write_text(json.dumps({'flutter.ls_alias':'Sender2414','flutter.ls_port':53317,'flutter.ls_locale':'en','flutter.ls_minimize_to_tray':False}))
        receiver_started=True
        receiver=guest('start',count)
        rwin=receiver['window']
        result['receiver']=receiver
        if not guest('status')['sampler_alive']:
            raise RuntimeError('Receiver sampler did not become active')
        check_guest('receiver-ready',['Receiver2414','Receive','Send'],30)
        result['receiver_ready_geometry']=guest('normalize')
        if not result['receiver_ready_geometry']['valid']:
            raise RuntimeError('Receiver geometry changed after readiness')
        guest('stage','ready')
        capture('guest','ready')
        with (OUT/(case+'-sender.log')).open('w') as log:
            sender=subprocess.Popen([str(bundle/'localsend_app')],stdout=log,stderr=subprocess.STDOUT)
        sampler=threading.Thread(target=sender_sample,args=(sender.pid,stop,OUT/(case+'-sender-samples.jsonl')),daemon=True)
        sampler.start()
        swin=host_window(sender.pid)
        focus('host',swin)
        locate_host('Sender2414',case+'-sender-ready')
        result['sender_ready_geometry']=normalize_host(swin,case)
        if SOURCE_PAIR:
            loaded_maps=Path(f'/proc/{sender.pid}/maps').read_text()
            (OUT/(case+'-sender-ready-loaded-maps.txt')).write_text(loaded_maps)
            if 'libdartjni.so' in loaded_maps or 'libjvm.so' in loaded_maps:
                raise RuntimeError('Sender loaded JNI unexpectedly; runtime qualification must be revised')
        capture('host',case+'-sender-ready')
        result['stage']='picker'
        click('host',(96,188))
        click('host',(514,150))
        locate_host('Recent',case+'-picker-ready',15)
        chooser=desktop('host','xdotool','search','--onlyvisible','--name','Choose Directory')['output'].split()[-1]
        focus('host',chooser)
        if SOURCE_PAIR:
            # GTK rendered the exact directory correctly, but full-frame OCR
            # confused 5 with S. Use the native location field with the exact
            # fixture path; approval counts and saved hashes qualify selection.
            desktop('host','xdotool','key','ctrl+l')
            desktop('host','xdotool','type','--clearmodifiers','--',str(fixture))
            desktop('host','xdotool','key','Return')
            time.sleep(2)
        else:
            click('host',locate_host('Home',case+'-home'))
            time.sleep(2)
            click('host',locate_host(fixture.name,case+'-folder-row'))
        capture('host',case+'-folder-selected')
        click('host',locate_host('Open',case+'-picker-open'))
        time.sleep(2)
        # The measured interval begins five seconds after the sampler is known active.
        target = locate_host('Receiver2414',case+'-target',60)
        time.sleep(5)
        result['metrics_before_metadata']=guest('metrics')
        if result['metrics_before_metadata']['records']<10 or result['metrics_before_metadata']['read_error_records']:
            raise RuntimeError('Receiver observer baseline samples missing or unreadable')
        result['metadata_request_host_monotonic']=time.monotonic()
        result['stage']='approval'
        click('host',target)
        time.sleep(3)
        focus('guest',rwin)
        # No OCR/SCP runs in this measured interval. The retained 1000x700
        # approval has Options at absolute (517,611). Inputs use
        # screenshot coordinates, avoiding the Openbox client/frame offset.
        approval=guest('capture','approval')
        guest('stage','approval')
        result['approval_capture']=approval
        if SOURCE_PAIR:
            result['recording']=guest('record-start')
        result['stage']='options'
        result['options_click']=click('guest',(517,611))
        start=time.monotonic()
        result['options_hold_origin_host_monotonic']=start
        options=guest('capture','options')
        guest('stage','options')
        result['options_capture']=options
        result['options_stages']=[]
        for delay,label in [(1,'options-plus-1'),(5,'options-plus-5'),(10,'options-plus-10')]:
            time.sleep(max(0,start+delay-time.monotonic()))
            actual_host_offset=time.monotonic()-start
            measurement=guest('stage',label)
            result['options_stages'].append({'requested_offset_seconds':delay,
                                            'actual_host_offset_seconds':actual_host_offset,
                                            'actual_guest_offset_from_input_seconds':measurement['guest_monotonic']-result['options_click']['started'],
                                            'measurement':measurement})
        result['hold_elapsed_host_seconds']=time.monotonic()-start
        held_capture=guest('capture','options-after-hold')
        result['held_options_capture']=held_capture
        result['held_capture_guest_offset_from_input_seconds']=held_capture['started']-result['options_click']['started']
        result['metrics_after_hold']=guest('metrics')
        if (result['metrics_after_hold']['records'] <= result['metrics_before_metadata']['records']
                or result['metrics_after_hold']['read_error_records']
                or result['metrics_after_hold']['last_guest_monotonic'] - result['metrics_before_metadata']['last_guest_monotonic'] < 10):
            raise RuntimeError('Receiver observer did not cover the measured hold')
        # OCR only after the measured window, from retained raw frames.
        for stage_name in ('approval','options','options-after-hold'):
            remote=f'/home/probe/evidence/files-{count}-{stage_name}.png'
            local=OUT/Path(remote).name
            run(SCP+['probe@127.0.0.1:'+remote,str(local)],45)
            words=ocr(local)
            result[stage_name+'_tokens']=[word['text'] for word in words if word['text'].strip()]
        option_words=ocr(OUT/f'files-{count}-options.png')
        option_title=any(word['text'].strip()=='Options' and word['top']<100 for word in option_words)
        result['initial_options_list_observed']=option_title and {'Save','Files','49B'}.issubset(result['options_tokens'])
        if not {'Options','wants',str(count)}.issubset(result['approval_tokens']):
            raise RuntimeError('Approval not established by retained screenshot')
        held_words=ocr(OUT/f'files-{count}-options-after-hold.png')
        result['held_options_list_observed']=(any(word['text'].strip()=='Options' and word['top']<100 for word in held_words)
                                              and {'Save','Files','49B'}.issubset(result['options-after-hold_tokens']))
        result['nominal_options_hold_after_input_wrapper_seconds']=10
        if not result['held_options_list_observed']:
            raise RuntimeError('Options list not observed after nominal ten-second hold; cause unknown')
        result['stage']='return'
        guest('stage','before-cancel')
        if not SOURCE_PAIR or count != 5000:
            result['back_click']=click('guest',(28,28),rwin)
        # The retained 5000-file frame is still Options around input+1.2s,
        # then approval by+3.4s. Observe the normal transition with a bounded
        # wait rather than declaring failure from one early screenshot.
        if SOURCE_PAIR and count==5000:
            result['scroll_down']=desktop('guest','xdotool','mousemove','600','450','click','--repeat','8','--delay','100','5')
            time.sleep(2)
            result['scroll_down_capture']=guest('capture','scroll-down')
            result['scroll_down_stage']=guest('stage','scroll-down')
            result['scroll_up']=desktop('guest','xdotool','mousemove','600','450','click','--repeat','8','--delay','100','4')
            time.sleep(2)
            result['scroll_up_capture']=guest('capture','scroll-up')
            result['scroll_up_stage']=guest('stage','scroll-up')
            # Return once after actual scrolling, then reopen in the same PID.
            result['back_click']=click('guest',(28,28),rwin)
        returned,return_capture=check_guest('back',['wants','Sender2414',str(count),'Options'],30)
        result['back_approval_capture']=return_capture
        result['back_approval_guest_offset_from_input_seconds']=return_capture['completed']-result['back_click']['started']
        return_source=OUT/Path(return_capture['path']).name
        if SOURCE_PAIR and count==5000:
            result['back_stage']=guest('stage','back')
            result['reopen_click']=click('guest',(517,611))
            time.sleep(10)
            result['reopen_capture']=guest('capture','reopen')
            result['reopen_stage']=guest('stage','reopen')
            reopened,_=check_guest('reopen-observed',['Options','Files','49B'],30)
            result['reopen_tokens']=[word['text'] for word in reopened]
            result['second_back_click']=click('guest',(28,28),rwin)
            returned,return_capture=check_guest('second-back',['wants','Sender2414',str(count),'Options'],30)
            return_source=OUT/Path(return_capture['path']).name
        if count==5:
            result['stage']='control-save'
            click('guest',approval_button(count,'Accept',returned,return_source))
            end=time.monotonic()+120
            while time.monotonic()<end:
                saved=guest('verify')
                if saved['content_valid']: break
                time.sleep(2)
            result['verify']=saved
            if not saved['content_valid']: raise RuntimeError('Five-file save did not verify')
            check_guest(case+'-finished',['Finished'],30)
            locate_host('Finished',case+'-sender-finished',30)
            capture('guest','finished')
            result['classification']='qualified-five-file-control'
        else:
            result['stage']='cancel'
            # The released UI labels normal rejection Decline. Resolve its
            # actual bounds from the post-hold Back screenshot before clicking.
            result['decline_click']=click('guest',approval_button(count,'Decline',returned,return_source))
            guest('capture','cancel')
            cancelled,cancel_capture=check_guest('cancel-observed',['Receiver2414','Receive','Send'],30)
            result['cancel_home_capture']=cancel_capture
            result['cancel_home_guest_offset_from_input_seconds']=cancel_capture['completed']-result['decline_click']['started']
            cancel_tokens={word['text'].strip() for word in cancelled}
            result['cancel_tokens']=sorted(cancel_tokens)
            if 'wants' in cancel_tokens or not {'Receive','Send'}.issubset(cancel_tokens):
                raise RuntimeError('Normal cancellation transition not observed')
            result['verify_no_save']=guest('verify')
            if result['verify_no_save']['saved_files'] != 0:
                raise RuntimeError('Pre-Accept case unexpectedly saved files')
            result['classification']='pre-accept-options-observed-and-cancelled'
        result['receiver_final_status']=guest('status')
        if not result['receiver_final_status']['alive']:
            raise RuntimeError('Receiver process exited; inspect supervisor and kernel evidence')
        if not result['receiver_final_status']['sampler_alive']:
            raise RuntimeError('Receiver sampler exited before case completion')
        if not (result['receiver_final_status']['kernel']['journal_read_succeeded']
                and result['receiver_final_status']['kernel']['baseline_read_succeeded']):
            raise RuntimeError('Kernel evidence unavailable; no OOM absence claim is qualified')
    except Exception as error:
        result.update({'failure':str(error),'classification':'unknown-cause-or-infrastructure-failure'})
        for side in ('host','guest'):
            try: result[side+'_failure_capture']=capture(side,case+'-failure')
            except Exception as failure: result[side+'_capture_error']=str(failure)
        try:
            status=guest('status')
            if status.get('count')==count:
                result['receiver_failure_status']=status
                receiver_started=True
                result['classification']=('receiver-process-exited-awaiting-kernel-correlation'
                                          if not status['alive'] else 'infrastructure-or-control-failure'
                                          if result['stage'] in ('setup','picker','control-save') or not status['sampler_alive']
                                          else 'ui-stage-not-observed-cause-unknown')
        except Exception as failure:
            result['status_error']=str(failure)
    finally:
        stop.set()
        if sampler: sampler.join(timeout=3)
        if sender:
            sender.terminate()
            try: sender.wait(timeout=5)
            except subprocess.TimeoutExpired:
                sender.kill(); sender.wait(timeout=5)
        if receiver_started:
            try:
                result['cleanup']=guest('stop')
                lifecycle=result['cleanup'].get('lifecycle')
                if not result['cleanup']['stopped'] or not isinstance(lifecycle,str) or not any(json.loads(line).get('event')=='exited' for line in lifecycle.splitlines() if line.strip()):
                    raise RuntimeError('Receiver cleanup or supervisor exit record not established')
                if SOURCE_PAIR and not result['cleanup'].get('recording',{}).get('finalized'):
                    raise RuntimeError('Recorder completion not established; do not continue to another case')
            except Exception as error:
                result['cleanup_error']=str(error)
                if not result['failure']:
                    result.update({'failure':str(error),'classification':'infrastructure-or-control-failure'})
        write(case+'-memory-result.json',result)
    return result


def main():
    results=[]
    for count in ((5,5000) if SOURCE_PAIR else (5,500,5000)):
        result=run_case(count)
        results.append(result)
        write('memory-results.json',results)
        print(json.dumps({'phase':'case-complete',**result}),flush=True)
        if result['failure']: raise SystemExit(f'{count}-file case failed; inspect evidence')
        if count==5 and not SOURCE_PAIR:
            checkpoint=OUT/'vm'/'checkpoint-guest'
            checkpoint.parent.mkdir(exist_ok=True)
            run(SCP+['-r','probe@127.0.0.1:/home/probe/evidence',str(checkpoint)],120)
            (OUT/'memory-checkpoint-ready').write_text('Five-file control qualified; guest evidence copied\n')
            print(json.dumps({'phase':'memory-checkpoint-ready'}),flush=True)
            resume=Path('/tmp/issue2414-memory-continue')
            end=time.monotonic()+900
            while not resume.exists() and time.monotonic()<end: time.sleep(1)
            if not resume.exists(): raise RuntimeError('Checkpoint continuation deadline (workflow infrastructure)')
        if count==500 and result['classification']!='pre-accept-options-observed-and-cancelled':
            raise SystemExit('500-file case did not qualify continuation')

if __name__=='__main__': main()
