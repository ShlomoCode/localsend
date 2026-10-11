#!/usr/bin/env bash
# Cloud guest only. Read-only equivalence gate after supported Flatpak packaging.
# SOURCE_BUNDLE must already pass prepare-whole-bundle.sh's accepted manifest gate.
set -euo pipefail
export LC_ALL=C
[[ $# == 3 ]] || { echo "Usage: $0 ACCEPTED_SOURCE_BUNDLE PACKAGED_BUILD_FILES NEW_EVIDENCE_DIR" >&2; exit 2; }
source_bundle=$(realpath "$1")
packaged_files=$(realpath "$2")
[[ -d $source_bundle && -d $packaged_files && $source_bundle != "$packaged_files" ]]
output=$(realpath -m "$3")
[[ ! -e $output ]]
# Evidence must not be created inside either input tree.
[[ $output != "$source_bundle"/* && $output != "$packaged_files"/* ]]
mkdir -p "$output"
for command in ruby objcopy readelf cmp sha256sum; do command -v "$command" > /dev/null; done
objcopy --version > "$output/objcopy-version.txt"
readelf --version > "$output/readelf-version.txt"
ruby --version > "$output/ruby-version.txt"
printf 'source=%s\npackaged=%s\n' "$source_bundle" "$packaged_files" > "$output/inputs.txt"
/usr/bin/ruby - "$source_bundle" "$packaged_files" "$output" <<'RUBY'
require 'digest'
require 'find'
require 'json'
require 'open3'

source, packaged, output = ARGV
def checked(command, log)
  stdout, stderr, status = Open3.capture3(*command)
  File.write(log, stdout)
  File.write(log + '.stderr', stderr)
  raise "Command failed (#{status.exitstatus}): #{command.first}; see #{log}" unless status.success?
  stdout
end

def bytes_at(bytes, offset, length)
  raise 'ELF range outside file' if offset < 0 || length < 0 || offset + length > bytes.bytesize
  bytes.byteslice(offset, length)
end

def elf_layout(path)
  bytes = File.binread(path)
  # The accepted artifacts are Linux x86-64. Reject unsupported/extended ELF
  # encodings instead of silently applying the wrong parser.
  ident = bytes_at(bytes, 0, 16)
  raise 'Expected ELF64 little endian version 1' unless ident.start_with?("\x7fELF".b) && ident.getbyte(4) == 2 && ident.getbyte(5) == 1 && ident.getbyte(6) == 1
  type, machine, version, entry, phoff, shoff, flags, ehsize, phsize, phnum, shsize, shnum, shstr = bytes_at(bytes, 16, 48).unpack('S<S<L<Q<Q<Q<L<S<S<S<S<S<S<')
  raise 'Unsupported ELF machine/header/table encoding' unless machine == 62 && version == 1 && ehsize == 64 && phsize == 56 && phnum > 0 && phnum < 65535 && shsize == 64 && shnum > 0 && shstr > 0 && shstr < shnum
  # Program header order and every field affect loading. Nonallocated section
  # table positions/counts may change when debug sections are split out.
  program_headers = phnum.times.map do |i|
    bytes_at(bytes, phoff + i * phsize, phsize).unpack('L<L<Q<Q<Q<Q<Q<Q<')
  end
  raise 'No PT_LOAD segment' unless program_headers.any? { |p| p[0] == 1 }
  sections = shnum.times.map do |i|
    bytes_at(bytes, shoff + i * shsize, shsize).unpack('L<L<Q<Q<Q<Q<L<L<Q<Q<')
  end
  names_section = sections.fetch(shstr)
  raise 'Invalid section-name string table' unless names_section[1] == 3
  names = bytes_at(bytes, names_section[4], names_section[5])
  section_name = lambda do |section|
    name_offset = section.fetch(0)
    raise 'Section name outside string table' unless name_offset < names.bytesize
    ending = names.index("\0", name_offset)
    raise 'Unterminated section name' unless ending
    names.byteslice(name_offset, ending - name_offset)
  end
  allocated = sections.filter_map do |s|
    _name_offset, section_type, section_flags, address, offset, size, link, info, alignment, entry_size = s
    next if section_flags & 2 == 0
    name = section_name.call(s)
    raise 'Unnamed allocated section' if name.empty?
    linked_name = link == 0 ? nil : section_name.call(sections.fetch(link))
    # SHF_INFO_LINK makes sh_info a section index. Compare its meaning rather
    # than numbering, which can change when nonallocated sections are removed.
    info_value = section_flags & 0x40 == 0 || info == 0 ? info : section_name.call(sections.fetch(info))
    # SHT_NOBITS has no file bytes, but its memory size/layout must match.
    digest = section_type == 8 ? nil : Digest::SHA256.hexdigest(bytes_at(bytes, offset, size))
    {'name' => name, 'type' => section_type, 'flags' => section_flags,
     'address' => address, 'offset' => offset, 'size' => size,
     'alignment' => alignment, 'entrySize' => entry_size,
     'linkedSection' => linked_name, 'info' => info_value, 'payloadSha256' => digest}
  end
  raise 'No allocated sections or duplicate names' if allocated.empty? || allocated.map { |s| s['name'] }.uniq.length != allocated.length
  {'identHex' => ident.unpack1('H*'), 'type' => type, 'machine' => machine,
   'version' => version, 'entry' => entry, 'flags' => flags, 'headerSize' => ehsize,
   'programHeaderOffset' => phoff, 'programHeaderEntrySize' => phsize,
   'programHeaders' => program_headers, 'allocatedSections' => allocated.sort_by { |s| s['name'] }}
end

files = []
Find.find(source) do |path|
  stat = File.lstat(path)
  raise "Source includes a symlink or special node: #{path}" unless stat.directory? || stat.file?
  next unless stat.file?
  relative = path.delete_prefix(source + '/')
  # SHA256SUMS is intentionally ordinary sha256sum format for the later live
  # namespace gate. Reject ambiguous names rather than inventing an encoding.
  raise "Unsupported bundle path: #{relative.inspect}" if relative.match?(/[\n\r\\]/)
  files << relative
end
files.sort!
raise "Expected all 50 accepted bundle files, found #{files.length}" unless files.length == 50
%w[localsend_app lib/libapp.so lib/libflutter_linux_gtk.so].each do |required|
  raise "Missing required source artifact: #{required}" unless files.include?(required)
end

File.open(File.join(output, 'source-all50-SHA256SUMS'), 'w') do |source_sums|
  File.open(File.join(output, 'packaged-all50-SHA256SUMS'), 'w') do |packaged_sums|
    files.each_with_index do |relative, index|
      original = File.join(source, relative)
      installed = File.join(packaged, relative)
      raise "Missing/nonregular packaged bundle file: #{relative}" unless File.file?(installed) && !File.symlink?(installed) && File.realpath(installed) == installed
      evidence = File.join(output, format('%02d', index + 1))
      Dir.mkdir(evidence)
      File.write(File.join(evidence, 'relative-path.txt'), relative + "\n")
      original_hash = Digest::SHA256.file(original).hexdigest
      installed_hash = Digest::SHA256.file(installed).hexdigest
      source_sums.puts "#{original_hash}  ./#{relative}"
      packaged_sums.puts "#{installed_hash}  ./#{relative}"
      source_sums.flush
      packaged_sums.flush
      File.write(File.join(evidence, 'full-hashes.json'), JSON.pretty_generate({'source' => original_hash, 'packaged' => installed_hash}))
      original_magic = File.binread(original, 4)
      installed_magic = File.binread(installed, 4)
      is_elf = original_magic == "\x7fELF".b
      raise "Packaged ELF classification changed: #{relative}" unless is_elf == (installed_magic == "\x7fELF".b)
      if is_elf
        layouts = []
        build_ids = []
        [['source', original], ['packaged', installed]].each do |label, path|
          checked(['readelf', '--wide', '-h', '-l', '-S', path], File.join(evidence, label + '-load-layout.txt'))
          notes = checked(['readelf', '--wide', '-n', path], File.join(evidence, label + '-notes.txt'))
          # GNU readelf --wide can append Build ID to the owner/type row.
          ids = notes.scan(/\bBuild ID:[ \t]+([0-9a-fA-F]+)[ \t]*$/).flatten.map(&:downcase)
          raise "Expected exactly one GNU Build ID: #{relative} (#{label})" unless ids.length == 1
          build_ids << ids.first
          layout = elf_layout(path)
          layouts << layout
          File.write(File.join(evidence, label + '-layout.json'), JSON.pretty_generate(layout))
          checked(['objcopy', '-O', 'binary', path, File.join(evidence, label + '-allocated.bin')], File.join(evidence, label + '-objcopy.txt'))
        end
        raise "ELF GNU Build ID changed: #{relative}" unless build_ids[0] == build_ids[1]
        raise "ELF load/allocated-section layout or bytes changed: #{relative}" unless layouts[0] == layouts[1]
        checked(['cmp', File.join(evidence, 'source-allocated.bin'), File.join(evidence, 'packaged-allocated.bin')], File.join(evidence, 'allocated-cmp.txt'))
        File.write(File.join(evidence, 'allocated-hashes.json'), JSON.pretty_generate({
          'source' => Digest::SHA256.file(File.join(evidence, 'source-allocated.bin')).hexdigest,
          'packaged' => Digest::SHA256.file(File.join(evidence, 'packaged-allocated.bin')).hexdigest,
          'buildId' => build_ids.first}))
      else
        raise "Non-ELF bytes changed: #{relative}" unless original_hash == installed_hash
        checked(['cmp', original, installed], File.join(evidence, 'full-cmp.txt'))
      end
      raise "Executable permissions changed: #{relative}" unless File.stat(original).mode & 0111 == File.stat(installed).mode & 0111
      File.write(File.join(evidence, 'result.txt'), is_elf ? "ELF allocated bytes, load layout and GNU Build ID match.\n" : "Non-ELF full bytes match.\n")
    end
  end
end
File.write(File.join(output, 'result.json'), JSON.pretty_generate({
  'status' => 'pass', 'filesVerified' => files.length,
  'sourcePrecondition' => 'Already verified against the root-accepted bundle manifest',
  'scope' => 'Packaged bundle equivalence only; exported/install/live namespace and UI remain separate gates'}))
RUBY
date -u +%FT%T.%N > "$output/verified-at.txt"
