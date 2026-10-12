require 'json'
require 'time'
require 'timeout'
require 'digest'
require 'ipaddr'
require 'rbconfig'
require_relative 'vnc'
require_relative 'qmp'
out, private_dir, iso = ARGV
serial = File.join(out, 'guest-serial.txt')
frames = File.join(out, 'frames')
Dir.mkdir(frames)
qemu = ENV.fetch('QEMU', 'qemu-system-x86_64')
linux = ENV['ISSUE1054_HOST'] == 'linux'
expected_version = linux ? '8.2.2' : '11.1.0'
raise 'QEMU version differs from selected control' unless File.read(File.join(ENV.fetch('CAPABILITY_DIR'), 'qemu-version.txt')).start_with?("QEMU emulator version #{expected_version}")
acceleration = ENV.fetch('INSTALL_ACCELERATION', 'hvf')
raise 'Unsupported installation acceleration' unless linux ? acceleration == 'kvm' : %w[hvf tcg].include?(acceleration)
accelerator_args = if linux
  ['-accel', 'kvm', '-cpu', 'host']
elsif acceleration == 'hvf'
  ['-accel', 'hvf', '-cpu', 'host']
else
  ['-accel', 'tcg,thread=multi', '-cpu', 'max']
end
qmp_endpoint = linux ? ['127.0.0.1', 4444] : File.join(private_dir, 'qmp.sock')
qmp_argument = linux ? 'tcp:127.0.0.1:4444,server=on,wait=off' : "unix:#{qmp_endpoint},server=on,wait=off"
args = [qemu, '-machine', 'pc', *accelerator_args, '-smp', '2', '-m', '4096',
  '-drive', "file=#{private_dir}/windows.qcow2,format=qcow2,if=ide,index=0",
  '-drive', "file=#{iso},media=cdrom,if=ide,index=2,readonly=on",
  '-drive', "file=#{private_dir}/seed.iso,media=cdrom,if=ide,index=3,readonly=on",
  '-boot', 'order=c,once=d', '-netdev', 'user,id=net0',
  '-device', 'e1000,netdev=net0,id=nic0,mac=52:54:00:12:34:56',
  '-qmp', qmp_argument, '-S', '-vga', 'std',
  '-usb', '-device', 'usb-tablet', '-display', 'none', '-vnc', '127.0.0.1:1',
  '-serial', "file:#{serial}"]
# The private paths reveal no credentials; never copy the seed or guest disk.
File.write(File.join(out, 'qemu-command.json'), JSON.pretty_generate(args))
log = File.open(File.join(out, 'qemu-stderr.txt'), 'w')
# Reserve the complete finite guest budget and evidence/cleanup margin. A slow
# dependency or ISO preparation must not silently shorten the guest experiment.
preparation_start = Time.iso8601(File.readlines(File.join(ENV.fetch('CAPABILITY_DIR'), 'stages.tsv')).first.split("\t").first)
preparation_seconds = Time.now.utc - preparation_start
raise "Preparation exceeded 14 minutes; insufficient reserved job time for #{linux ? 40 : 90}-minute guest gate" if preparation_seconds > 840
launch_utc = Time.now.utc.iso8601
launch_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
guest_seconds = linux ? 2400 : 5400
deadline = launch_monotonic + guest_seconds
guest = nil
qmp = nil
def budget(deadline, maximum)
  remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
  raise 'Windows preparation deadline reached before bounded operation' unless remaining > 0
  [maximum, remaining].min
end
def stop_child(pid, group = false)
  begin; Process.kill('KILL', group ? -pid : pid); rescue Errno::ESRCH; end
  begin; Timeout.timeout(5) { Process.wait(pid) }; rescue Errno::ECHILD; end
end
def frame(path, deadline)
  capture_deadline = [deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20].min
  Timeout.timeout(budget(capture_deadline, 20)) do
    client = GuestVNC.new
    begin; client.screenshot(path); ensure; client.close; end
  end
  convert_frame(path, capture_deadline)
