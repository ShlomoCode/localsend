require 'socket'
require 'json'
require 'timeout'
require 'time'

# One aggregate deadline includes connection, greeting and every command.
class GuestQMP
  def initialize(path, evidence, deadline)
    @evidence = evidence
    @deadline = deadline
    @sequence = 0
    begin
      loop do
        budget
        begin
          @socket = Timeout.timeout(budget) { path.is_a?(Array) ? TCPSocket.new(*path) : UNIXSocket.new(path) }
          break
        rescue Errno::ENOENT, Errno::ECONNREFUSED
          sleep [0.1, budget].min
        end
      end
      greeting = read_message
      version = greeting.dig('QMP', 'version', 'qemu')
      expected = ENV['ISSUE1054_HOST'] == 'linux' ? [8, 2, 2] : [11, 1, 0]
      raise 'Unexpected QMP greeting/version' unless version && version.values_at('major', 'minor', 'micro') == expected
      record('greeting', version)
      command('qmp_capabilities')
    rescue StandardError
      close
      raise
    end
  end

  def limit(deadline)
    @deadline = [@deadline, deadline].min
  end

  def command(name, arguments = nil)
    raise 'Unadmitted QMP command' unless %w[qmp_capabilities set_link cont].include?(name)
    @sequence += 1
    request = {'execute' => name, 'id' => "issue1054-#{@sequence}"}
    request['arguments'] = arguments if arguments
    Timeout.timeout(budget) { @socket.write(JSON.generate(request) + "\r\n") }
    loop do
      response = read_message
      if response['event']
        record('event', {'name' => response['event']})
        next
      end
      raise 'QMP response ID mismatch' unless response['id'] == request['id']
      record(name, {'arguments' => arguments, 'response' => response})
      raise "QMP #{name} failed" if response['error']
      raise 'Malformed QMP command response' unless response.key?('return')
      budget
      return response
    end
  end

  def close
    @socket.close if @socket && !@socket.closed?
  end

  private

  def budget
    remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise 'Aggregate QMP deadline exceeded' unless remaining > 0
    remaining
  end

  def read_message
    line = Timeout.timeout(budget) { @socket.gets(65_537) }
    raise 'QMP disconnected or oversized message' unless line && line.bytesize <= 65_536 && line.end_with?("\n")
    message = JSON.parse(line)
    raise 'QMP message is not an object' unless message.is_a?(Hash)
    budget
    message
  end

  def record(command, data)
    File.open(@evidence, 'a') do |file|
      file.puts JSON.generate(utc: Time.now.utc.iso8601, monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC), command: command, data: data)
    end
  end
end
