require 'json'
require 'time'
require 'timeout'
require 'digest'
require_relative '../1054-win10-install/qmp'
require_relative '../1054-win10-install/vnc'

out, private_dir = ARGV
host = File.dirname(File.expand_path(__FILE__))
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
deadline = started + 15 # Reserve ten seconds of the 25-second gate for cleanup.
guest = nil
qmp = nil
def allowance(deadline)
  value = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
  raise 'Firmware aggregate deadline exceeded' unless value > 0
  value
end
def capture(path, deadline)
  Timeout.timeout(allowance(deadline)) do
    client = GuestVNC.new
    begin; client.screenshot(path); ensure; client.close; end
  end
  png = path.sub(/\.bmp$/, '.png')
  child = Process.spawn('/usr/bin/ffmpeg', '-nostdin', '-y', '-i', path, '-frames:v', '1', png,
                        out: File::NULL, err: path.sub(/\.bmp$/, '.conversion.txt'), pgroup: true)
  begin
    _, status = Timeout.timeout(allowance(deadline)) { Process.waitpid2(child) }
    raise 'Firmware frame conversion failed' unless status.success?
  ensure
    begin; Process.kill('KILL', -child); rescue Errno::ESRCH; end
    begin; Timeout.timeout(1) { Process.wait(child) }; rescue Errno::ECHILD; end
  end
  bytes = File.binread(path)
  width, height = bytes.byteslice(18, 8).unpack('V2')
  raise 'Invalid firmware frame dimensions' unless width > 0 && height > 0 && width * height <= 16_777_216
  {utc: Time.now.utc.iso8601, width: width, height: height,
   bmp_sha256: Digest::SHA256.file(path).hexdigest, png_sha256: Digest::SHA256.file(png).hexdigest}
end
begin
  [4444, 5901].each do |port|
    listener = nil
    begin
      listener = Timeout.timeout(allowance(deadline)) { TCPSocket.new('127.0.0.1', port) }
      raise "Unowned listener already occupies #{port}"
    rescue Errno::ECONNREFUSED
    ensure
      listener.close if listener
    end
  end
  log = File.open(File.join(out, 'qemu-stderr.txt'), 'w')
  guest = Process.spawn('/bin/bash', File.join(host, 'launch-qemu.sh'), 'firmware', out: log, err: log, pgroup: true)
  File.write(File.join(out, 'supervisor.json'), JSON.pretty_generate(pid: guest, utc: Time.now.utc.iso8601, maximum_seconds: 25))
  qmp = GuestQMP.new(['127.0.0.1', 4444], File.join(out, 'qmp.jsonl'), deadline)
  qmp.command('cont')
  sleep [3, allowance(deadline)].min
  before = capture(File.join(out, 'before-escape.bmp'), deadline)
  input = Time.now.utc.iso8601
  Timeout.timeout(allowance(deadline)) do
    client = GuestVNC.new
    begin; client.tap(0xff1b); ensure; client.close; end
  end
  sleep [1, allowance(deadline)].min
  after = capture(File.join(out, 'after-escape.bmp'), deadline)
  raise 'Firmware framebuffer dimensions changed' unless before.values_at(:width, :height) == after.values_at(:width, :height)
  File.write(File.join(out, 'frame-results.json'), JSON.pretty_generate(before: before, escape_utc: input, after: after,
    pixels_changed: before[:bmp_sha256] != after[:bmp_sha256], scope: 'firmware RFB input/capture admission; no Windows or application claim'))
ensure
  qmp.close if qmp
  if guest
    cleanup = Process.spawn('/bin/bash', File.join(host, 'cleanup.sh'), '--firmware-only', pgroup: true)
    begin
      _, status = Timeout.timeout([25 - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started), 8].min.clamp(0.1, 8)) { Process.waitpid2(cleanup) }
      raise 'Firmware privileged cleanup failed' unless status.success?
    ensure
      begin; Process.kill('KILL', -cleanup); rescue Errno::ESRCH; end
      begin; Timeout.timeout(1) { Process.wait(cleanup) }; rescue Errno::ECHILD; end
    end
    Timeout.timeout(1) { Process.wait(guest) } rescue Errno::ECHILD
    # Both loopback listeners must have disappeared before the Windows launch.
    [4444, 5901].each do |port|
      socket = nil
      begin
        socket = Timeout.timeout(1) { TCPSocket.new('127.0.0.1', port) }
        raise "Firmware listener remains on #{port}"
      rescue Errno::ECONNREFUSED
      ensure
        socket.close if socket
      end
    end
  end
  log.close if log
end
raise 'Firmware gate including cleanup exceeded 25 seconds' if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 25