end
def convert_frame(path, deadline)
  png = path.sub(/\.bmp$/, '.png')
  allowance = budget(deadline, 20)
  converter_args = ENV['ISSUE1054_HOST'] == 'linux' ? ['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', path, '-frames:v', '1', png] : ['sips', '-s', 'format', 'png', path, '--out', png]
  converter = Process.spawn(*converter_args, out: File::NULL)
  begin
    _, status = Timeout.timeout(allowance) { Process.waitpid2(converter) }
    raise 'PNG conversion failed' unless status.success?
    budget(deadline, 20)
  ensure
    stop_child(converter)
  end
end
def observed_text(path, private_dir, deadline)
  output = path.sub(/\.png$/, '.ocr.raw.json')
  error = path.sub(/\.png$/, '.ocr.stderr.txt')
  allowance = budget(deadline, 20)
  ocr_args = if ENV['ISSUE1054_HOST'] == 'linux'
    [RbConfig.ruby, File.expand_path('../1054-linux-kvm/ocr.rb', __dir__), path]
  else
    [File.join(private_dir, 'setup-ocr'), path]
  end
  ocr_environment = ENV['ISSUE1054_HOST'] == 'linux' ? {'OCR_STAGE_SECONDS' => allowance.to_s, 'LOCALSEND_STAGE_DEADLINE_MONOTONIC' => deadline.to_s} : {}
  pid = Process.spawn(ocr_environment, *ocr_args, out: output, err: error, pgroup: true)
  begin
    _, status = Timeout.timeout(allowance) { Process.waitpid2(pid) }
    raise "Setup OCR failed; inspect #{File.basename(error)}" unless status.success?
    budget(deadline, 20)
    parsed = JSON.parse(File.read(output))
    ENV['ISSUE1054_HOST'] == 'linux' ? parsed.fetch('lines').select { |line| line.fetch('confidence') >= 0.5 }.map { |line| line.fetch('text') } : parsed
  ensure
    stop_child(pid, true)
  end
end
def guest_records(serial)
  return [] unless File.exist?(serial)
  File.readlines(serial).map do |line|
    next unless line.start_with?('ISSUE1054 ')
    begin; JSON.parse(line.delete_prefix('ISSUE1054 ')); rescue JSON::ParserError; nil; end
  end.compact
end
def qualified_network_wait(records)
  stages = %w[bootstrap-entry windows-identity probe-session waiting-for-network]
  markers = stages.map { |stage| records.each_index.select { |index| records[index]['stage'] == stage } }
  return nil if markers.last.empty?
  raise 'Duplicate or missing first-logon marker; no reconnect' unless markers.all? { |indices| indices.length == 1 }
  positions = markers.map(&:first)
  raise 'Out-of-order first-logon marker; no reconnect' unless positions == positions.sort && positions.uniq.length == 4
  entry, identity, session, waiting = positions.map { |index| records[index].fetch('data') }
  elapsed = waiting['handshakeElapsedMs']
  raise 'Invalid bounded bootstrap entry' unless entry['handshakeLimitSeconds'] == 120 && elapsed.is_a?(Numeric) && elapsed >= 0 && elapsed < 120_000
  raise 'Unqualified Windows identity' unless identity['caption'].to_s.include?('Windows 10 Enterprise Evaluation') && identity['build'].to_s == '19045' && identity['version'].to_s.match?(/^10\.0\.19045(?:\.|$)/)
  raise 'Unqualified Probe first-logon session' unless session['account'].to_s.casecmp('Probe').zero? && session['identity'].to_s.casecmp('Sender\\Probe').zero? && session['interactiveUser'].to_s.casecmp('Sender\\Probe').zero? && session['sid'].to_s.start_with?('S-1-5-21-') && session['sessionId'].is_a?(Integer) && session['sessionId'] > 0 && session['userInteractive'] == true
  adapter = waiting.fetch('adapter')
  raise 'Unexpected disconnected Ethernet identity' unless waiting['expectedMac'] == '52:54:00:12:34:56' && adapter['mac'] == waiting['expectedMac'] && adapter['description'].to_s.match?(/Intel.*PRO\/1000/i) && adapter['interfaceIndex'].is_a?(Integer) && adapter['interfaceIndex'] > 0 && adapter['netEnabled'] == true && adapter['connectionStatus'] == 7 && adapter['ipv4'].is_a?(Array) && adapter['defaultRoutes'].is_a?(Array)
  waiting
