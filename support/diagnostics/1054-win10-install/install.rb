require 'json'
require 'time'
require 'timeout'
require 'digest'
require_relative 'vnc'
out, private_dir, iso = ARGV
serial = File.join(out, 'guest-serial.txt')
frames = File.join(out, 'frames')
Dir.mkdir(frames)
qemu = ENV.fetch('QEMU', 'qemu-system-x86_64')
raise 'QEMU version differs from measured TCG control 11.1.0' unless File.read(File.join(ENV.fetch('CAPABILITY_DIR'), 'qemu-version.txt')).start_with?('QEMU emulator version 11.1.0')
acceleration = ENV.fetch('INSTALL_ACCELERATION', 'hvf')
raise 'Unsupported installation acceleration' unless %w[hvf tcg].include?(acceleration)
accelerator_args = acceleration == 'hvf' ? ['-accel', 'hvf', '-cpu', 'host'] : ['-accel', 'tcg,thread=multi', '-cpu', 'max']
args = [qemu, '-machine', 'pc', *accelerator_args, '-smp', '2', '-m', '4096',
  '-drive', "file=#{private_dir}/windows.qcow2,format=qcow2,if=ide,index=0",
  '-drive', "file=#{iso},media=cdrom,if=ide,index=2,readonly=on",
  '-drive', "file=#{private_dir}/seed.iso,media=cdrom,if=ide,index=3,readonly=on",
  '-boot', 'order=c,once=d', '-nic', 'user,model=e1000', '-vga', 'std',
  '-usb', '-device', 'usb-tablet', '-display', 'none', '-vnc', '127.0.0.1:1',
  '-serial', "file:#{serial}"]
# The private paths reveal no credentials; never copy the seed or guest disk.
File.write(File.join(out, 'qemu-command.json'), JSON.pretty_generate(args))
log = File.open(File.join(out, 'qemu-stderr.txt'), 'w')
# Reserve the complete finite guest budget and evidence/cleanup margin. A slow
# dependency or ISO preparation must not silently shorten the guest experiment.
preparation_start = Time.iso8601(File.readlines(File.join(ENV.fetch('CAPABILITY_DIR'), 'stages.tsv')).first.split("\t").first)
preparation_seconds = Time.now.utc - preparation_start
raise 'Preparation exceeded 14 minutes; insufficient reserved job time for 90-minute guest gate' if preparation_seconds > 840
launch_utc = Time.now.utc.iso8601
launch_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
guest = Process.spawn(*args, out: log, err: log)
def frame(path)
  Timeout.timeout(20) do
    client = GuestVNC.new
    begin; client.screenshot(path); ensure; client.close; end
  end
  png = path.sub(/\.bmp$/, '.png')
  converter = Process.spawn('sips', '-s', 'format', 'png', path, '--out', png, out: File::NULL)
  begin
    _, status = Timeout.timeout(20) { Process.waitpid2(converter) }
    raise 'PNG conversion failed' unless status.success?
  ensure
    begin; Process.kill('KILL', converter); rescue Errno::ESRCH; end
    begin; Process.wait(converter); rescue Errno::ECHILD; end
  end
end
def observed_text(path, private_dir)
  output = path.sub(/\.png$/, '.ocr.raw.json')
  error = path.sub(/\.png$/, '.ocr.stderr.txt')
  pid = Process.spawn(File.join(private_dir, 'setup-ocr'), path, out: output, err: error)
  begin
    _, status = Timeout.timeout(20) { Process.waitpid2(pid) }
    raise "Setup OCR failed; inspect #{File.basename(error)}" unless status.success?
    JSON.parse(File.read(output))
  ensure
    begin; Process.kill('KILL', pid); rescue Errno::ESRCH; end
    begin; Process.wait(pid); rescue Errno::ECHILD; end
  end
