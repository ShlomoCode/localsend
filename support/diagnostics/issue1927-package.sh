#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
mkdir -p evidence/packages/provenance
OUT=$(realpath evidence/packages)
SOURCE=$(realpath evidence/source)
(cd "$SOURCE" && sha256sum -c SHA256SUMS)
sudo apt-get update
sudo apt-get install -y flatpak flatpak-builder ruby git
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
git clone --recurse-submodules https://github.com/flathub/org.localsend.localsend_app.git "$RUNNER_TEMP/issue1927-package"
cd "$RUNNER_TEMP/issue1927-package"
git checkout 1b93d4aed3c0867e95feb2d4022a3f6a6b232e7e
git submodule update --init --recursive
git rev-parse HEAD > "$OUT/provenance/packaging-sha.txt"
cp org.localsend.localsend_app.yml "$OUT/provenance/original-manifest.yml"
for variant in baseline candidate; do
  archive="$SOURCE/$variant-source-bundle.tar.gz"
  # Change only the declared LocalSend archive input. The normal manifest owns
  # installation, metadata, libraries, and unchanged stock sandbox permissions.
  ruby -ryaml -rjson -e '
    manifest = YAML.load_file(ARGV[0])
    # CMake 4/current 26.08 SDK selects lib64, which the stock follow-on
    # pkg-config build cannot find. Normalize normal build installation only;
    # the same adjustment applies to both packages and adds no app permission.
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
    raise "finish-args changed" unless manifest.fetch("finish-args") == YAML.load_file(ARGV[0]).fetch("finish-args")
    puts JSON.pretty_generate(manifest)
  ' org.localsend.localsend_app.yml "$archive" > "$variant-manifest.json"
  cp "$variant-manifest.json" "$OUT/provenance/"
  flatpak-builder --user --assumeyes --install-deps-from=flathub --default-branch=stable --force-clean --repo=repo "build-$variant" "$variant-manifest.json" > "$OUT/provenance/$variant-package-build.log" 2>&1
  flatpak build-bundle repo "$OUT/$variant.flatpak" org.localsend.localsend_app stable
  flatpak info --user --show-commit org.freedesktop.Platform/x86_64/26.08 > "$OUT/provenance/runtime-commit.txt"
done
cd "$OUT"
sha256sum baseline.flatpak candidate.flatpak > SHA256SUMS