end
def usable_ipv4(address)
  ip = IPAddr.new(address.to_s)
  ip.ipv4? && !%w[0.0.0.0/8 127.0.0.0/8 169.254.0.0/16 224.0.0.0/3].any? { |range| IPAddr.new(range).include?(ip) }
rescue IPAddr::InvalidAddressError
  false
end
def qualified_network_ready(records, waiting)
  matches = records.each_index.select { |index| records[index]['stage'] == 'network-ready' }
  raise 'Missing or duplicate restored-network marker' unless matches.length == 1
  position = matches.first
  raise 'Restored-network marker precedes first-logon wait' unless position > records.index { |record| record['stage'] == 'waiting-for-network' }
  network = records[position].fetch('data')
  adapter = network.fetch('adapter')
  addresses = adapter['ipv4']
  routes = adapter['defaultRoutes']
  raise 'Unqualified restored Ethernet identity' unless network['expectedMac'] == waiting['expectedMac'] && adapter['mac'] == waiting['expectedMac'] && adapter['interfaceIndex'] == waiting.dig('adapter', 'interfaceIndex') && adapter['description'].to_s.match?(/Intel.*PRO\/1000/i) && adapter['netEnabled'] == true && adapter['connectionStatus'] == 2
  raise 'No usable address/route on restored interface' unless addresses.is_a?(Array) && addresses.any? { |address| address['addressState'] == 4 && usable_ipv4(address['address']) } && routes.is_a?(Array) && routes.any? { |route| route['interfaceIndex'] == adapter['interfaceIndex'] && route['destination'] == '0.0.0.0/0' && usable_ipv4(route['nextHop']) }
  network
