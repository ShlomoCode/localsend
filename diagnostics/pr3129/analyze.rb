require 'json'
root=ARGV.fetch(0,'evidence')
report={}
Dir.glob("#{root}/*/probe.jsonl").sort.each do |path|
  name=File.basename(File.dirname(path))
  rows=File.readlines(path).map { |line| JSON.parse(line) }
  phases={}
  rows.group_by { |r| r['phase'] }.each do |phase,samples|
    stable=samples.size>3 ? samples[1...-1] : samples
    frames=stable.flat_map { |r| r['frames'] }
    paints=stable.flat_map { |r| r['paints'].to_a }.group_by(&:first).transform_values { |pairs| pairs.sum(&:last) }
    metrics={seconds:stable.size,frame_count:frames.size,paints:paints,tabs:samples.map { |r| r['tab'] }.uniq}
    %w[build_us raster_us total_us].each do |key|
      values=frames.map { |f| f[key] }.sort
      metrics[key]={median:values[values.size/2],p95:values[(values.size*0.95).floor],max:values.last,over_16667:values.count { |v| v>16667 },over_33333:values.count { |v| v>33333 }} unless values.empty?
    end
    phases[phase]=metrics
  end
  geometries={}
  %w[move title-drag terminal-move send-move no-record-move].each do |kind|
    p=File.join(File.dirname(path),"#{kind}-geometries.txt")
    points=File.readlines(p).map { |line| [line[/\bX=(-?\d+)/,1],line[/\bY=(-?\d+)/,1]] }
    geometries[kind]={samples:points.size,unique_positions:points.uniq.size,first:points.first,last:points.last}
  end
  report[name]={phases:phases,geometries:geometries}
end
puts JSON.pretty_generate(report)
