#!/usr/bin/env ruby
# Temporary diagnostic instrumentation; run only in a disposable checkout.
require 'fileutils'
require 'open3'

abort 'Usage: ruby support/benchmarks/taskbar/prepare.rb BASE_SHA' unless ARGV.length == 1
base = ARGV.fetch(0)
abort 'BASE_SHA must be a full commit SHA' unless base.match?(/\A[0-9a-f]{40}\z/)
root = File.expand_path('../../..', __dir__)
helper = 'app/lib/util/native/taskbar_helper.dart'
baseline, status = Open3.capture2('git', '-C', root, 'show', "#{base}:#{helper}")
abort 'Could not read baseline helper' unless status.success?
abort 'Unexpected baseline helper' unless baseline.scan('class TaskbarHelper').length == 1 && baseline.scan('enum TaskbarIcon { regular, error, success }').length == 1
baseline = baseline.gsub(/\bTaskbarHelper\b/, 'BeforeTaskbarHelper')
baseline = baseline.sub('enum TaskbarIcon { regular, error, success }', '')
baseline = "import 'package:localsend_app/util/native/taskbar_helper.dart' show TaskbarIcon;\n#{baseline}"
destination = File.join(root, 'app/lib/util/native/taskbar_before_benchmark.dart')
abort 'Baseline destination already exists' if File.exist?(destination)

swift_path = File.join(root, 'app/macos/Runner/AppDelegate.swift')
swift = File.read(swift_path)
def replace_once(source, anchor, replacement)
  abort "Expected one exact instrumentation anchor: #{anchor.inspect}" unless source.scan(anchor).length == 1
  source.sub(anchor, replacement)
end
swift = replace_once(swift, "import Cocoa\n", "import Cocoa\nimport Darwin\n")
swift = replace_once(swift, "    private var statusItem: NSStatusItem?", <<~'SWIFT'.lines.map { |line| "    #{line}" }.join.rstrip)
private var benchmarkCalls: Int64 = 0
private var benchmarkHandlerNanos: UInt64 = 0

private func benchmarkMetrics() -> [String: Any] {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { fatalError("getrusage failed") }
    return [
        "native_calls": benchmarkCalls,
        "native_handler_ns": Int64(benchmarkHandlerNanos),
        "app_user_cpu_us": Int64(usage.ru_utime.tv_sec) * 1_000_000 + Int64(usage.ru_utime.tv_usec),
        "app_system_cpu_us": Int64(usage.ru_stime.tv_sec) * 1_000_000 + Int64(usage.ru_stime.tv_usec)
    ]
}

private var statusItem: NSStatusItem?
SWIFT
swift = replace_once(swift, <<'SWIFT', <<'SWIFT')
        case "updateDockProgress":
            let progress = call.arguments as! Double
            DockProgress.progress = progress
            result(nil)
SWIFT
        case "resetBenchmarkMetrics":
            benchmarkCalls = 0
            benchmarkHandlerNanos = 0
            result(benchmarkMetrics())
        case "readBenchmarkMetrics":
            result(benchmarkMetrics())
        case "updateDockProgress":
            let started = DispatchTime.now().uptimeNanoseconds
            let progress = call.arguments as! Double
            DockProgress.progress = progress
            benchmarkCalls += 1
            benchmarkHandlerNanos += DispatchTime.now().uptimeNanoseconds - started
            result(nil)
SWIFT
# All anchors are checked before any mutation.
File.write(destination, baseline)
FileUtils.cp(File.join(__dir__, 'benchmark.dart'), File.join(root, 'app/lib/taskbar_benchmark.dart'))
File.write(swift_path, swift)
puts "Prepared taskbar benchmark with baseline #{base}"