end
begin
  # Cleanup covers every operation after spawn, including the paused QMP gate.
  if linux
    %w[INT TERM].each { |signal| Signal.trap(signal) { raise Interrupt, "Received #{signal}; cleaning owned Windows guest" } }
  end
  if linux
    guest = Process.spawn('/bin/bash', ENV.fetch('ISSUE1054_LINUX_LAUNCHER'), 'windows', out: log, err: log, pgroup: true)
  else
    guest = Process.spawn(*args, out: log, err: log)
  end
  File.write(File.join(out, 'preparation-timing.json'), JSON.pretty_generate(launch_utc: launch_utc,
    guest_pid: guest, preparation_seconds: preparation_seconds, guest_budget_seconds: guest_seconds,
    initial_boot_gate_seconds: 720, checkpoint_minutes: linux ? [10, 20, 30, 40] : [45, 60, 75, 90],
    scope: 'Finite installation/activation/window preparation budget; not a transfer experiment.'))
  qmp = GuestQMP.new(qmp_endpoint, File.join(out, 'qmp-transitions.jsonl'),
    [deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20].min)
  qmp.command('set_link', {'name' => 'nic0', 'up' => false})
  qmp.command('cont')
  qmp.close
  qmp = nil
  boot_deadline = launch_monotonic + 720
  checkpoints = linux ? [10, 20, 30, 40] : [45, 60, 75, 90]
  setup_observed = false
  count = 0
  next_capture = 0
  ready = nil
  recovery_attempted = false
  network_restored = false
  network_wait = nil
  handshake_deadline = nil
  loop do
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise 'QEMU exited during Windows preparation' if Process.waitpid(guest, Process::WNOHANG)
    records = guest_records(serial)
    File.write(File.join(out, 'guest-records.json'), JSON.pretty_generate(records))
    failure = records.find { |record| record['stage'] == 'guest-blocked' }
    raise "Guest preparation blocked: #{failure.dig('data', 'message') || failure.dig('data', 'failureReason')}" if failure
    entry = records.find { |record| record['stage'] == 'bootstrap-entry' }
    if entry && !handshake_deadline
      elapsed = entry.dig('data', 'handshakeElapsedMs')
      raise 'Invalid bootstrap elapsed time' unless elapsed.is_a?(Numeric) && elapsed >= 0 && elapsed < 120_000
      handshake_deadline = [deadline, now + (120_000 - elapsed) / 1000.0].min
    end
    if !network_restored && (waiting = qualified_network_wait(records))
      reconnect_deadline = [deadline, handshake_deadline, now + (120_000 - waiting.fetch('handshakeElapsedMs')) / 1000.0, now + 20].min
      frame(File.join(frames, 'first-logon-preparation.bmp'), reconnect_deadline)
      before_serial = File.stat(serial)
      serial_text = File.read(serial)
      after_serial = File.stat(serial)
      raise 'Serial changed during reconnect qualification; no input' unless before_serial.size == after_serial.size && before_serial.mtime == after_serial.mtime && serial_text.end_with?("\n")
      records = serial_text.lines.map do |line|
        next unless line.start_with?('ISSUE1054 ')
        begin; JSON.parse(line.delete_prefix('ISSUE1054 ')); rescue JSON::ParserError; nil; end
      end.compact
      raise 'Guest handshake failed before reconnect' if records.any? { |record| record['stage'] == 'guest-blocked' }
      raise 'First-logon markers changed before reconnect' unless qualified_network_wait(records) == waiting
      progress = records.reverse.find { |record| record['stage'] == 'network-wait-progress' }
      raise 'No latest same-interface network-wait progress' unless progress && progress == records.last && progress.dig('data', 'expectedMac') == waiting['expectedMac'] && progress.dig('data', 'interfaceIndex') == waiting.dig('adapter', 'interfaceIndex') && %w[before after].include?(progress.dig('data', 'queryBoundary'))
      raise 'Last serial line is not the qualified progress marker' unless serial_text.lines.last.start_with?('ISSUE1054 ') && JSON.parse(serial_text.lines.last.delete_prefix('ISSUE1054 ')) == progress
      elapsed = progress.dig('data', 'handshakeElapsedMs')
      raise 'Guest network handshake reserve exhausted' unless elapsed.is_a?(Numeric) && elapsed >= waiting['handshakeElapsedMs'] && elapsed < 110_000
      # The last complete marker's host file age includes time spent in a guest
      # query after a "before" marker. Keep another ten seconds for serial write
      # and transport rather than renewing an old guest allowance on receipt.
      marker_age = Time.now.utc - after_serial.mtime
      raise 'Invalid serial modification time; no reconnect' unless marker_age >= 0
      remaining_marker = (110_000 - elapsed) / 1000.0 - marker_age
      raise 'Stale guest network-wait marker; no reconnect' unless remaining_marker > 0
      reconnect_deadline = [reconnect_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + remaining_marker].min
      qmp = GuestQMP.new(qmp_endpoint, File.join(out, 'qmp-transitions.jsonl'), reconnect_deadline)
      qmp.command('set_link', {'name' => 'nic0', 'up' => true})
      qmp.close
      qmp = nil
      network_restored = true
      network_wait = waiting
      File.write(File.join(out, 'network-reconnect.json'), JSON.pretty_generate(utc: Time.now.utc.iso8601,
        guest_pid: guest, waiting: waiting, progress: progress['data'], marker_age_seconds: marker_age,
        serial_modified_utc: after_serial.mtime.utc.iso8601(6), serial_bytes: after_serial.size,
        scope: 'First-logon preparation handshake; desktop/app/input remain later gates.'))
    end
    if !checkpoints.empty? && now >= launch_monotonic + checkpoints.first * 60
      minute = checkpoints.shift
      checkpoint = {utc: Time.now.utc.iso8601, elapsed_seconds: now - launch_monotonic,
        minute: minute, guest_pid: guest, guest_stages: records.map { |record| record['stage'] },
        scope: 'Same running VM checkpoint; inspect original pixels, not a completed guest or product gate.'}
      begin
        path = File.join(frames, format('checkpoint-%03d.bmp', minute))
        frame(path, deadline)
        checkpoint[:frame] = File.basename(path)
        checkpoint[:sha256] = Digest::SHA256.file(path).hexdigest
        checkpoint[:capture_completed_utc] = Time.now.utc.iso8601
      rescue StandardError => error
        checkpoint[:capture_error] = "#{error.class}: #{error.message}"
      end
      File.open(File.join(out, 'timing-checkpoints.jsonl'), 'a') { |file| file.puts JSON.generate(checkpoint) }
    end
    raise "Windows installation/activation/window deadline exceeded (#{guest_seconds / 60} minutes)" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    ready = records.find { |record| record['stage'] == 'app-window-ready' }
    if ready
      raise 'App readiness preceded network restoration' unless network_restored && network_wait
      qualified_network_ready(records, network_wait)
      frame(File.join(frames, 'official-app-window.bmp'), deadline)
      break
    end
    if now >= next_capture
      recovery_visible = false
      begin
        path = File.join(frames, format('setup-%03d.bmp', count))
        File.open(File.join(out, 'frame-times.jsonl'), 'a') { |file| file.puts JSON.generate(utc: Time.now.utc.iso8601, frame: File.basename(path)) }
        frame(path, deadline)
        lines = observed_text(path.sub(/\.bmp$/, '.png'), private_dir, deadline)
        File.write(path.sub(/\.bmp$/, '.ocr.json'), JSON.pretty_generate(lines))
        recovery_visible = lines.include?('Why did my PC restart?')
        if !setup_observed && lines.any? { |line| line.match?(/Windows Setup|Installing Windows|Getting files ready|Copying Windows files|Getting ready|Just a moment/i) }
          setup_observed = true
          File.write(File.join(out, 'boot-progress.json'), JSON.pretty_generate(utc: Time.now.utc.iso8601,
            acceleration: acceleration, frame: File.basename(path), lines: lines,
            scope: 'Observed installation UI only; not proof of completed OS or app preparation.'))
        end
      rescue StandardError => error
        File.open(File.join(out, 'capture-errors.txt'), 'a') { |file| file.puts "#{Time.now.utc.iso8601} #{error.class}: #{error.message}" }
      end
      count += 1
      next_capture = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (setup_observed ? 60 : 15)
      if recovery_visible && !recovery_attempted
        recovery_attempted = true
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining < 160
          File.write(File.join(out, 'oobe-recovery-refused.json'), JSON.pretty_generate(utc: Time.now.utc.iso8601,
            remaining_seconds: remaining, reason: 'Less than bounded 160-second action budget remains; no input sent.'))
          raise 'Insufficient remaining preparation budget for observed OOBE recovery action; no input'
        end
        # Only one ordinary recovery action; the helper independently requires
        # this exact header and a unique Next whole line in fresh original pixels.
        recovery_ocr = linux ? File.expand_path('../1054-linux-kvm/ocr.rb', __dir__) : File.join(private_dir, 'recovery-ocr')
        action = Process.spawn({'ISSUE1054_RECOVERY_DEADLINE' => deadline.to_s}, RbConfig.ruby, File.join(__dir__, 'recovery-action.rb'),
          File.join(out, 'oobe-recovery'), recovery_ocr, pgroup: true)
        begin
          action_budget = [160, deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)].min
          raise 'Preparation deadline reached while starting OOBE recovery action' unless action_budget > 0
          _, status = Timeout.timeout(action_budget) { Process.waitpid2(action) }
          raise 'Observed OOBE recovery action failed; inspect original before/after and action.json' unless status.success?
        ensure
          stop_child(action, true)
        end
      end
    end
    identity_observed = records.any? { |record| record['stage'] == 'windows-identity' }
    if !setup_observed && !identity_observed && Process.clock_gettime(Process::CLOCK_MONOTONIC) > boot_deadline
      raise 'No observed Windows installation UI or guest identity within 12 minutes; stop before another blind installation wait'
    end
    sleep budget(deadline, 2)
  end
  gui_script = linux ? File.expand_path('../1054-linux-kvm/gui.sh', __dir__) : nil
  gui_deadline = linux ? [deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120].min : deadline
  if linux
    raise 'Insufficient remaining guest budget for two-minute GUI check' unless deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC) >= 120
    ENV['LOCALSEND_GUI_DEADLINE_MONOTONIC'] = gui_deadline.to_s
    %w[start record].each do |operation|
      helper = Process.spawn('/bin/bash', gui_script, operation, out, budget(gui_deadline, 120).to_s, pgroup: true)
      begin
        _, status = Timeout.timeout(budget(gui_deadline, 120)) { Process.waitpid2(helper) }
        raise "Linux GUI #{operation} gate failed" unless status.success?
      ensure
        stop_child(helper, true)
      end
    end
  end
  # Capture normal OS input response while preserving the original application.
  input_deadline = [gui_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20].min
  Timeout.timeout(budget(input_deadline, 20)) do
    client = GuestVNC.new
    begin
      File.write(File.join(out, 'desktop-input.json'), JSON.pretty_generate(utc: Time.now.utc.iso8601, action: 'Windows+R; capture; Escape', route: 'ordinary VNC input'))
      client.key(0xffeb, true)
      client.tap('r'.ord)
      client.key(0xffeb, false)
      sleep budget(input_deadline, 2)
      client.screenshot(File.join(frames, 'run-dialog.bmp'))
      client.tap(0xff1b)
    ensure
      client.close
    end
  end
  convert_frame(File.join(frames, 'run-dialog.bmp'), input_deadline)
  if linux
    frame(File.join(frames, 'app-after-run.bmp'), gui_deadline)
    run_lines = observed_text(File.join(frames, 'run-dialog.png'), private_dir, gui_deadline)
    app_lines = observed_text(File.join(frames, 'app-after-run.png'), private_dir, gui_deadline)
    raise 'Actual Run dialog was not observed' unless run_lines.any? { |line| line == 'Run' } && run_lines.any? { |line| line.match?(/Open:/) }
    raise 'Actual LocalSend pixels missing after Escape' unless app_lines.any? { |line| line.include?('LocalSend') }
    helper = Process.spawn('/bin/bash', gui_script, 'stop', out, budget(gui_deadline, 120).to_s, pgroup: true)
    begin
      _, status = Timeout.timeout(budget(gui_deadline, 120)) { Process.waitpid2(helper) }
      raise 'Linux GUI recording validation failed' unless status.success?
    ensure
      stop_child(helper, true)
    end
  end
  File.write(File.join(out, 'gui-stage.json'), JSON.pretty_generate(stage: 'official-window-and-vnc-captured', record: ready,
    limitation: 'Inspect frames. Native window handle alone does not establish correct rendering, completed onboarding, or transfer.'))
  # A parent-owned same-job script may continue the actual-app pair while this VM
  # and its private installation are alive. No callback is provided by default.
  if ENV['AFTER_GUEST_READY_SCRIPT']
    raise 'Same-job continuation failed' unless system('bash', ENV.fetch('AFTER_GUEST_READY_SCRIPT'))
  end
