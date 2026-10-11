import csv
import io
import json
from pathlib import Path
import subprocess
from PIL import Image

source = Image.open(next(Path('/tmp/ocr-reference').rglob('settings-button-0.png')))
results = []
for region, crop in [('full', (0, 0, source.width, source.height)), ('sidebar', (0, 100, 256, 300))]:
    part = source.crop(crop)
    path = Path('evidence') / (region + '.png')
    part.resize((part.width * 3, part.height * 3), Image.Resampling.LANCZOS).save(path)
    for mode in ['6', '11', '12']:
        tsv = subprocess.check_output(['tesseract', str(path), 'stdout', '--psm', mode, 'tsv'], text=True)
        Path('evidence', region + '-' + mode + '.tsv').write_text(tsv)
        words = list(csv.DictReader(io.StringIO(tsv), delimiter='\t', quoting=csv.QUOTE_NONE))
        names = [w['text'] for w in words if w['text']]
        result = {'region': region, 'mode': mode, 'recognized': names, 'settings_found': 'Settings' in names}
        results.append(result)
        print(json.dumps(result))
Path('evidence', 'ocr-probe.json').write_text(json.dumps(results, indent=2))
assert any(r['region'] == 'sidebar' and r['settings_found'] for r in results), 'Sidebar OCR remains unverified'
server_source = Image.open(next(Path('/tmp/ocr-reference').rglob('server-row-11.png')))
server_source.resize((server_source.width * 3, server_source.height * 3), Image.Resampling.LANCZOS).save('evidence/server.png')
tsv = subprocess.check_output(['tesseract', 'evidence/server.png', 'stdout', '--psm', '11', 'tsv'], text=True)
words = list(csv.DictReader(io.StringIO(tsv), delimiter='\t', quoting=csv.QUOTE_NONE))
for word in words:
    for key in ['left', 'top', 'width', 'height']:
        word[key] = str(int(word[key]) // 3)
matches = [w for w in words if w['text'].strip() == 'Server']
Path('evidence/server-lookup.json').write_text(json.dumps({'words': words, 'matches': matches}, indent=2))
assert matches, 'Same screenshot Server parser does not match'
