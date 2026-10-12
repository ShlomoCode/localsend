#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
mkdir -p evidence/packages/provenance
OUT=$(realpath evidence/packages)
SOURCE=$(realpath evidence/source)
EXPECTED_SOURCE=d76437b6effdbcd8e0835f353c95b0fa7affeac123dcc853e7dd5b25107e9e5c
EXPECTED_BASELINE=3dbdb82917adc3ca724002380bd74ed4346a980166a8c7fb2aa19d51a6f60a36
printf '%s  %s\n' "$EXPECTED_SOURCE" "$SOURCE/baseline-source-bundle.tar.gz" | sha256sum -c -
printf '%s  %s\n' "$EXPECTED_BASELINE" "$OUT/baseline.flatpak" | sha256sum -c -
cp "$SOURCE/SHA256SUMS" "$OUT/provenance/source-SHA256SUMS"
cp -r "$SOURCE/provenance" "$OUT/provenance/source"
sudo apt-get update
sudo apt-get install -y flatpak flatpak-builder ruby git
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
git clone --recurse-submodules https://github.com/flathub/org.localsend.localsend_app.git "$RUNNER_TEMP/issue1927-mapping-package"
cd "$RUNNER_TEMP/issue1927-mapping-package"
git checkout 1b93d4aed3c0867e95feb2d4022a3f6a6b232e7e
git submodule update --init --recursive
git rev-parse HEAD > "$OUT/provenance/mapping-packaging-sha.txt"
git submodule status --recursive > "$OUT/provenance/mapping-submodules.txt"
cp org.localsend.localsend_app.yml "$OUT/provenance/mapping-original-manifest.yml"
# Same supported normal build inputs as the retained baseline, plus one declared
# finish-arg. flatpak-builder owns installation and exported package metadata.
ruby -ryaml -rjson -e '
  original = YAML.load_file(ARGV[0])
  manifest = YAML.load_file(ARGV[0])
  normalize = lambda do |modules|
    modules.each do |m|
      next unless m.is_a?(Hash)
      if m["buildsystem"] == "cmake-ninja"
        m["config-opts"] ||= []
        m["config-opts"] << "-DCMAKE_INSTALL_LIBDIR=lib"
      end
      normalize.call(m["modules"]) if m["modules"]
    end
  end
  normalize.call(manifest.fetch("modules"))
  app = manifest.fetch("modules").find { |m| m.is_a?(Hash) && m["name"] == "localsend" }
  app["sources"] = app.fetch("sources").reject { |s| s["dest-filename"] == "LocalSend.tar.gz" }
  app["sources"].unshift({"type"=>"file", "path"=>ARGV[1], "dest-filename"=>"LocalSend.tar.gz"})
  permission = "--filesystem=xdg-config/autostart:create"
  raise "permission already exists upstream" if manifest.fetch("finish-args").include?(permission)
  manifest["finish-args"] << permission
  raise "unexpected permission delta" unless manifest.fetch("finish-args") == original.fetch("finish-args") + [permission]
  puts JSON.pretty_generate(manifest)
' org.localsend.localsend_app.yml "$SOURCE/baseline-source-bundle.tar.gz" > mapping-manifest.json
ruby -rjson -e '
  baseline = JSON.parse(File.read(ARGV[0]))
  exposed = JSON.parse(File.read(ARGV[1]))
  source_path = lambda do |m|
    m.fetch("modules").find { |v| v.is_a?(Hash) && v["name"] == "localsend" }.fetch("sources").find { |v| v["dest-filename"] == "LocalSend.tar.gz" }["path"] = "IMMUTABLE_BASELINE_ARCHIVE"
  end
  source_path.call(baseline)
  source_path.call(exposed)
  baseline.fetch("finish-args") << "--filesystem=xdg-config/autostart:create"
  raise "unexpected baseline packaging delta" unless baseline == exposed
' "$OUT/provenance/baseline-manifest.json" mapping-manifest.json
cp mapping-manifest.json "$OUT/provenance/"
flatpak --version > "$OUT/provenance/package-host-flatpak-version.txt"
flatpak-builder --version > "$OUT/provenance/package-host-builder-version.txt"
dpkg-query -W flatpak flatpak-builder libflatpak0 > "$OUT/provenance/package-host-library-versions.txt"
flatpak-builder --user --assumeyes --install-deps-from=flathub --default-branch=stable --force-clean --repo=repo build-mapping mapping-manifest.json > "$OUT/provenance/mapping-package-build.log" 2>&1
flatpak build-bundle repo "$OUT/exposed.flatpak" org.localsend.localsend_app stable
flatpak info --user org.freedesktop.Platform/x86_64/26.08 > "$OUT/provenance/mapping-runtime-info.txt"
flatpak info --user --show-commit org.freedesktop.Platform/x86_64/26.08 > "$OUT/provenance/mapping-runtime-commit.txt"
flatpak list --user --runtime --columns=application,arch,branch,version,commit > "$OUT/provenance/mapping-installed-runtimes.txt"
cd "$OUT"
printf '%s  baseline.flatpak\n' "$EXPECTED_BASELINE" | sha256sum -c -
sha256sum baseline.flatpak exposed.flatpak > SHA256SUMS
