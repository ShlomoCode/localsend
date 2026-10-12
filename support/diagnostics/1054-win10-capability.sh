#!/usr/bin/env bash
# Cloud capability preparation only. No LocalSend or Windows reproduction claim.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || { echo "Cloud-only capability gate" >&2; exit 2; }
OUT="${EVIDENCE_DIR:?Set EVIDENCE_DIR}"
mkdir -p "$OUT"
exec > >(tee "$OUT/preparation.log") 2>&1
trap 'result=$?; if [[ -n "${ISO:-}" ]]; then rm -f "$ISO"; fi; exit "$result"' EXIT
stage() { printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT/stages.tsv"; }
PREPARATION_STARTED=$SECONDS
stage 'host-measurement'
sw_vers > "$OUT/sw-vers.txt"
uname -a > "$OUT/uname.txt"
sysctl hw.memsize hw.ncpu kern.hv_support > "$OUT/sysctl.txt" 2>&1 || true
df -k "$OUT" > "$OUT/disk-before.txt"
if ! command -v qemu-system-x86_64 >/dev/null; then
  stage 'install-qemu'
  HOMEBREW_NO_AUTO_UPDATE=1 brew install qemu
fi
QEMU="$(command -v qemu-system-x86_64)"
"$QEMU" --version > "$OUT/qemu-version.txt"
"$QEMU" -accel help > "$OUT/qemu-accelerators.txt"

# Ruby stdlib provides deadlines, QMP control, and real RFB framebuffer capture.
cat > "$OUT/capability.rb" <<'RUBY'
require 'socket'
require 'json'
require 'timeout'
require 'digest'
out, qemu = ARGV
def exact(io, count)
  data = ''.b
  while data.bytesize < count
    chunk = io.read(count - data.bytesize)
    raise 'Peer closed connection' unless chunk
    data << chunk
  end
  data
end
def qmp_command(socket, name)
  socket.puts JSON.generate(execute: name)
  loop do
    value = JSON.parse(socket.readline)
    return value if value.key?('return') || value.key?('error')
  end
end
def bitmap(path, width, height, pixels)
  # RFB is requested as little-endian BGRX, matching uncompressed 32-bit BMP.
  size = width * height * 4
  header = 'BM' + [54 + size, 0, 54].pack('V3')
  header << [40, width, height, 1, 32, 0, size, 0, 0, 0, 0].pack('V3v2V6')
  File.binwrite(path, header + pixels.reverse.join)
end
probe = nil
probe_path = File.join(out, 'hvf-qmp.sock')
File.open(File.join(out, 'hvf-stderr.txt'), 'w') do |log|
  probe = Process.spawn(qemu, '-machine', 'pc', '-accel', 'hvf', '-cpu', 'host',
    '-m', '512', '-S', '-display', 'none', '-nic', 'none',
    '-qmp', "unix:#{probe_path},server=on,wait=off", out: log, err: log)
end
hvf = false
begin
  Timeout.timeout(5) do
    sleep 0.1 until File.socket?(probe_path)
    socket = UNIXSocket.new(probe_path)
    File.write(File.join(out, 'hvf-greeting.json'), socket.readline)
    capabilities = qmp_command(socket, 'qmp_capabilities')
    raise capabilities.inspect if capabilities.key?('error')
    status = qmp_command(socket, 'query-status')
    File.write(File.join(out, 'hvf-status.json'), JSON.pretty_generate(status))
    raise status.inspect unless status.dig('return', 'status') == 'prelaunch' || status.dig('return', 'status') == 'paused'
    qmp_command(socket, 'quit')
    socket.close
    hvf = true
  end
rescue => error
  File.write(File.join(out, 'hvf-failure.txt'), "#{error.class}: #{error.message}\n")
ensure
  begin; Process.kill('KILL', probe); rescue Errno::ESRCH; end
  Process.wait(probe)
end
File.write(File.join(out, 'acceleration.txt'), hvf ? "hvf\n" : "tcg (HVF probe failed; software emulation only)\n")
args = [qemu, '-machine', 'pc', '-accel', hvf ? 'hvf' : 'tcg', '-m', '512',
  '-nic', 'none', '-vga', 'std', '-boot', 'menu=on', '-display', 'none', '-vnc', '127.0.0.1:1']
args += ['-cpu', 'host'] if hvf
File.write(File.join(out, 'firmware-command.json'), JSON.pretty_generate(args))
guest = nil
File.open(File.join(out, 'firmware-stderr.txt'), 'w') { |log| guest = Process.spawn(*args, out: log, err: log) }
begin
  Timeout.timeout(20) do
    socket = nil
    until socket
      begin; socket = TCPSocket.new('127.0.0.1', 5901); rescue Errno::ECONNREFUSED; sleep 0.1; end
    end
    version = exact(socket, 12)
    raise "Unexpected RFB protocol #{version.inspect}" unless version.start_with?('RFB 003.')
    socket.write "RFB 003.008\n"
    count = exact(socket, 1).unpack1('C')
    types = exact(socket, count).bytes
    raise "No unprotected loopback security mode: #{types}" unless types.include?(1)
    socket.write [1].pack('C')
    raise 'RFB security failure' unless exact(socket, 4).unpack1('N') == 0
    socket.write [1].pack('C')
    width, height = exact(socket, 4).unpack('n2')
    exact(socket, 16)
    name = exact(socket, exact(socket, 4).unpack1('N'))
    File.write(File.join(out, 'vnc-server.json'), JSON.pretty_generate(width: width, height: height, name: name, protocol: version))
    format = [32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 0, 0, 0].pack('C4n3C6')
    socket.write [0, 0, 0, 0].pack('C4') + format
    socket.write [2, 0, 1, 0].pack('CCnN') # Raw encoding only.
    sleep 3
    capture = lambda do |filename|
      socket.write [3, 0, 0, 0, width, height].pack('CCn4')
      pixels = Array.new(height) { "\0".b * width * 4 }
      loop do
        kind = exact(socket, 1).unpack1('C')
        next if kind == 2 # Bell.
        raise "Unexpected RFB message #{kind}" unless kind == 0
        exact(socket, 1)
        rects = exact(socket, 2).unpack1('n')
        rects.times do
          x, y, w, h, encoding = exact(socket, 12).unpack('n4N')
          raise "Unexpected encoding #{encoding}" unless encoding == 0
          raise 'Framebuffer bounds invalid' if x + w > width || y + h > height
          h.times { |row| pixels[y + row][x * 4, w * 4] = exact(socket, w * 4) }
        end
        bitmap(File.join(out, filename), width, height, pixels)
        break
      end
    end
    capture.call('firmware-before.bmp')
    File.write(File.join(out, 'input.json'), JSON.pretty_generate(time: Time.now.utc.to_s, key: 'Escape', route: 'RFB key-down/key-up'))
    socket.write [4, 1, 0, 0xff1b].pack('CCnN')
    socket.write [4, 0, 0, 0xff1b].pack('CCnN')
    sleep 1
    capture.call('firmware-after.bmp')
    hashes = %w[firmware-before.bmp firmware-after.bmp].to_h { |file| [file, Digest::SHA256.file(File.join(out, file)).hexdigest] }
    File.write(File.join(out, 'frame-results.json'), JSON.pretty_generate(hashes: hashes, pixels_changed: hashes.values.uniq.length == 2,
      scope: 'Real QEMU VNC firmware frames. A frame change is not proof that Escape caused it; no Windows or LocalSend UI ran.'))
    socket.close
  end
ensure
  begin; Process.kill('KILL', guest); rescue Errno::ESRCH; end
  Process.wait(guest)
end
RUBY
stage 'bounded-hvf-and-vnc-firmware'
/usr/bin/ruby "$OUT/capability.rb" "$OUT" "$QEMU"
for image in "$OUT"/firmware-*.bmp; do
  sips -s format png "$image" --out "${image%.bmp}.png"
done
stage 'firmware-frames-retained-needs-human-inspection'
df -k "$OUT" > "$OUT/disk-after-qemu.txt"
FREE_KB="$(df -k "$OUT" | awk 'END {print $4}')"
MIN_KB=36700160 # 35 GiB free, measured after QEMU installation.
if [[ "$FREE_KB" -lt "$MIN_KB" ]]; then
  stage "blocked-storage free_kb=$FREE_KB required_kb=$MIN_KB; no ISO downloaded"
  exit 1
fi
stage "storage-pass free_kb=$FREE_KB; download official ISO"
ISO="$OUT/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
URL='https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso'
command -v curl > "$OUT/curl-command-path.txt"
curl --version > "$OUT/curl-version.txt"
curl --help all > "$OUT/curl-help-all.txt"
if ! grep -q -- '--continue-at' "$OUT/curl-help-all.txt"; then
  stage 'blocked-curl-version continue-at unsupported; no silent fallback or tool upgrade'
  exit 1
fi
# Resume the same official GET after a progressing transient failure. Separate
# invocations read the retained file length through curl's supported -C - API.
# Reserve 120s of the existing 840s prelaunch limit for verification/seed setup.
ISO_DOWNLOAD_DEADLINE=$((PREPARATION_STARTED + 720))
ISO_COMPLETE=0
for ISO_ATTEMPT in 1 2 3; do
  ISO_REMAINING=$((ISO_DOWNLOAD_DEADLINE - SECONDS))
  [[ "$ISO_REMAINING" -gt 0 ]] || { stage 'blocked-iso-download shared preparation budget exhausted'; exit 1; }
  ISO_BEFORE=0
  if [[ -f "$ISO" ]]; then ISO_BEFORE="$(stat -f '%z' "$ISO")"; fi
  stage "iso-attempt=$ISO_ATTEMPT resume_bytes=$ISO_BEFORE remaining_seconds=$ISO_REMAINING"
  ISO_RESULT=0
  curl --fail --location --continue-at - --retry 0 --max-time "$ISO_REMAINING" \
    --dump-header "$OUT/iso-attempt-$ISO_ATTEMPT-headers.txt" \
    --write-out '%{json}\n' "$URL" --output "$ISO" > "$OUT/iso-attempt-$ISO_ATTEMPT-transfer.json" || ISO_RESULT=$?
  ISO_AFTER=0
  if [[ -f "$ISO" ]]; then ISO_AFTER="$(stat -f '%z' "$ISO")"; fi
  stage "iso-attempt=$ISO_ATTEMPT exit=$ISO_RESULT before_bytes=$ISO_BEFORE after_bytes=$ISO_AFTER"
  if [[ "$ISO_RESULT" -eq 0 ]]; then ISO_COMPLETE=1; break; fi
  # Refuse unsupported ranges, HTTP errors, no progress, or an oversized file.
  case "$ISO_RESULT" in
    18|28|52|55|56) ;;
    *) exit "$ISO_RESULT" ;;
  esac
  [[ "$ISO_AFTER" -gt "$ISO_BEFORE" && "$ISO_AFTER" -lt 5550497792 ]] || exit "$ISO_RESULT"
