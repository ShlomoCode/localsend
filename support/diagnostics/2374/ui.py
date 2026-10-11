import csv
import hashlib
import io
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import time

OUT = Path("evidence")
OUT.mkdir(exist_ok=True)
RESULTS = []


def run(*args):
    with (OUT / "inputs.jsonl").open("a") as log:
        log.write(json.dumps({"monotonic": time.monotonic(), "argv": args}) + "\n")
    return subprocess.check_output(args, text=True, timeout=30).strip()


def screen(stage, roi=None, psm=11):
    path = OUT / (stage + ".png")
    run("scrot", str(path))
    image = OUT / (stage + "-ocr.png")
    command = ["convert", str(path)]
    if roi:
        x, y, width, height = roi
        command += ["-crop", f"{width}x{height}+{x}+{y}", "+repage"]
    command += ["-resize", "300%", str(image)]
    run(*command)
    rows = []
    # Sparse OCR skips light text on filled Material buttons. Preserve both
    # contrast passes against the same screenshot instead of guessing clicks.
    for contrast in ("normal", "inverted"):
        ocr_image = image
        if contrast == "inverted":
            ocr_image = OUT / (stage + "-ocr-inverted.png")
            run("convert", str(image), "-negate", str(ocr_image))
        text = run("tesseract", str(ocr_image), "stdout", "--psm", str(psm), "tsv")
        suffix = "" if contrast == "normal" else "-inverted"
        (OUT / (stage + suffix + ".tsv")).write_text(text)
        rows.extend(csv.DictReader(io.StringIO(text), delimiter="\t", quoting=csv.QUOTE_NONE))
    for row in rows:
        row["text"] = row.get("text") or ""
        for key in ("left", "top", "width", "height"):
            row[key] = int(row[key]) // 3
        row["left"] += roi[0] if roi else 0
        row["top"] += roi[1] if roi else 0
    return rows


def locate(label, stage, seconds=20, roi=None, psm=11):
    end = time.monotonic() + seconds
    index = 0
    while True:
        rows = screen(stage + "-" + str(index), roi, psm)
        index += 1
        matches = [row for row in rows if row["text"].strip().lower() == label.lower()]
        if matches:
            row = matches[0]
            return row["left"] + row["width"] // 2, row["top"] + row["height"] // 2
        if time.monotonic() >= end:
            raise RuntimeError("Visible label missing: " + label)
        time.sleep(.5)


def click(point, window=None):
    args = ["xdotool", "mousemove"]
    if window:
        args += ["--window", window]
    run(*args, *map(str, point), "click", "1")
    run("xdotool", "mousemove", "1190", "790")
    time.sleep(.4)


def focus(window):
    run("xdotool", "windowactivate", "--sync", window)
    time.sleep(.5)


def normalize(window, stage):
    for _ in range(3):
        run("xdotool", "windowmove", window, "0", "0")
        run("xdotool", "windowsize", window, "1000", "700")
        time.sleep(.8)
    geometry = run("xdotool", "getwindowgeometry", "--shell", window)
    (OUT / (stage + "-geometry.txt")).write_text(geometry)
    fields = dict(line.split("=", 1) for line in geometry.splitlines())
    if (int(fields["WIDTH"]), int(fields["HEIGHT"])) != (1000, 700):
        raise RuntimeError("Window normalization failed")
    screen(stage)


def window(pid):
    end = time.monotonic() + 30
    while time.monotonic() < end:
        try:
            for wid in run("xdotool", "search", "--onlyvisible", "--pid", str(pid)).split():
                if run("xdotool", "getwindowname", wid) == "LocalSend":
                    return wid
        except subprocess.CalledProcessError:
            pass
        time.sleep(.5)
    raise RuntimeError("App window missing")


assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Cloud only'
VARIANT = os.environ['ISSUE2374_VARIANT']
OUT = Path('evidence') / VARIANT
bundle = Path('/tmp/issue2374-' + VARIANT)
shutil.copytree('released/' + VARIANT, bundle)
profile = bundle / 'settings.json'
profile.write_text(json.dumps({'flutter.ls_version': 3 if VARIANT == 'current' else 2,
                              'flutter.ls_alias': 'Probe2374', 'flutter.ls_locale': 'en',
                              'flutter.ls_minimize_to_tray': False}))
executable = str(bundle / 'localsend_app')
process = None
recording = None


def start(tag):
    global process
    process = subprocess.Popen([executable], stdout=(OUT / (tag + '-app.log')).open('w'), stderr=subprocess.STDOUT)
    wid = window(process.pid)
    focus(wid)
    normalize(wid, tag + '-normalized')
    rows = screen(tag + '-startup')
    if any(row['text'].lower() == 'new' for row in rows):
        click((740, 278))
    locate('Probe2374', tag + '-home', 30)
    return wid