end
begin
  File.write(File.join(out, 'preparation-timing.json'), JSON.pretty_generate(launch_utc: launch_utc,
    guest_pid: guest, preparation_seconds: preparation_seconds, guest_budget_seconds: 5400,
    initial_boot_gate_seconds: 720, checkpoint_minutes: [45, 60, 75, 90],
    scope: 'Finite installation/activation/window preparation budget; not a transfer experiment.'))
  deadline = launch_monotonic + 5400
  boot_deadline = launch_monotonic + 720
  checkpoints = [45, 60, 75, 90]
  setup_observed = false
  count = 0
  next_capture = 0
  ready = nil
  recovery_attempted = false
  loop do
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise 'QEMU exited during Windows preparation' if Process.waitpid(guest, Process::WNOHANG)
    records = File.exist?(serial) ? File.readlines(serial).map { |line|
      next unless line.start_with?('ISSUE1054 ')
      begin; JSON.parse(line.delete_prefix('ISSUE1054 ')); rescue JSON::ParserError; nil; end
    }.compact : []
    File.write(File.join(out, 'guest-records.json'), JSON.pretty_generate(records))
    failure = records.find { |record| record['stage'] == 'guest-blocked' }
    raise "Guest preparation blocked: #{failure.dig('data', 'message')}" if failure
    if !checkpoints.empty? && now >= launch_monotonic + checkpoints.first * 60
      minute = checkpoints.shift
      checkpoint = {utc: Time.now.utc.iso8601, elapsed_seconds: now - launch_monotonic,
        minute: minute, guest_pid: guest, guest_stages: records.map { |record| record['stage'] },
        scope: 'Same running VM checkpoint; inspect original pixels, not a completed guest or product gate.'}
      begin
        path = File.join(frames, format('checkpoint-%03d.bmp', minute))
        frame(path)
        checkpoint[:frame] = File.basename(path)
        checkpoint[:sha256] = Digest::SHA256.file(path).hexdigest
        checkpoint[:capture_completed_utc] = Time.now.utc.iso8601
      rescue StandardError => error
        checkpoint[:capture_error] = "#{error.class}: #{error.message}"
      end
      File.open(File.join(out, 'timing-checkpoints.jsonl'), 'a') { |file| file.puts JSON.generate(checkpoint) }
    end
    raise 'Windows installation/activation/window deadline exceeded (90 minutes)' if now > deadline
    ready = records.find { |record| record['stage'] == 'app-window-ready' }
    if ready
      frame(File.join(frames, 'official-app-window.bmp'))
      break
    end
    if now >= next_capture
      recovery_visible = false
      begin
        path = File.join(frames, format('setup-%03d.bmp', count))
        File.open(File.join(out, 'frame-times.jsonl'), 'a') { |file| file.puts JSON.generate(utc: Time.now.utc.iso8601, frame: File.basename(path)) }
        frame(path)
        lines = observed_text(path.sub(/\.bmp$/, '.png'), private_dir)
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
      next_capture = now + (setup_observed ? 60 : 15)
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
        action = Process.spawn({'ISSUE1054_RECOVERY_DEADLINE' => deadline.to_s}, '/usr/bin/ruby', File.join(__dir__, 'recovery-action.rb'),
          File.join(out, 'oobe-recovery'), File.join(private_dir, 'recovery-ocr'), pgroup: true)
        begin
          action_budget = [160, deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)].min
          raise 'Preparation deadline reached while starting OOBE recovery action' unless action_budget > 0
          _, status = Timeout.timeout(action_budget) { Process.waitpid2(action) }
          raise 'Observed OOBE recovery action failed; inspect original before/after and action.json' unless status.success?
        ensure
          begin; Process.kill('KILL', -action); rescue Errno::ESRCH; end
          begin; Process.wait(action); rescue Errno::ECHILD; end
        end
      end
    end
    identity_observed = records.any? { |record| record['stage'] == 'windows-identity' }
    if !setup_observed && !identity_observed && Process.clock_gettime(Process::CLOCK_MONOTONIC) > boot_deadline
      raise 'No observed Windows installation UI or guest identity within 12 minutes; stop before another blind installation wait'
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
