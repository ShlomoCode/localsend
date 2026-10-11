require "base64"
require "json"
dir = ARGV.fetch(0)
lines = File.readlines(Dir["#{dir}/probe-*.txt"].first)
clean = []
lines.each_with_index do |line, i|
  if line.start_with?("iVBOR")
    name = lines[i-1].strip.sub("SCREEN:", "")
    File.binwrite("#{dir}/#{name}.png", Base64.decode64(line))
  elsif line.match?(/^\[\d+,/)
    state = JSON.parse(line)
    mode = state[1][0][1].find { |m| m[6]["is-current"] }
    clean << "STATE: serial=#{state[0]} mode=#{mode[0]} physical=#{mode[1]}x#{mode[2]} logical_monitors=#{state[2]}\n"
  else
    clean << line
  end
end
File.write("#{dir}/result.txt", clean.join)
