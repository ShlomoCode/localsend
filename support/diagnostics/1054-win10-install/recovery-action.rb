require 'json'
require 'time'
require 'timeout'
require 'digest'
require_relative 'vnc'

out, ocr = ARGV
deadline = Float(ENV.fetch('ISSUE1054_RECOVERY_DEADLINE'))
Dir.mkdir(out)
record = {utc: Time.now.utc.iso8601, action: 'One ordinary Next click on observed OOBE recovery screen', input: []}
client = nil
def bounded_child(args, out, name)
  # Inherit the action's process group so its parent can terminate the complete
  # helper tree at the outer deadline even if Ruby cannot run this ensure.
  pid = Process.spawn(*args, out: File.join(out, "#{name}.stdout"), err: File.join(out, "#{name}.stderr"))
  begin
    _, status = Timeout.timeout(20) { Process.waitpid2(pid) }
    raise "#{name} failed" unless status.success?
  ensure
    begin; Process.kill('KILL', pid); rescue Errno::ESRCH; end
    begin; Process.wait(pid); rescue Errno::ECHILD; end
  end
end
def capture(client, out, name)
  path = File.join(out, "#{name}.bmp")
  Timeout.timeout(20) { client.screenshot(path) }
  captured = Time.now.utc
  bounded_child(['sips', '-s', 'format', 'png', path, '--out', path.sub(/\.bmp$/, '.png')], out, "#{name}-convert")
  [path, captured]
end
begin
  Timeout.timeout(20) { client = GuestVNC.new }
  path, captured = capture(client, out, 'before')
  record[:before_utc] = captured.iso8601(6)
  record[:before_sha256] = Digest::SHA256.file(path).hexdigest
  bounded_child([ocr, path.sub(/\.bmp$/, '.png')], out, 'before-ocr')
  data = JSON.parse(File.read(File.join(out, 'before-ocr.stdout')))
  width, height = File.binread(path, 54).byteslice(18, 8).unpack('l<2')
  raise 'OCR/frame geometry mismatch' unless data['origin'] == 'top-left' && data['width'] == width && data['height'] == height.abs
  lines = data.fetch('lines').select { |line| Float(line.fetch('confidence')) >= 0.5 }
  raise 'Exact OOBE recovery header is not uniquely visible' unless lines.count { |line| line['text'] == 'Why did my PC restart?' } == 1
  # Whole-line matching excludes the instructions' other occurrences of Next.
  buttons = lines.select { |line| line['text'] == 'Next' }
  raise 'Next button whole line is not uniquely visible' unless buttons.length == 1
  box = buttons.first.fetch('bounds')
  x, y, w, h = %w[x y width height].map { |key| Float(box.fetch(key)) }
  raise 'Invalid Next bounds' unless [x, y, w, h].all?(&:finite?) && w > 0 && h > 0 && x >= 0 && y >= 0 && x + w <= width && y + h <= height.abs
  # Verify the current RFB handshake geometry before mutating the guest.
  fresh = nil
  Timeout.timeout(20) { fresh = GuestVNC.new }
  client.close
  client = fresh
  raise 'Guest geometry changed since capture' unless [client.instance_variable_get(:@width), client.instance_variable_get(:@height)] == [width, height.abs]
  raise 'Observed recovery frame is older than five seconds; no input' if Time.now.utc - captured > 5
  raise 'Preparation deadline reached; no input' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  point = [(x + w / 2).floor, (y + h / 2).floor]
  record[:header] = 'Why did my PC restart?'
  record[:button] = buttons.first
  record[:input] << {utc: Time.now.utc.iso8601(6), kind: 'click', x: point[0], y: point[1]}
  Timeout.timeout(5) { client.click(*point) }
  record[:status] = 'ok'
rescue StandardError => error
  record[:status] = 'error'
  record[:error] = "#{error.class}: #{error.message}"
ensure
  if client
    begin
      sleep 0.8
      capture(client, out, 'after')
    rescue StandardError => error
      record[:after_error] = "#{error.class}: #{error.message}"
      record[:status] = 'error'
    ensure
      client.close rescue nil
    end
  end
  record[:finished_utc] = Time.now.utc.iso8601(6)
  File.write(File.join(out, 'action.json'), JSON.pretty_generate(record))
end
exit(record[:status] == 'ok' ? 0 : 1)