rescue StandardError => error
  File.write(File.join(out, 'preparation-failure.json'), JSON.pretty_generate(utc: Time.now.utc.iso8601,
    guest_pid: guest, elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - launch_monotonic,
    error: error.class.to_s, message: error.message))
  if guest
    begin
      # Passive evidence: 20s capture plus at most 5s converter reap and 5s guest
      # reap use the existing cleanup reserve. No input occurs after the deadline.
      frame(File.join(frames, 'preparation-final.bmp'), Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20)
    rescue StandardError => capture_error
      File.write(File.join(out, 'final-capture-error.txt'), "#{capture_error.class}: #{capture_error.message}\n")
    end
  end
  raise
ensure
  begin
    qmp.close if qmp
  rescue IOError, SystemCallError => close_error
    File.write(File.join(out, 'qmp-close-error.txt'), "#{close_error.class}: #{close_error.message}\n")
  ensure
    if guest
      begin
        if linux
          cleanup = Process.spawn('/bin/bash', File.expand_path('../1054-linux-kvm/cleanup.sh', __dir__), '--install-only', pgroup: true)
          begin
            _, status = Timeout.timeout(30) { Process.waitpid2(cleanup) }
            raise 'Guarded privileged Windows cleanup failed' unless status.success?
          ensure
            stop_child(cleanup, true)
          end
          begin; Timeout.timeout(5) { Process.wait(guest) }; rescue Errno::ECHILD; end
        else
          stop_child(guest)
        end
        File.write(File.join(out, 'guest-cleanup.json'), JSON.pretty_generate(utc: Time.now.utc.iso8601, guest_pid: guest, kill_and_wait: 'completed'))
      rescue StandardError => cleanup_error
        File.write(File.join(out, 'guest-cleanup.json'), JSON.pretty_generate(utc: Time.now.utc.iso8601, guest_pid: guest, error: cleanup_error.class.to_s))
      end
    end
    log.close
  end
end
