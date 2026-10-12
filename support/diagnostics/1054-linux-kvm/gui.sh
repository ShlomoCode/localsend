#!/usr/bin/env bash
set -euo pipefail
# All children belong to this evidence directory. DISPLAY is inherited from
# the entry's private xvfb-run; this helper never changes a display or service.
exec ruby - "$@" <<'RUBY'
require 'json'
require 'fileutils'
require 'time'
%w[INT TERM].each { |signal| Signal.trap(signal) { raise "GUI interrupted by #{signal}" } }

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
def receipt(path, data)
  File.write(path + '.tmp', JSON.pretty_generate(data) + "\n")
  File.rename(path + '.tmp', path)
end
def alive(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end
def identity(pid)
  raw = File.read("/proc/#{pid}/stat")
  fields = raw[(raw.rindex(')') + 2)..-1].split
  executable = begin File.readlink("/proc/#{pid}/exe"); rescue Errno::ENOENT; nil; end
  { 'pid' => pid, 'group' => Integer(fields.fetch(2)), 'starttime' => fields.fetch(19), 'executable' => executable,
    'zombie' => fields[0] == 'Z' }
rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
  nil
end
def register(pid, argv)
  owner = identity(pid)
  raise 'Cannot retain spawned process identity' unless owner && owner['group'] == pid
  owner['argv'] = argv
  @owners[pid.to_s] = owner
  owner
end
def same_identity(current, saved)
  current && saved && current['pid'] == saved['pid'] && current['group'] == saved['group'] &&
    current['starttime'] == saved['starttime'] &&
    (current['zombie'] || current['executable'] == saved['executable'])
end
def group_members(group)
  Dir.glob('/proc/[0-9]*/stat').each_with_object([]) do |path, members|
    member = identity(Integer(path.split('/')[2], 10))
    members << member if member && member['group'] == group && !member['zombie']
  end
end
def kill_owned(pid, owner = nil)
  return { 'state' => 'stopped' } unless pid
  owner ||= @owners[pid.to_s]
  return { 'pid' => pid, 'state' => 'identity-missing' } unless owner && owner['group'] == pid
  current = identity(pid)
  members = group_members(pid)
  return { 'pid' => pid, 'state' => 'stopped' } if !current && members.empty?
  return { 'pid' => pid, 'state' => 'identity-mismatch' } unless same_identity(current, owner)
  return { 'pid' => pid, 'state' => 'identity-mismatch' } unless same_identity(identity(pid), owner) &&
    members.all? { |member| Integer(member['starttime']) >= Integer(owner['starttime']) }
  # Snapshot members only while the original group leader still matches. Each
  # individual signal checks starttime/group/executable again; no saved numeric
  # process-group ID is signalled after its leader has disappeared.
  members.each do |member|
    begin
      Process.kill('TERM', member['pid']) if same_identity(identity(member['pid']), member)
    rescue Errno::ESRCH
    end
  end
  limit = [now + 0.5, @deadline].min
  sleep 0.02 while !group_members(pid).empty? && now < limit
  members.each do |member|
    begin
      Process.kill('KILL', member['pid']) if same_identity(identity(member['pid']), member)
    rescue Errno::ESRCH
    end
  end
  limit = [now + 0.5, @deadline].min
  sleep 0.02 while !group_members(pid).empty? && now < limit
  begin Process.waitpid(pid, Process::WNOHANG); rescue Errno::ECHILD; end
  { 'pid' => pid, 'state' => group_members(pid).empty? ? 'stopped' : 'unconfirmed' }
end
def remaining
  seconds = @deadline - now
  raise 'GUI absolute deadline exhausted' unless seconds > 0
  seconds
end
def bounded(argv, name, maximum = 5)
  limit = now + [remaining, maximum].min
  output = File.join(@dir, name)
  pid = Process.spawn(*argv, out: output, err: output + '.stderr', pgroup: true)
  owner = register(pid, argv)
  command_state = File.join(@dir, 'active-command.json')
  receipt(command_state, { pid: pid, argv: argv, owner: owner })
  status = nil
  loop do
    result = Process.waitpid2(pid, Process::WNOHANG)
    if result
      status = result[1]
      break
    end
    raise "#{name} timed out" unless now < limit
    sleep [0.03, limit - now].min
  end
  remaining
  raise "#{name} failed: #{status.exitstatus}" unless status.success?
  File.read(output)
ensure
  stopped = status || !pid || kill_owned(pid, owner)['state'] == 'stopped'
  File.unlink(command_state) if stopped && command_state && File.exist?(command_state)
end
def load_state
  JSON.parse(File.read(File.join(@dir, 'owned.json')))
end
def clean(state)
  results = []
  active = File.join(@dir, 'active-command.json')
  if File.exist?(active)
    command = JSON.parse(File.read(active))
    result = kill_owned(command.fetch('pid'), command['owner'])
    results << result
    File.unlink(active) if result['state'] == 'stopped'
  end
  %w[recorderPid viewerPid wmPid].each do |key|
    result = kill_owned(state[key])
    results << result
    state.delete(key) if result['state'] == 'stopped'
  end
  state['cleanupResults'] = results
  state['cleanupConfirmed'] = results.all? { |result| result['state'] == 'stopped' }
  state['cleanedUtc'] = Time.now.utc.iso8601(6) if state['cleanupConfirmed']
  receipt(File.join(@dir, 'owned.json'), state)
  state['cleanupConfirmed']
end

state = {}
begin
  raise 'Usage: gui.sh <start|record|stop|cleanup> EVIDENCE [STAGE_SECONDS]' unless (2..3).cover?(ARGV.length)
  action, evidence, allowance = ARGV
  raise 'Unknown GUI action' unless %w[start record stop cleanup].include?(action)
  @dir = File.join(File.expand_path(evidence), 'gui')
  FileUtils.mkdir_p(@dir)
  state_path = File.join(@dir, 'owned.json')
  state = load_state if File.exist?(state_path)
  @owners = state.fetch('processOwners', {})
  if action == 'cleanup'
    # Passive workflow cleanup has a separate reserve after xvfb-run exits.
    # It must not depend on DISPLAY or renew/use the expired input-stage clock.
    seconds = Float(allowance || '30')
    raise 'Invalid cleanup allowance' unless seconds.finite? && seconds > 0
    @deadline = now + [seconds, 30.0].min
    confirmed = clean(state)
    receipt(File.join(@dir, 'cleanup.json'), { utc: Time.now.utc.iso8601(6), allowanceSeconds: [seconds, 30.0].min,
                                             inputPerformed: false, confirmed: confirmed, results: state['cleanupResults'] })
    exit(confirmed ? 0 : 1)
  end
  deadline = Float(ENV.fetch('LOCALSEND_GUI_DEADLINE_MONOTONIC'))
  raise 'Invalid GUI deadline' unless deadline.finite?
  @deadline = [deadline, now + 120.0].min
  if allowance
    seconds = Float(allowance)
    raise 'Invalid GUI allowance' unless seconds.finite? && seconds > 0
    @deadline = [@deadline, now + seconds].min
  end
  # A later helper call cannot renew the stage clock.
  @deadline = [@deadline, state['deadlineMonotonic']].min if state['deadlineMonotonic']
  display = ENV.fetch('DISPLAY')
  raise 'Private DISPLAY required' if display.empty?
  if action == 'start'
    raise 'GUI state already exists' unless state.empty?
    remaining
    state = { 'deadlineMonotonic' => @deadline, 'display' => display, 'startedUtc' => Time.now.utc.iso8601(6), 'processOwners' => @owners }
    state['wmPid'] = Process.spawn('openbox', '--sm-disable', out: File.join(@dir, 'openbox.stdout'),
                                   err: File.join(@dir, 'openbox.stderr'), pgroup: true)
    register(state['wmPid'], ['openbox', '--sm-disable'])
    receipt(state_path, state)
    state['viewerPid'] = Process.spawn('vncviewer', '-Shared', '-ViewOnly', '-RemoteResize=0', '-geometry', '1200x900+0+0',
                                       '127.0.0.1:5901', out: File.join(@dir, 'viewer.stdout'),
                                       err: File.join(@dir, 'viewer.stderr'), pgroup: true)
    register(state['viewerPid'], ['vncviewer', '127.0.0.1:5901'])
    receipt(state_path, state)
    window = nil
    loop do
      remaining
      raise 'Viewer exited before readiness' unless alive(state['viewerPid'])
      begin
        ids = bounded(['xdotool', 'search', '--onlyvisible', '--pid', state['viewerPid'].to_s], 'viewer-windows.txt').lines.map(&:strip)
        raise 'Ambiguous viewer windows' if ids.length > 1
        window = ids.first unless ids.empty?
      rescue RuntimeError => error
        raise unless error.message.start_with?('viewer-windows.txt failed: 1')
      end
      break if window
      sleep [0.1, remaining].min
    end
    geometry_text = bounded(['xdotool', 'getwindowgeometry', '--shell', window], 'viewer-geometry.txt')
    geometry = geometry_text.lines.map { |line| line.strip.split('=', 2) }.to_h
    x, y, width, height = %w[X Y WIDTH HEIGHT].map { |key| Integer(geometry.fetch(key), 10) }
    raise 'Viewer outside recording display' unless x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1280 && y + height <= 960
    bounded(['xwininfo', '-id', window], 'viewer-xwininfo.txt')
    root_info = bounded(['xwininfo', '-root'], 'display-xwininfo.txt')
    raise 'Unexpected private display dimensions' unless root_info.match?(/^\s*Width: 1280$/) && root_info.match?(/^\s*Height: 960$/)
    state['window'] = window
    state['geometry'] = { x: x, y: y, width: width, height: height }
    state['viewerReadyUtc'] = Time.now.utc.iso8601(6)
    state['viewerReadyMonotonic'] = now
    receipt(state_path, state)
    receipt(File.join(@dir, 'viewer.json'), state)
    puts JSON.generate(state)
  elsif action == 'record'
    raise 'Viewer state missing or dead' unless state['viewerPid'] && alive(state['viewerPid'])
    raise 'Recorder already exists' if state['recorderPid']
    raise 'Ten-second recording plus inspection does not fit' unless remaining >= 16
    bounded(['ffmpeg', '-version'], 'ffmpeg-version.txt')
    video = File.join(@dir, 'viewer-original.mkv')
    progress = File.join(@dir, 'record-progress.txt')
    exit_path = File.join(@dir, 'recorder-exit.txt')
    argv = ['ffmpeg', '-nostdin', '-y', '-f', 'x11grab', '-framerate', '10', '-video_size', '1280x960',
            '-i', display, '-t', '10', '-c:v', 'ffv1', '-progress', progress, video]
    # Wrapper persists actual FFmpeg status, even though a later invocation is
    # not its parent. Presence of a media file alone is never accepted.
    wrapper = 'exitfile=$1; shift; "$@"; result=$?; printf "%s\n" "$result" > "$exitfile.tmp"; mv "$exitfile.tmp" "$exitfile"; exit "$result"'
    state['recordStartedUtc'] = Time.now.utc.iso8601(6)
    state['recordStartedMonotonic'] = now
    state['recordCommand'] = argv
    state['recorderPid'] = Process.spawn('/bin/sh', '-c', wrapper, 'owned-recorder', exit_path, *argv,
                                         out: File.join(@dir, 'recorder.stdout'), err: File.join(@dir, 'recorder.stderr'), pgroup: true)
    register(state['recorderPid'], ['/bin/sh', '-c', wrapper, 'owned-recorder', exit_path, *argv])
    receipt(state_path, state)
    loop do
      remaining
      raise 'Recorder exited before first frame' if File.exist?(exit_path)
      raise 'Recorder died before first frame' unless alive(state['recorderPid'])
      progress_text = File.exist?(progress) ? File.read(progress) : ''
      frames = progress_text.scan(/^frame=(\d+)$/).flatten.map(&:to_i)
      break if frames.any? { |value| value > 0 } && File.exist?(video) && File.size(video) > 0
      sleep [0.05, remaining].min
    end
    state['recordReadyUtc'] = Time.now.utc.iso8601(6)
    state['recordReadyMonotonic'] = now
    receipt(state_path, state)
    receipt(File.join(@dir, 'recorder.json'), state)
    puts JSON.generate(state)
  elsif action == 'stop'
    raise 'Recorder missing' unless state['recorderPid']
    exit_path = File.join(@dir, 'recorder-exit.txt')
    until File.exist?(exit_path)
      remaining
      raise 'Recorder died without exit receipt' unless alive(state['recorderPid'])
      sleep [0.05, remaining].min
    end
    exit_status = Integer(File.read(exit_path).strip, 10)
    raise "FFmpeg recording failed: #{exit_status}" unless exit_status == 0
    video = File.join(@dir, 'viewer-original.mkv')
    probe = bounded(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_streams', '-show_format', '-show_frames',
                     '-of', 'json', video], 'recording-ffprobe.json', 10)
    parsed = JSON.parse(probe)
    stream = parsed.fetch('streams').first
    raise 'Wrong recording dimensions' unless stream.fetch('width') == 1280 && stream.fetch('height') == 960
    duration = Float(parsed.fetch('format').fetch('duration'))
    frames = parsed.fetch('frames')
    raise 'Incomplete continuous recording' unless duration >= 9.0 && duration <= 11.0 && frames.length >= 90
    times = frames.map { |frame| Float(frame.fetch('best_effort_timestamp_time')) }
    raise 'Nonmonotonic recording timestamps' unless times.all? { |time| time.finite? && time >= 0 } &&
      times.first <= 0.2 && times.last >= 8.9 && times.each_cons(2).all? { |a, b| b > a && b - a < 0.3 }
    bounded(['ffmpeg', '-nostdin', '-v', 'error', '-i', video, '-f', 'null', '-'], 'recording-decode.txt', 15)
    bounded(['ffmpeg', '-nostdin', '-y', '-v', 'error', '-i', video, '-vf', 'fps=1', '-frames:v', '10',
             File.join(@dir, 'decoded-%02d.png')], 'recording-decoded-frames.txt', 15)
    state['recordFinishedUtc'] = Time.now.utc.iso8601(6)
    state['recordFinishedMonotonic'] = now
    state['exitStatus'] = exit_status
    state['durationSeconds'] = duration
    state['frameCount'] = frames.length
    state['decoded'] = true
    # This receipt validates media integrity only. Parent must inspect these
    # original decoded pixels for Run visible and return to LocalSend.
    receipt(File.join(@dir, 'recording.json'), state)
    puts JSON.generate(state)
    raise 'Owned GUI shutdown unconfirmed' unless clean(state)
  else
    clean(state)
  end
rescue StandardError => error
  warn "GUI failed: #{error.message}"
  receipt(File.join(@dir, 'failure.json'), { error: error.message, utc: Time.now.utc.iso8601(6) }) if @dir
  clean(state) if @deadline && @dir
  exit 1
end
RUBY
