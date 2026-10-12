#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || exit 8
PACKAGING=1b93d4aed3c0867e95feb2d4022a3f6a6b232e7e
RUNTIME=92659297ffdb4f9f14dd1562bd919b48160b0dc42c99653dcfc0688096af41df
mkdir -p evidence/packages/provenance
OUT=$(realpath evidence/packages)
SOURCE=$(realpath evidence/source)
OLD=$(realpath evidence/immutable-packages/packages)
exec > >(tee "$OUT/provenance/package-stage.log") 2>&1
(cd "$SOURCE" && sha256sum -c SHA256SUMS)
test "$(cat "$OLD/provenance/packaging-sha.txt")" = "$PACKAGING"
test "$(cat "$OLD/provenance/runtime-commit.txt")" = "$RUNTIME"
cp -a "$OLD/provenance" "$OUT/provenance/immutable-packages"
sudo apt-get update
sudo apt-get install -y flatpak flatpak-builder ruby git ostree
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user --noninteractive -y flathub org.freedesktop.Platform/x86_64/26.08
flatpak update --user --noninteractive --commit="$RUNTIME" org.freedesktop.Platform/x86_64/26.08
test "$(flatpak info --user --show-commit org.freedesktop.Platform/x86_64/26.08)" = "$RUNTIME"
git clone --recurse-submodules https://github.com/flathub/org.localsend.localsend_app.git "$RUNNER_TEMP/issue1927-product-package"
cd "$RUNNER_TEMP/issue1927-product-package"
git checkout "$PACKAGING"
git submodule update --init --recursive
git rev-parse HEAD > "$OUT/provenance/packaging-sha.txt"
cmp org.localsend.localsend_app.yml "$OLD/provenance/original-manifest.yml"
cp org.localsend.localsend_app.yml "$OUT/provenance/original-manifest.yml"
for variant in baseline candidate; do
  archive="$SOURCE/$variant-source-bundle.tar.gz"
  digest=$(sha256sum "$archive" | cut -d ' ' -f 1)
  ruby -ryaml -rjson -e '
    original=YAML.load_file(ARGV[0]); manifest=Marshal.load(Marshal.dump(original))
    scope="--filesystem=xdg-config/autostart:create"
    abort "Unexpected original autostart grant" if manifest.fetch("finish-args").any? { |x| x.include?("autostart") }
    manifest.fetch("finish-args") << scope
    normalize=lambda do |modules|
      modules.each do |m|
        next unless m.is_a?(Hash)
        if m["buildsystem"]=="cmake-ninja"
          (m["config-opts"] ||= []) << "-DCMAKE_INSTALL_LIBDIR=lib"
        end
        normalize.call(m["modules"]) if m["modules"]
      end
    end
    normalize.call(manifest.fetch("modules"))
    app=manifest.fetch("modules").find { |m| m.is_a?(Hash) && m["name"]=="localsend" }
    abort "LocalSend module absent" unless app
    app["sources"]=app.fetch("sources").reject { |s| s["dest-filename"]=="LocalSend.tar.gz" }
    app["sources"].unshift({"type"=>"file","path"=>ARGV[1],"sha256"=>ARGV[2],"dest-filename"=>"LocalSend.tar.gz"})
    abort "Unexpected finish arguments" unless manifest.fetch("finish-args")==original.fetch("finish-args")+[scope]
    puts JSON.pretty_generate(manifest)
  ' org.localsend.localsend_app.yml "$archive" "$digest" > "$variant-manifest.json"
  cp "$variant-manifest.json" "$OUT/provenance/"
done
# Compare the entire manifests before building, permitting only archive identity.
ruby -rjson -e '
  pair=ARGV.map { |p| JSON.parse(File.read(p)) }
  pair.each do |m|
    app=m.fetch("modules").find { |x| x.is_a?(Hash) && x["name"]=="localsend" }
    archive=app.fetch("sources").select { |s| s["dest-filename"]=="LocalSend.tar.gz" }
    abort "Ambiguous archive" unless archive.length==1
    archive[0]["path"]="SAME_ARCHIVE_INPUT"; archive[0]["sha256"]="SAME_ARCHIVE_DIGEST"
  end
  abort "Package manifests differ beyond source archive" unless pair[0]==pair[1]
  puts "whole_manifest_equal_except_archive=PASS"
' baseline-manifest.json candidate-manifest.json > "$OUT/provenance/manifest-comparison.txt"
for variant in baseline candidate; do
  flatpak-builder --user --assumeyes --install-deps-from=flathub --default-branch=stable --force-clean --repo=repo "build-$variant" "$variant-manifest.json" > "$OUT/provenance/$variant-package-build.log" 2>&1
  flatpak build-bundle repo "$OUT/$variant.flatpak" org.localsend.localsend_app stable
  flatpak info --user --show-commit org.freedesktop.Platform/x86_64/26.08 > "$OUT/provenance/runtime-commit.txt"
  test "$(cat "$OUT/provenance/runtime-commit.txt")" = "$RUNTIME"
  ostree --repo=repo rev-parse app/org.localsend.localsend_app/x86_64/stable > "$OUT/provenance/$variant-app-commit.txt"
done
cd "$OUT"
sha256sum baseline.flatpak candidate.flatpak > SHA256SUMS