done
[[ "$ISO_COMPLETE" -eq 1 ]] || { stage 'blocked-iso-download bounded resume attempts exhausted'; exit 1; }
printf '%s  %s\n' 'ef7312733a9f5d7d51cfa04ac497671995674ca5e1058d5164d6028f0938d668' "$ISO" > "$OUT/iso.expected.sha256"
shasum -a 256 -c "$OUT/iso.expected.sha256" | tee "$OUT/iso-verification.txt"
stat -f '%z' "$ISO" > "$OUT/iso-size.txt"
[[ "$(cat "$OUT/iso-size.txt")" == 5550497792 ]]
if [[ ${ISSUE1054_INSTALL_GUEST:-0} == 1 ]]; then
  stage 'ordinary-evaluation-installation-and-official-app-window'
  EVIDENCE_DIR="$OUT/install" CAPABILITY_DIR="$OUT" WINDOWS_ISO="$ISO" EVALUATION_TERMS_ACCEPTED=true \
    bash support/diagnostics/1054-win10-install/run.sh
  stage 'Windows-and-official-app-window-stage-returned; inspect original frames and guest records'
fi
# Keep tiny evidence rather than uploading or redistributing installation media.
rm "$ISO"
stage 'official-media-verification-finished; no app-to-app transfer executed'
