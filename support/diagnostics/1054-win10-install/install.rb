require 'json'
require 'time'
require 'timeout'
require_relative 'vnc'
out, private_dir, iso = ARGV
serial = File.join(out, 'guest-serial.txt')
frames = File.join(out, 'frames')
Dir.mkdir(frames)
qemu = ENV.fetch('QEMU', 'qemu-system-x86_64')
args = [qemu, '-machine', 'pc', '-accel', 'hvf', '-cpu', 'host', '-smp', '2', '-m', '4096',
  '-drive', "file=#{private_dir}/windows.qcow2,format=qcow2,if=ide,index=0",
  '-drive', "file=#{iso},media=cdrom,if=ide,index=2,readonly=on",
  '-drive', "file=#{private_dir}/seed.iso,media=cdrom,if=ide,index=3,readonly=on",
  '-boot', 'order=c,once=d', '-nic', 'user,model=e1000', '-vga', 'std',
  '-usb', '-device', 'usb-tablet', '-display', 'none', '-vnc', '127.0.0.1:1',
  '-serial', "file:#{serial}"]
# The private paths reveal no credentials; never copy the seed or guest disk.
File.write(File.join(out, 'qemu-command.json'), JSON.pretty_generate(args))
log = File.open(File.join(out, 'qemu-stderr.txt'), 'w')
guest = Process.spawn(*args, out: log, err: log)
def frame(path)
  Timeout.timeout(20) do
    client = GuestVNC.new
    begin; client.screenshot(path); ensure; client.close; end
  end
  png = path.sub(/\.bmp$/, '.png')
  raise 'PNG conversion failed' unless system('sips', '-s', 'format', 'png', path, '--out', png, out: File::NULL)
end
begin
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2700
  count = 0
  next_capture = 0
  ready = nil
  loop do
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise 'Windows installation/activation/window deadline exceeded (45 minutes)' if now > deadline
    raise 'QEMU exited during Windows preparation' if Process.waitpid(guest, Process::WNOHANG)
    records = File.exist?(serial) ? File.readlines(serial).map { |line|
      next unless line.start_with?('ISSUE1054 ')
      begin; JSON.parse(line.delete_prefix('ISSUE1054 ')); rescue JSON::ParserError; nil; end
    }.compact : []
    File.write(File.join(out, 'guest-records.json'), JSON.pretty_generate(records))
    failure = records.find { |record| record['stage'] == 'guest-blocked' }
    raise "Guest preparation blocked: #{failure.dig('data', 'message')}" if failure
    ready = records.find { |record| record['stage'] == 'app-window-ready' }
    if ready
      frame(File.join(frames, 'official-app-window.bmp'))
      break
    end
    if now >= next_capture
      begin
        frame(File.join(frames, format('setup-%03d.bmp', count)))
      rescue StandardError => error
        File.open(File.join(out, 'capture-errors.txt'), 'a') { |file| file.puts "#{Time.now.utc.iso8601} #{error.class}: #{error.message}" }
      end
      count += 1
      next_capture = now + 60
    end
    sleep 2
  end
  # Capture normal OS input response while preserving the original application.
  Timeout.timeout(20) do
    client = GuestVNC.new
    begin
      File.write(File.join(out, 'desktop-input.json'), JSON.pretty_generate(utc: Time.now.utc.iso8601, action: 'Windows+R; capture; Escape', route: 'ordinary VNC input'))
      client.key(0xffeb, true)
      client.tap('r'.ord)
      client.key(0xffeb, false)
      sleep 2
      client.screenshot(File.join(frames, 'run-dialog.bmp'))
      client.tap(0xff1b)
    ensure
      client.close
    end
  end
  raise 'PNG conversion failed' unless system('sips', '-s', 'format', 'png', File.join(frames, 'run-dialog.bmp'), '--out', File.join(frames, 'run-dialog.png'), out: File::NULL)
  File.write(File.join(out, 'gui-stage.json'), JSON.pretty_generate(stage: 'official-window-and-vnc-captured', record: ready,
    limitation: 'Inspect frames. Native window handle alone does not establish correct rendering, completed onboarding, or transfer.'))
  # A parent-owned same-job script may continue the actual-app pair while this VM
  # and its private installation are alive. No callback is provided by default.
  if ENV['AFTER_GUEST_READY_SCRIPT']
    raise 'Same-job continuation failed' unless system('bash', ENV.fetch('AFTER_GUEST_READY_SCRIPT'))
  end
ensure
  begin; Process.kill('KILL', guest); rescue Errno::ESRCH; end
  begin; Process.wait(guest); rescue Errno::ECHILD; end
  log.close
end
