"""Cloud-only actual Linux UI replay; never run this driver locally."""
import csv
import io
import json
import os
import pathlib
import shutil
import signal
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
    # Whole-screen layout segmentation omits the rendered sidebar labels even
    # at 2x. The retained initial screenshot establishes this navigation ROI.
    sidebar = out/(name+'-sidebar.png')
    original.crop((110, 155, 275, 300)).resize((495, 435)).save(sidebar)
    sidebar_result = run('tesseract', str(sidebar), 'stdout', '--psm', '6', 'tsv')
    (out/(name+'-sidebar.tsv')).write_text(sidebar_result)
    sidebar_rows = [r for r in csv.DictReader(io.StringIO(sidebar_result), delimiter='\t') if r['text'].strip()]
    for row in sidebar_rows:
        row['left'] = str(int(row['left'])//3+110)
        row['top'] = str(int(row['top'])//3+155)
        row['width'] = str(int(row['width'])//3)
        row['height'] = str(int(row['height'])//3)
    rows.extend(sidebar_rows)
    center = out/(name+'-center.png')
    original.crop((350, 200, 850, 650)).resize((1500, 1350)).save(center)
    center_result = run('tesseract', str(center), 'stdout', '--psm', '6', 'tsv')
    (out/(name+'-center.tsv')).write_text(center_result)
    center_rows = [r for r in csv.DictReader(io.StringIO(center_result), delimiter='\t') if r['text'].strip()]
    for row in center_rows:
        row['left'] = str(int(row['left'])//3+350)
        row['top'] = str(int(row['top'])//3+200)
        row['width'] = str(int(row['width'])//3)
        row['height'] = str(int(row['height'])//3)
    rows.extend(center_rows)
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
    if any(r['text'].lower()==text.lower() for r in rows):
        click(*xy(word(rows, text)))
        return
    if text not in ('Add', 'Confirm', 'Cancel'):
        raise RuntimeError('Missing rendered label '+text)
    # Run5 favorites-empty.png shows ordinary Material action placement.
    # OCR misses the small button captions. Locate the real filled action by
    # its connected foreground color, retain bounds, and use its Cancel neighbor.
    latest = [e for e in events if e['event']=='screenshot' and e['stage']==stage][-1]['name']
    image = Image.open(out/(latest+'.png')).convert('RGB')
    pixels = image.load()
    points = {(x,y) for y in range(250,650) for x in range(450,850) if pixels[x,y][0]<40 and 80<pixels[x,y][1]<150 and 50<pixels[x,y][2]<145}
    groups = []
    while points:
        seed = points.pop()
        pending = [seed]
        group = [seed]
        while pending:
            x,y = pending.pop()
            for neighbor in ((x-1,y),(x+1,y),(x,y-1),(x,y+1)):
                if neighbor in points:
                    points.remove(neighbor)
                    pending.append(neighbor)
                    group.append(neighbor)
        if len(group)>500: groups.append(group)
    if len(groups)!=1:
        raise RuntimeError('Expected one visible filled dialog action, found '+str(len(groups)))
    group = groups[0]
    left, right = min(p[0] for p in group), max(p[0] for p in group)
    top, bottom = min(p[1] for p in group), max(p[1] for p in group)
    record('rendered-dialog-action', stage=stage, action=text, screenshot=latest, bounds=[left,top,right,bottom], pixels=len(group))
    click(left-48 if text=='Cancel' else (left+right)//2, (top+bottom)//2)

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
    recorder = subprocess.Popen(['ffmpeg', '-y', '-video_size', '1280x900', '-framerate', '10', '-f', 'x11grab', '-i', os.environ['DISPLAY'], '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', str(out/'replay.mp4')], stdout=(out/'video.log').open('w'), stderr=subprocess.STDOUT)
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
        # The Run4 screenshot shows the Favorites tooltip over the actual heart
        # at x680/y241. Anchor to rendered Nearby devices and the established
        # row layout (scan, manual address, favorite, each 40 pixels wide).
        nearby = word(rows, 'Nearby')
        y = xy(nearby)[1]
        devices = word(rows, 'devices')
        x = int(devices['left'])+int(devices['width'])+110
        run('xdotool', 'mousemove', str(x), str(y))
        time.sleep(1)
        snap('favorites-tooltip-before-click')
        record('favorites-icon', stage=stage, x=x, y=y, evidence='Run4 tooltip-670.png and actual row labels')
        click(x, y)
        rows = snap('favorites-empty')
        click_word(rows, 'Add')
        rows = snap('add-cancel-control-open')
        click_word(rows, 'Cancel')
        rows = snap('add-cancel-control-closed')
        if favorites():
            raise RuntimeError('Cancel unexpectedly persisted a favorite')
        record('add-cancel-control', stage=stage, persisted_count=0)
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
        recorder.send_signal(signal.SIGINT)
        try: recorder.wait(timeout=10)
        except subprocess.TimeoutExpired: recorder.kill()
        for process in processes:
            process.terminate()
        for process in processes:
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill()
        time.sleep(2)