def find_scrolled(label, tag, direction, attempts=15):
    run('xdotool', 'mousemove', '850', '550')
    for i in range(attempts):
        rows = screen(tag + '-' + str(i))
        hits = [r for r in rows if r['text'].lower() == label.lower()]
        if hits:
            r = hits[-1]
            return r['left'] + r['width']//2, r['top'] + r['height']//2
        run('xdotool', 'click', '--repeat', '4', '--delay', '80', str(direction))
        time.sleep(.4)
    raise RuntimeError('Settings label missing: ' + label)


def open_network(tag, enable_advanced=False, filtered=False):
    # The real normalized baseline screenshot shows the small sidebar label
    # at (107,232); sparse full-screen OCR omits it. Crop that visible area.
    click(locate('Settings', tag + '-settings-button', roi=(65, 205, 175, 60), psm=6))
    if enable_advanced:
        click(find_scrolled('Advanced', tag + '-advanced', 5))
        time.sleep(.5)
    # All/Filtered is the unique Network setting button, unlike the repeated
    # Network heading. Locate its rendered label while scrolling settings.
    click(find_scrolled('Filtered' if filtered else 'All', tag + '-network', 4))
    return screen(tag + '-network-page')


def type_filter(value, tag):
    run('xdotool', 'key', '--clearmodifiers', 'ctrl+a')
    run('xdotool', 'type', '--clearmodifiers', '--delay', '80', '--', value)
    time.sleep(1)
    rows = screen(tag)
    (OUT / (tag + '-profile.json')).write_text(profile.read_text())
    return rows


try:
    wid = start('initial')
    open_network('initial', enable_advanced=True)
    click(locate('Whitelist', 'whitelist-checkbox'))
    rows = screen('enabled-whitelist')
    hits = [r for r in rows if r['text'].lower() == 'whitelist']
    checkbox_y = max(r['top'] for r in hits)
    # Ordinary first filter TextField lies below the whitelist/blacklist row;
    # retain its pixels before acting. No program state or event injection.
    click((350, checkbox_y + 85))
    control = type_filter('10.0.0.*', 'valid-wildcard-control')
    assert any(r['text'].lower() == 'preview' for r in control), 'Valid control lost settings UI'
    recording = subprocess.Popen(['ffmpeg', '-y', '-f', 'x11grab', '-framerate', '15', '-video_size', '1200x800',
                                   '-i', os.environ['DISPLAY'], '-t', '10', '-c:v', 'libx264', '-preset', 'ultrafast',
                                   '-pix_fmt', 'yuv420p', str(OUT / 'trigger-continuous.mp4')],
                                  stdout=subprocess.DEVNULL, stderr=(OUT / 'ffmpeg.log').open('w'))
    time.sleep(.7)
    outcome = type_filter('10.0.0.(', 'malformed-trigger')
    lost = not any(r['text'].lower() == 'whitelist' for r in outcome)
    recording.wait(timeout=15)
    assert recording.returncode == 0
    run('xdotool', 'key', '--clearmodifiers', 'Escape')
    time.sleep(.8)
    screen('escape-recovery')
    # ESC returns to settings; enter the persisted Filtered setting again.
    click(find_scrolled('Filtered', 'reopen-filtered', 4))
    reopened = screen('persisted-reopen')
    reopen_lost = not any(r['text'].lower() == 'whitelist' for r in reopened)
    process.terminate()
    process.wait(timeout=10)
    wid = start('restart')
    restarted = open_network('restart', filtered=True)
    restart_lost = not any(r['text'].lower() == 'whitelist' for r in restarted)
    logs = '\n'.join(p.read_text() for p in OUT.glob('*-app.log'))
    result = {'variant': VARIANT, 'trigger_ui_lost': lost, 'reopen_ui_lost': reopen_lost,
              'restart_reopen_ui_lost': restart_lost,
              'exact_format_exception': 'FormatException' in logs and 'Unterminated group' in logs,
              'persisted_filter': json.loads(profile.read_text()).get('flutter.ls_network_whitelist')}
    (OUT / 'results.json').write_text(json.dumps(result, indent=2))
    assert all(result[k] for k in ('trigger_ui_lost', 'reopen_ui_lost', 'restart_reopen_ui_lost', 'exact_format_exception'))
    assert result['persisted_filter'] == ['10.0.0.(']
except Exception as error:
    (OUT / 'harness-error.json').write_text(json.dumps({'error': str(error)}))
    screen('failure')
    raise
finally:
    if process is not None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


