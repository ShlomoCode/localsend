"""Cloud-only actual Linux UI replay; never run this driver locally."""
import csv
import io
import json
import os
import pathlib
import shutil
import subprocess
import time
from PIL import Image

if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise RuntimeError('This diagnostic runs only in the authorized fork Actions')
root = pathlib.Path('/tmp/evidence1840')
events = []

def run(*args):
    return subprocess.run(args, text=True, capture_output=True, timeout=20, check=True).stdout

def record(event, **values):
    events.append(dict(event=event, time=time.time(), **values))
    (root/'events.json').write_text(json.dumps(events, indent=2))

def snap(name):
    image = out/(name+'.png')
    run('scrot', str(image))
    original = Image.open(image)
    enlarged = out/(name+'-ocr.png')
    original.resize((original.width*2, original.height*2)).save(enlarged)
    result = run('tesseract', str(enlarged), 'stdout', '--psm', '11', 'tsv')
    (out/(name+'.tsv')).write_text(result)
    rows = [r for r in csv.DictReader(io.StringIO(result), delimiter='\t') if r['text'].strip()]
    for row in rows:
        for dimension in ('left', 'top', 'width', 'height'):
            row[dimension] = str(int(row[dimension])//2)
    record('screenshot', stage=stage, name=name, labels=[r['text'] for r in rows])
    return rows

def xy(row):
    return int(row['left'])+int(row['width'])//2, int(row['top'])+int(row['height'])//2

def click(x, y):
    run('xdotool', 'mousemove', str(x), str(y), 'click', '1')
    time.sleep(1)

def word(rows, text):
    hits = [r for r in rows if r['text'].lower() == text.lower()]
    if not hits:
        raise RuntimeError('Missing rendered label '+text)
    return hits[0]

def click_word(rows, text):
    click(*xy(word(rows, text)))

def fill(x, y, value):
    click(x, y)
    run('xdotool', 'key', 'ctrl+a')
    run('xdotool', 'type', '--clearmodifiers', '--delay', '60', value)

def favorites():
    stored = json.loads((sender/'settings.json').read_text())
    result = [json.loads(s) if isinstance(s, str) else s for s in stored.get('flutter.ls_favorites', [])]
    return result

for stage, location in [('historical117', '/tmp/release1840'), ('currentc1ce', '/tmp/current1840/app')]:
    out = root/stage
    out.mkdir()
    executable = next(pathlib.Path(location).rglob('localsend_app'))
    record('executable', stage=stage, source=str(executable))
    processes = []
    try:
        for name, port in [('peer', 53317), ('sender', 53318)]:
            directory = pathlib.Path('/tmp/1840-'+stage+'-'+name)
            shutil.copytree(executable.parent, directory)
            # Supported portable configuration. No favorite data is seeded.
            (directory/'settings.json').write_text(json.dumps({'flutter.ls_port':port, 'flutter.ls_alias':'Peer1840' if name=='peer' else 'Sender1840', 'flutter.ls_locale':'en', 'flutter.ls_save_window_placement':False}))
            process = subprocess.Popen([str(directory/'localsend_app')], stdout=(out/(name+'.log')).open('w'), stderr=subprocess.STDOUT)
            processes.append(process)
            time.sleep(12)
            record('process', stage=stage, name=name, pid=process.pid, proc_exe=os.readlink('/proc/'+str(process.pid)+'/exe'))
            windows = run('xdotool', 'search', '--onlyvisible', '--pid', str(process.pid)).splitlines()
            window = windows[-1]
            run('xdotool', 'windowactivate', '--sync', window)
            run('xdotool', 'windowmove', window, '40', '40')
            run('xdotool', 'windowsize', window, '1100', '700')
            time.sleep(2)
            snap(name+'-ready')
            if name=='peer':
                # A real visible peer initialized its normal server before UI creation.
                run('xdotool', 'windowminimize', window)
            else:
                sender = directory
        rows = snap('sender-initial')
        click_word(rows, 'Send')
        rows = snap('send-ready')
        # Locate the icon through its actual Favorites tooltip. Search the
        # rendered Nearby row, without assuming the icon's screenshot pixels.
        nearby = word(rows, 'Nearby')
        y = xy(nearby)[1]
        found = False
        for x in range(150, 1110, 20):
            run('xdotool', 'mousemove', str(x), str(y))
            time.sleep(0.8)
            probe = snap('tooltip-'+str(x))
            if any(r['text'].lower()=='favorites' for r in probe):
                record('favorites-tooltip', stage=stage, x=x, y=y)
                click(x, y)
                found = True
                break
        if not found:
            raise RuntimeError('Favorites icon tooltip not found on the Nearby row')
        rows = snap('favorites-empty')
        click_word(rows, 'Add')
        rows = snap('add-empty')
        # Fields lie immediately below their visible labels.
        name_row = word(rows, 'name')
        ip_row = word(rows, 'IP')
        port_row = word(rows, 'Port')
        field_x = xy(ip_row)[0]+90
        fill(field_x, int(name_row['top'])+45, 'Original1840')
        fill(field_x, int(ip_row['top'])+45, '127.0.0.1')
        fill(field_x, int(port_row['top'])+45, '53317')
        rows = snap('add-filled')
        click_word(rows, 'Confirm')
        time.sleep(4)
        rows = snap('add-confirmed')
        saved = favorites()
        (out/'ui-created-favorites.json').write_text(json.dumps(saved, indent=2))
        if len(saved)!=1 or saved[0]['alias']!='Original1840' or not any(r['text']=='Original1840' for r in rows):
            raise RuntimeError('Actual UI favorite creation control failed')
        for index, new_alias in enumerate(['Changed1840', 'ChangedAgain1840', 'ChangedAgain1840']):
            alias_row = word(rows, saved[0]['alias'])
            # Favorites content is a minimal centered row with the edit icon
            # following the name/IP text. Retain before/after screenshot bounds.
            click(xy(alias_row)[0]+185, xy(alias_row)[1]+10)
            edit = snap('edit-'+str(index)+'-open')
            name_row = word(edit, 'name')
            fill(field_x, int(name_row['top'])+45, new_alias)
            edit = snap('edit-'+str(index)+'-filled')
            click_word(edit, 'Confirm')
            time.sleep(3)
            confirmed = snap('edit-'+str(index)+'-confirmed')
            saved = favorites()
            still_open = any(r['text'].lower()=='delete' for r in confirmed)
            record('edit-outcome', stage=stage, index=index, alias=new_alias, still_open=still_open, saved_alias=saved[0]['alias'])
            (out/('edit-'+str(index)+'-saved.json')).write_text(json.dumps(saved, indent=2))
            if saved[0]['alias'] != new_alias:
                raise RuntimeError('Confirm did not persist requested alias')
            if still_open:
                click_word(confirmed, 'Cancel')
            rows = snap('edit-'+str(index)+'-reopened-list')
        record('stage-complete', stage=stage)
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill()
        time.sleep(2)
