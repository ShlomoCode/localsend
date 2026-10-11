#!/usr/bin/env bash
# Shared Debian 12 guest preflight. Container mode validates tools and ABI, not swap configuration.
set -euo pipefail
export LC_ALL=C
mode=${1:-vm}
case "$mode" in vm|container-tools) ;; *) exit 2 ;; esac
cd /home/probe
mkdir -p evidence
dpkg-query -W > evidence/package-inventory.txt
/sbin/ldconfig -p > evidence/library-inventory.txt
/sbin/swapon --help > evidence/swapon-help.txt
{ uname -a; lscpu; free -m; /sbin/swapon --show --bytes; cat /proc/meminfo; cat /proc/sys/vm/swappiness; findmnt --target /swap.img; cat /etc/os-release; } > evidence/environment.txt
/sbin/swapon --show=NAME --noheadings > evidence/swap-names.txt
/sbin/swapon --show=SIZE --noheadings --bytes > evidence/swap-sizes.txt
swap_file_bytes=$(stat --format=%s /swap.img)
page_size=$(getconf PAGESIZE)
swap_type=$(findmnt -n -o FSTYPE --target /swap.img)
printf 'mode=%s\nfile_bytes=%s\npage_size=%s\nfilesystem=%s\n' "$mode" "$swap_file_bytes" "$page_size" "$swap_type" > evidence/swap-file-contract.txt
if test "$mode" = vm; then
  test "$(/sbin/swapon --show=NAME --noheadings | wc -l)" = 1
  test "$(/sbin/swapon --show=NAME --noheadings)" = /swap.img
  # The swap header consumes one page; the on-disk allocation remains 2 GiB.
  test "$swap_file_bytes" = 2147483648
  expected_swap_bytes=$((2147483648 - page_size))
  test "$(/sbin/swapon --show=SIZE --noheadings --bytes | tr -d '[:space:]')" = "$expected_swap_bytes"
  test "$swap_type" != tmpfs
  test "$swap_type" != ramfs
fi
python3 - <<'PY'
import json
from pathlib import Path
import re
import subprocess

bundle = Path('/home/probe/released/base')
output = Path('/home/probe/evidence')
cache = subprocess.check_output(['/sbin/ldconfig', '-p'], text=True)
libraries = {}
for line in cache.splitlines():
    match = re.match(r'\s*(\S+) .*=> (\S+)', line)
    if match and 'x86-64' in line:
        libraries.setdefault(match[1], []).append(Path(match[2]))
records = []
failures = []
all_elf = [path for path in bundle.rglob('*') if path.is_file() and path.open('rb').read(4) == b'\x7fELF']
source_pair = Path('/home/probe/source-pair-mode').exists() and Path('/home/probe/source-pair-mode').read_text().strip() == '1'
optional = bundle / 'lib/libdartjni.so'
optional_records = []
if source_pair and optional in all_elf:
    # JNI 1.0.0's Flutter CMake target is optional, and its Dart library loads
    # lazily. It is not registered as a Linux native plugin or used by this
    # app's Linux folder/send/save route. Keep the artifact untouched and
    # transparently record its unresolved Java dependency. Any real DT_NEEDED
    # edge to it below still traverses it and fails the closure normally.
    optional_records.append({'path': str(optional),
        'role': 'Dormant optional JNI root on the Linux file route; require real control and loaded-map verification',
        'dynamic': subprocess.check_output(['readelf', '-d', str(optional)], text=True),
        'versions': subprocess.check_output(['readelf', '-V', str(optional)], text=True),
        'unresolved_optional_dependency': 'libjvm.so; no JRE installed solely to satisfy all-ELF inspection',
        'source': 'jni1.0.0 src/CMakeLists.txt optional Flutter JNI; lib/src/jni.dart lazy _dylib; exact app Linux registrant and NativeAssetsManifest'})
pending = [path for path in all_elf if not (source_pair and path == optional)]
roots = list(map(str, pending))
visited = set()
while pending:
    path = pending.pop()
    if path in visited:
        continue
    visited.add(path)
    header = subprocess.check_output(['readelf', '-h', '-l', str(path)], text=True)
    dynamic = subprocess.check_output(['readelf', '-d', str(path)], text=True)
    versions = subprocess.check_output(['readelf', '-V', str(path)], text=True)
    record = {'path': str(path), 'headers': header, 'dynamic': dynamic, 'versions': versions, 'resolved': {}}
    if 'Advanced Micro Devices X86-64' not in header:
        failures.append(f'Unexpected ELF architecture: {path}')
    interpreter = re.search(r'Requesting program interpreter: ([^\]]+)', header)
    if interpreter and not Path(interpreter[1]).is_file():
        failures.append(f'Missing interpreter: {interpreter[1]}')
    for soname in re.findall(r'\(NEEDED\).*\[([^\]]+)\]', dynamic):
        bundled = bundle / 'lib' / soname
        options = [bundled] if bundled.is_file() else libraries.get(soname, [])
        if not options:
            failures.append(f'Missing DT_NEEDED {soname} for {path}')
            continue
        library = options[0]
        record['resolved'][soname] = str(library)
        pending.append(library)
    # Compare required version names with definitions on the resolved SONAME.
    needs = versions.split('Version needs section', 1)[-1] if 'Version needs section' in versions else ''
    for part in re.split(r'File: ', needs)[1:]:
        soname = part.split()[0]
        required = set(re.findall(r'Name: (\S+)', part))
        resolved = record['resolved'].get(soname)
        if not resolved:
            failures.append(f'{path}: unresolved version-needs provider {soname}')
            continue
        provided = subprocess.check_output(['readelf', '-V', resolved], text=True)
        definitions = provided.split('Version needs section', 1)[0]
        available = set(re.findall(r'Name: (\S+)', definitions))
        missing = sorted(required - available)
        if missing:
            failures.append(f'{path}: {soname} lacks {missing}')
    records.append(record)
(output / 'static-abi-preflight.json').write_text(json.dumps({'scope': 'Static readelf runtime closure; no artifact execution or ldd',
    'roots': roots, 'optional_artifacts': optional_records, 'records': records, 'failures': failures}, indent=2))
if failures:
    raise SystemExit('\n'.join(failures))
PY
