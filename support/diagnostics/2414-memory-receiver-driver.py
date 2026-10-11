"""Low-overhead receiver supervisor for the 1 GiB real-desktop experiment."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path('/home/probe')
OUT = ROOT / 'evidence'
OUT.mkdir(exist_ok=True)
STATE = OUT / 'memory-state.json'
CONTENT = b'LocalSend issue 2414 fixed ordinary file content\n'


def write(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
    temporary.write_text(json.dumps(value, indent=2))
    os.replace(temporary, path)


def read(path):
    try:
        return Path(path).read_text()
    except OSError as error:
        return {'error': str(error)}


def proc_start(pid):
    value = read(f'/proc/{pid}/stat')
    try:
        return value.rsplit(')', 1)[1].split()[19] if isinstance(value, str) else None
    except (IndexError, ValueError):
        return None


def alive(state):
    value = read(f"/proc/{state['pid']}/stat")
    try:
        fields = value.rsplit(')', 1)[1].split()
        return state.get('starttime') is not None and fields[19] == state['starttime'] and fields[0] != 'Z'
    except (AttributeError, IndexError, ValueError):
        return False


def vmstat():
    value = read('/proc/vmstat')
    return '\n'.join(line for line in value.splitlines()
                     if line.startswith(('pswpin ', 'pswpout ', 'pgfault ', 'pgmajfault '))) if isinstance(value, str) else value


def journal(state, label):
    started = time.monotonic()
    read_succeeded = True
    read_error = None
    try:
        data = subprocess.check_output(['sudo', 'journalctl', '-k', '--no-pager', '-o', 'short-monotonic'], text=True, timeout=25)
        # journalctl exits zero for an empty journal too. That cannot qualify
        # an absence-of-OOM observation, so require retained kernel entries.
        if not re.search(r'^\[\s*\d+\.\d+\]', data, re.M):
            read_succeeded = False
            read_error = 'Kernel journal contains no timestamped entries'
    except Exception as error:
        data = str(error)
        read_succeeded = False
        read_error = str(error)
    (OUT / f"files-{state['count']}-{label}-kernel.txt").write_text(data)
    metadata = OUT / f"files-{state['count']}-{label}-kernel-read.json"
    write(metadata, {'read_succeeded': read_succeeded, 'error': read_error})
    baseline = read(OUT / f"files-{state['count']}-baseline-kernel.txt")
    baseline_metadata = OUT / f"files-{state['count']}-baseline-kernel-read.json"
    try:
        baseline_succeeded = json.loads(baseline_metadata.read_text())['read_succeeded']
    except (OSError, ValueError, KeyError):
        baseline_succeeded = False
    baseline_lines = set(baseline.splitlines()) if isinstance(baseline, str) else set()
    oom_lines = ([line for line in data.splitlines() if line not in baseline_lines and re.search('out of memory|killed process|oom-kill', line, re.I)]
                 if read_succeeded and baseline_succeeded else None)
    victims = ([line for line in oom_lines if re.search(r'Killed process\s+' + str(state['pid']) + r'\b', line, re.I)]
               if oom_lines is not None else None)
    return {'oom_lines_since_baseline': oom_lines, 'matching_pid_victim_lines': victims,
            'journal_read_succeeded': read_succeeded, 'journal_read_error': read_error,
            'baseline_read_succeeded': baseline_succeeded,
            'started': started, 'completed': time.monotonic(),
            'interpretation': 'PID-matched kernel evidence; correlate event time with launch/starttime before claiming OOM'}


def sample(state):
    count, pid = state['count'], state['pid']
    path = OUT / f'files-{count}-memory-samples.jsonl'
    with path.open('a', buffering=1) as output:
        while True:
            started = time.monotonic()
            stat = read(f'/proc/{pid}/stat')
            sampler_stat = read(f'/proc/{os.getpid()}/stat')
            record = {'guest_monotonic': started, 'utc_ns': time.time_ns(), 'pid': pid,
                      'expected_starttime': state['starttime'], 'stat': stat,
                      'status': read(f'/proc/{pid}/status'), 'meminfo': read('/proc/meminfo'),
                      'vmstat': vmstat(),
                      'pressure_memory': read('/proc/pressure/memory'),
                      'sampler_pid': os.getpid(), 'sampler_stat': sampler_stat,
                      'sampler_status': read(f'/proc/{os.getpid()}/status'),
                      'clock_ticks_per_second': os.sysconf('SC_CLK_TCK')}
            record['read_completed'] = time.monotonic()
            record['read_duration_seconds'] = record['read_completed'] - started
            output.write(json.dumps(record) + '\n')
            if not alive(state):
                break
            time.sleep(max(0, .5 - (time.monotonic() - started)))


def stage(state, name):
    if not re.fullmatch(r'[a-z0-9-]+', name):
        raise ValueError('Invalid stage')
    pid = state['pid']
    start = time.monotonic()
    pss = read(f'/proc/{pid}/smaps_rollup')
    done = time.monotonic()
    record = {'stage': name, 'guest_monotonic': start, 'pss_read_completed': done,
              'pss_read_duration_seconds': done-start, 'pid': pid,
              'expected_starttime': state['starttime'], 'observed_starttime': proc_start(pid),
              'smaps_rollup': pss, 'status': read(f'/proc/{pid}/status'),
              'meminfo': read('/proc/meminfo'), 'pressure_memory': read('/proc/pressure/memory'),
              'vmstat': vmstat()}
    record['read_completed'] = time.monotonic()
    record['read_duration_seconds'] = record['read_completed'] - start
    record['pss_valid'] = (isinstance(pss, str) and record['observed_starttime'] == state['starttime']
                           and all(re.search(r'^' + key + r':\s+\d+ kB$', pss, re.M)
                                   for key in ('Rss', 'Pss', 'Swap', 'SwapPss')))
    with (OUT / f"files-{state['count']}-stages.jsonl").open('a') as output:
        output.write(json.dumps(record) + '\n')
    return record


def supervisor(count):
    bundle = ROOT / f'receiver-{count}'
    shutil.copytree(ROOT / 'released/base', bundle)
    destination = ROOT / f'received-{count}'
    destination.mkdir()
    (bundle / 'settings.json').write_text(json.dumps({'flutter.ls_alias': 'Receiver2414', 'flutter.ls_port': 53317,
        'flutter.ls_locale': 'en', 'flutter.ls_destination': str(destination), 'flutter.ls_quick_save': False,
        'flutter.ls_minimize_to_tray': False}))
    journal({'count': count, 'pid': None}, 'baseline')
    with (OUT / f'files-{count}-receiver.log').open('w') as log:
        child = subprocess.Popen([str(bundle / 'localsend_app')], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        state = {'count': count, 'pid': child.pid, 'starttime': proc_start(child.pid),
                 'destination': str(destination), 'supervisor_pid': os.getpid(), 'launched_monotonic': time.monotonic()}
        # Publish launch identity immediately for cleanup even if sampling fails.
        # Readiness waits for sampler_pid before adding window, avoiding a race.
        write(STATE, state)
        if state['starttime'] is None:
            child.terminate()
            try:
                rc = child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                rc = child.wait(timeout=5)
            with (OUT / f'files-{count}-lifecycle.jsonl').open('a') as lifecycle:
                lifecycle.write(json.dumps({'event': 'exited', 'returncode': rc,
                                           'guest_monotonic': time.monotonic(), 'harness_stop_requested': True,
                                           'reason': 'launch identity unavailable', **state}) + '\n')
            return
        sampler = None
        try:
            sampler = subprocess.Popen([sys.executable, __file__, 'sample', json.dumps(state)], stdout=subprocess.DEVNULL,
                                       stderr=(OUT / f'files-{count}-sampler.log').open('w'), start_new_session=True)
            state['sampler_pid'] = sampler.pid
            state['sampler_starttime'] = proc_start(sampler.pid)
        except Exception as error:
            state['sampler_error'] = str(error)
        write(STATE, state)
        with (OUT / f'files-{count}-lifecycle.jsonl').open('a', buffering=1) as lifecycle:
            lifecycle.write(json.dumps({'event': 'launched', **state}) + '\n')
            rc = child.wait()
            lifecycle.write(json.dumps({'event': 'exited', 'returncode': rc, 'guest_monotonic': time.monotonic(),
                                        'harness_stop_requested': (OUT / f'files-{count}-stop-requested').exists()}) + '\n')
        try:
            if sampler is None: return
            sampler.wait(timeout=5)
        except subprocess.TimeoutExpired:
            sampler.terminate()
            sampler.wait(timeout=5)


def main():
    action = sys.argv[1]
    if action == 'supervisor':
        supervisor(int(sys.argv[2])); return
    if action == 'sample':
        sample(json.loads(sys.argv[2])); return
    if action == 'start':
        count = int(sys.argv[2])
        if count not in (5, 500, 5000) or STATE.exists() and alive(json.loads(STATE.read_text())):
            raise RuntimeError('Invalid count or prior receiver still alive')
        STATE.unlink(missing_ok=True)
        process = subprocess.Popen([sys.executable, __file__, 'supervisor', str(count)],
            stdout=(OUT / f'files-{count}-supervisor.log').open('w'), stderr=subprocess.STDOUT, start_new_session=True)
        end = time.monotonic() + 40
        while time.monotonic() < end:
            if STATE.exists():
                state = json.loads(STATE.read_text())
                if state.get('count') == count and 'sampler_pid' in state:
                    try:
                        windows = subprocess.check_output(['xdotool', 'search', '--onlyvisible', '--pid', str(state['pid'])], text=True, timeout=3).split()
                        for window in windows:
                            if subprocess.check_output(['xdotool', 'getwindowname', window], text=True, timeout=3).strip() == 'LocalSend':
                                subprocess.run(['xdotool', 'windowmove', window, '0', '0'], check=True, timeout=3)
                                subprocess.run(['xdotool', 'windowsize', window, '1000', '700'], check=True, timeout=3)
                                state['window'] = window
                                write(STATE, state)
                                print(json.dumps(state)); return
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                        pass
            if process.poll() is not None:
                raise RuntimeError('Supervisor exited before window')
            time.sleep(.5)
        raise RuntimeError('Receiver window readiness deadline; cause unknown')
    state = json.loads(STATE.read_text())
    if action == 'desktop':
        argv = sys.argv[2:]
        with (OUT / f"files-{state['count']}-inputs.jsonl").open('a') as log:
            log.write(json.dumps({'guest_monotonic': time.monotonic(), 'argv': argv}) + '\n')
        started = time.monotonic()
        output = subprocess.check_output(argv, text=True, timeout=20).strip()
        print(json.dumps({'output': output, 'started': started, 'completed': time.monotonic()}))
    elif action == 'capture':
        name = sys.argv[2]
        if not re.fullmatch(r'[a-z0-9-]+', name): raise ValueError('Invalid capture name')
        path = OUT / f"files-{state['count']}-{name}.png"
        started = time.monotonic()
        subprocess.run(['scrot', str(path)], check=True, timeout=10)
        report = {'path': str(path), 'started': started, 'completed': time.monotonic()}
        with (OUT / f"files-{state['count']}-captures.jsonl").open('a') as log: log.write(json.dumps(report) + '\n')
        print(json.dumps(report))
    elif action == 'stage':
        print(json.dumps(stage(state, sys.argv[2])))
    elif action == 'metrics':
        first = last = None
        records = errors = 0
        with (OUT / f"files-{state['count']}-memory-samples.jsonl").open() as samples:
            for line in samples:
                record = json.loads(line)
                first = record if first is None else first
                last = record
                records += 1
                if any(not isinstance(record.get(key),str) for key in ('stat','status','meminfo','vmstat','pressure_memory')):
                    errors += 1
        print(json.dumps({'records':records,'read_error_records':errors,
                          'first_guest_monotonic':first['guest_monotonic'] if first else None,
                          'last_guest_monotonic':last['guest_monotonic'] if last else None}))
    elif action == 'status':
        sampler_state = {'pid': state.get('sampler_pid'), 'starttime': state.get('sampler_starttime')}
        kernel = journal(state, 'status')
        print(json.dumps({**state, 'observed_starttime': proc_start(state['pid']),
            'alive': alive(state), 'sampler_alive': alive(sampler_state),
            'lifecycle': read(OUT / f"files-{state['count']}-lifecycle.jsonl"),
            'kernel': kernel}))
    elif action == 'verify':
        files = [path for path in Path(state['destination']).rglob('*') if path.is_file()]
        expected = {f'file-{i:05d}.txt' for i in range(state['count'])}
        digest = hashlib.sha256(CONTENT).hexdigest()
        valid = len(files) == state['count'] and {path.name for path in files} == expected and all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path in files)
        print(json.dumps({'content_valid': valid, 'saved_files': len(files), 'expected_sha256': digest}))
    elif action == 'stop':
        marker = OUT / f"files-{state['count']}-stop-requested"
        marker.write_text(str(time.monotonic()))
        journal(state, 'final')
        was_alive = alive(state)
        if was_alive:
            os.kill(state['pid'], signal.SIGTERM)
        end = time.monotonic() + 10
        while alive(state) and time.monotonic() < end: time.sleep(.2)
        forced = alive(state)
        if forced:
            os.kill(state['pid'], signal.SIGKILL)
            (OUT / f"files-{state['count']}-cleanup-kill").write_text('Harness SIGKILL after SIGTERM deadline')
        end = time.monotonic() + 10
        lifecycle_path = OUT / f"files-{state['count']}-lifecycle.jsonl"
        lifecycle = read(lifecycle_path)
        while time.monotonic() < end:
            lifecycle = read(lifecycle_path)
            if isinstance(lifecycle, str) and any(json.loads(line).get('event') == 'exited' for line in lifecycle.splitlines() if line.strip()):
                break
            time.sleep(.2)
        print(json.dumps({'stopped': not alive(state), 'harness_term_sent': was_alive,
                         'harness_kill_sent': forced, 'lifecycle': lifecycle,
                         'guest_monotonic': time.monotonic()}))
    else: raise ValueError(action)

if __name__ == '__main__': main()
