#!/usr/bin/env ruby
require 'json'
%w[INT TERM].each { |signal| Signal.trap(signal) { raise "OCR interrupted by #{signal}" } }

# Read original pixels. No resizing, thresholding, cropping or synthetic frames.
def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def run_child(argv, stdout_path, stderr_path, deadline)
  raise 'OCR deadline exhausted' unless deadline > monotonic
  # Inherit the caller's owned helper group, so its outer timeout also stops
  # this child if OCR cannot finish its ensure during cancellation.
  pid = Process.spawn(*argv, out: stdout_path, err: stderr_path)
  status = nil
  until status
    result = Process.waitpid2(pid, Process::WNOHANG)
    status = result[1] if result
    break if status
    raise 'OCR child deadline exhausted' unless deadline > monotonic
    sleep [0.05, deadline - monotonic].min
  end
  raise 'OCR child completed after deadline' unless deadline > monotonic
  raise "OCR child failed: #{status.exitstatus}" unless status.success?
ensure
  if pid && !status
    cleanup_started = monotonic
    cleanup_deadline = cleanup_started + 5.0
    cleanup = { pid: pid, signal: 'KILL', reapState: 'unknown', reapAllowanceSeconds: 5.0 }
    begin
      Process.kill('KILL', pid)
      cleanup[:killRequested] = true
    rescue Errno::ESRCH
      cleanup[:killRequested] = false
    end
    begin
      loop do
        result = Process.waitpid2(pid, Process::WNOHANG)
        if result
          cleanup[:reapState] = 'reaped'
          cleanup[:exitStatus] = result[1].exitstatus
          cleanup[:termSignal] = result[1].termsig
          break
        end
        break unless cleanup_deadline > monotonic
        sleep [0.05, [cleanup_deadline - monotonic, 0.0].max].min
      end
    rescue Errno::ECHILD
      cleanup[:reapState] = 'unavailable-not-a-child'
    end
    cleanup[:elapsedSeconds] = monotonic - cleanup_started
    File.write(stdout_path + '.cleanup.json', JSON.pretty_generate(cleanup) + "\n")
    warn "OCR child reap state: #{cleanup[:reapState]}" unless cleanup[:reapState] == 'reaped'
  end
end

begin
  raise 'Usage: ocr.rb IMAGE [EXACT_PHRASE] (OCR_STAGE_SECONDS env bounds work)' unless (1..2).cover?(ARGV.length)
  image = File.expand_path(ARGV[0])
  phrase = ARGV[1]
  raise 'Empty exact phrase' if phrase == ''
  allowance = Float(ENV.fetch('OCR_STAGE_SECONDS', '20'))
  raise 'Invalid OCR allowance' unless allowance.finite? && allowance > 0
  deadline = monotonic + [20.0, allowance].min
  if ENV['LOCALSEND_STAGE_DEADLINE_MONOTONIC']
    external = Float(ENV['LOCALSEND_STAGE_DEADLINE_MONOTONIC'])
    raise 'Invalid external deadline' unless external.finite?
    deadline = [deadline, external].min
  end
  header = File.open(image, 'rb') { |file| file.read(32) }
  if header && header.bytesize >= 26 && header.start_with?('BM')
    dib = header.byteslice(14, 4).unpack('V').first
    if dib == 12
      width, height = header.byteslice(18, 4).unpack('v2')
    elsif dib >= 40
      width, height = header.byteslice(18, 8).unpack('l<2')
      height = height.abs
    else
      raise 'Unsupported BMP header'
    end
  else
    metadata = image + '.dimensions.json'
    run_child(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'json', image],
              metadata, image + '.dimensions.stderr', deadline)
    stream = JSON.parse(File.read(metadata)).fetch('streams').first
    width, height = stream.fetch('width'), stream.fetch('height')
  end
  raise 'Invalid original dimensions' unless width.is_a?(Integer) && height.is_a?(Integer) && width > 0 && height > 0
  tsv = image + '.tsv'
  run_child(['tesseract', image, 'stdout', '-l', 'eng', '--psm', '3', 'tsv'], tsv, image + '.ocr.stderr', deadline)
  groups = {}
  File.foreach(tsv).with_index do |row, index|
    next if index == 0
    fields = row.chomp.split("\t", 12)
    next unless fields.length == 12 && fields[0] == '5' && !fields[11].strip.empty?
    confidence = Float(fields[10]) / 100.0
    raise 'Invalid OCR confidence' unless confidence.finite? && (0.0..1.0).cover?(confidence)
    x, y, w, h = fields[6, 4].map { |value| Integer(value, 10) }
    raise 'OCR bounds outside original image' unless x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= width && y + h <= height
    key = fields[1, 4] # page, block, paragraph, line; word number is deliberately excluded.
    (groups[key] ||= []) << { text: fields[11], confidence: confidence, x: x, y: y, width: w, height: h }
  end
  union = lambda do |words|
    x = words.map { |word| word[:x] }.min
    y = words.map { |word| word[:y] }.min
    { x: x, y: y, width: words.map { |word| word[:x] + word[:width] }.max - x,
      height: words.map { |word| word[:y] + word[:height] }.max - y }
  end
  lines = []
  matches = []
  groups.each_value do |words|
    text = words.map { |word| word[:text] }.join(' ')
    confidence = words.map { |word| word[:confidence] }.min
    lines << { text: text, confidence: confidence, bounds: union.call(words) }
    next unless phrase
    # Exact word-span matches preserve case and phrase boundaries without enlarging
    # the bounds to unrelated words in the same line.
    words.each_index do |first|
      (first...words.length).each do |last|
        selected = words[first..last]
        next unless selected.map { |word| word[:text] }.join(' ') == phrase
        score = selected.map { |word| word[:confidence] }.min
        next unless score >= 0.5
        matches << { text: phrase, line: text, confidence: score, bounds: union.call(selected) }
      end
    end
  end
  puts JSON.pretty_generate(width: width, height: height, origin: 'top-left', lines: lines, matches: matches)
rescue StandardError => error
  warn "OCR failed: #{error.message}"
  exit 1
end
