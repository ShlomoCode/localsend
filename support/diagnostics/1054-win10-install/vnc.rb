require 'socket'
require 'timeout'
require 'json'
class GuestVNC
  def initialize
    @socket = TCPSocket.new('127.0.0.1', 5901)
    raise 'Unexpected protocol' unless read(12).start_with?('RFB 003.')
    @socket.write "RFB 003.008\n"
    types = read(read(1).unpack1('C')).bytes
    raise 'Loopback RFB authentication unavailable' unless types.include?(1)
    @socket.write [1].pack('C')
    raise 'RFB security failure' unless read(4).unpack1('N') == 0
    @socket.write [1].pack('C')
    @width, @height = read(4).unpack('n2')
    read(16)
    read(read(4).unpack1('N'))
    raise 'Frame too large' if @width * @height > 16_777_216
    @socket.write [0, 0, 0, 0].pack('C4') + [32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 0, 0, 0].pack('C4n3C6')
    @socket.write [2, 0, 1, 0].pack('CCnN')
  end
  def read(count)
    data = ''.b
    while data.bytesize < count
      chunk = @socket.read(count - data.bytesize)
      raise 'RFB closed' unless chunk
      data << chunk
    end
    data
  end
  def key(symbol, down)
    @socket.write [4, down ? 1 : 0, 0, symbol].pack('CCnN')
  end
  def tap(symbol)
    key(symbol, true)
    key(symbol, false)
  end
  def click(x, y)
    raise 'Pointer out of bounds' unless x.between?(0, @width - 1) && y.between?(0, @height - 1)
    @socket.write [5, 0, x, y].pack('CCn2')
    @socket.write [5, 1, x, y].pack('CCn2')
    @socket.write [5, 0, x, y].pack('CCn2')
  end
  def text(value)
    value.each_codepoint do |code|
      raise 'Use ASCII text for controlled console entry' unless code.between?(32, 126)
      tap(code)
    end
  end
  def screenshot(path)
    @socket.write [3, 0, 0, 0, @width, @height].pack('CCn4')
    pixels = Array.new(@height) { "\0".b * @width * 4 }
    loop do
      kind = read(1).unpack1('C')
      next if kind == 2
      if kind == 3
        read(3)
        read(read(4).unpack1('N'))
        next
      end
      raise "Unexpected RFB message #{kind}" unless kind == 0
      read(1)
      rectangles = read(2).unpack1('n')
      raise 'No framebuffer rectangles received' if rectangles.zero?
      rectangles.times do
        x, y, width, height, encoding = read(12).unpack('n4N')
        raise 'Unexpected RFB encoding' unless encoding == 0
        raise 'Framebuffer bounds invalid' if x + width > @width || y + height > @height
        height.times { |row| pixels[y + row][x * 4, width * 4] = read(width * 4) }
      end
      size = @width * @height * 4
      header = 'BM' + [54 + size, 0, 54].pack('V3')
      header << [40, @width, @height, 1, 32, 0, size, 0, 0, 0, 0].pack('V3v2V6')
      File.binwrite(path, header + pixels.reverse.join)
      return
    end
  end
  def close
    @socket.close
  end
end

if $PROGRAM_NAME == __FILE__
  # Ordinary VNC input helper for a subsequent same-job actual-app workflow.
  operation, *args = ARGV
  Timeout.timeout(20) do
    client = GuestVNC.new
    case operation
    when 'capture'; client.screenshot(args.fetch(0))
    when 'click'; client.click(Integer(args.fetch(0)), Integer(args.fetch(1)))
    when 'text'; client.text(args.fetch(0))
    when 'key'; client.tap(Integer(args.fetch(0)))
    when 'run'
      client.key(0xffeb, true) # Left Windows/Super.
      client.tap('r'.ord)
      client.key(0xffeb, false)
    else; raise 'Expected capture, click, text, key, or run'
    end
    client.close
  end
end
