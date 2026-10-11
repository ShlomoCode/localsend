#!/usr/bin/env bash
# Debian GNOME guest only. Build each complete package from declared inputs.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 STAGED_INPUT_DIR" >&2; exit 2; }
input=$(realpath "$1")
output=/home/probe/evidence/source-flatpak
[[ ! -e $output ]]
mkdir -p "$output"
exec > >(tee "$output/build.log") 2>&1
date -u +%FT%T.%N
descriptor="$input/whole-bundle-descriptor.accepted.json"
jq -e '.root_accepted == true and .app_build_run_id == "38164164206"' "$descriptor"
sdk_commit=0cc82216a407cc993941b5ddabd446becc3c9a6219d9bcf50125c60101dcad46
runtime_commit=d27f7a6a974e40b061070bec1be9e1b52a7a6872b271e6a45c2c34a48bf6fedf
sudo flatpak install -y flathub org.freedesktop.Sdk//25.08
sudo flatpak install -y flathub org.freedesktop.Sdk.Extension.vala//25.08
sudo flatpak update -y --commit="$sdk_commit" org.freedesktop.Sdk//25.08
sudo flatpak update -y --commit="$runtime_commit" org.freedesktop.Platform//25.08
[[ $(flatpak info --show-commit org.freedesktop.Sdk//25.08) == "$sdk_commit" ]]
[[ $(flatpak info --show-commit org.freedesktop.Platform//25.08) == "$runtime_commit" ]]
flatpak info org.freedesktop.Sdk//25.08
flatpak info org.freedesktop.Platform//25.08
flatpak info org.freedesktop.Sdk.Extension.vala//25.08 > "$output/vala-extension-info.txt"
flatpak info --show-commit org.freedesktop.Sdk.Extension.vala//25.08 > "$output/vala-extension-commit.txt"
flatpak-builder --version
git clone --recurse-submodules https://github.com/flathub/org.localsend.localsend_app.git "$output/flathub"
git -C "$output/flathub" checkout e6a71e097895dcab75ab2f961eac6b816c108e80
git -C "$output/flathub" submodule update --init
git -C "$output/flathub" rev-parse HEAD > "$output/flathub-sha.txt"
git -C "$output/flathub" submodule status > "$output/flathub-submodules.txt"
cmp "$input/flatpak-original.yml" "$output/flathub/org.localsend.localsend_app.yml"
for variant in control B; do
  bundle="$input/$variant/artifact/source-bundle.tar.gz"
  manifest="$input/$variant/artifact/provenance/manifest.json"
  [[ $(sha256sum "$bundle" | awk '{print $1}') == $(jq -er --arg v "$variant" '.variants[$v].bundle_sha256' "$descriptor") ]]
  cp "$bundle" "$output/flathub/LocalSend-$variant.tar.gz"
  cp "$manifest" "$output/$variant-app-manifest.json"
done
cp "$input/A-production.patch" "$output/flathub/A-production.patch"
sha256sum "$output/flathub/A-production.patch" > "$output/A-source-patch.sha256"
# Ruby YAML edits declared source manifests before flatpak-builder starts.
/usr/bin/ruby -ryaml -rjson -e '
  root, descriptor_path = ARGV
  descriptor = JSON.parse(File.read(descriptor_path))
  base = YAML.load_file(File.join(root, "org.localsend.localsend_app.yml"))
  %w[control B].each do |engine|
    %w[stock A].each do |bridge|
      m = Marshal.load(Marshal.dump(base))
      a = {"name"=>"at-spi2-core-254-source", "buildsystem"=>"meson",
        "config-opts"=>["-Ddocs=false","-Dintrospection=disabled","-Dgtk2_atk_adaptor=false","-Duse_systemd=false"],
        "sources"=>[{"type"=>"archive", "url"=>"https://codeload.github.com/GNOME/at-spi2-core/tar.gz/2b2085e3bb98c35cfeaf33a9b2852c610c3a9b7b",
          "dest-filename"=>"at-spi2-core-254.tar.gz",
          "sha256"=>"ef4f2a528f76edc7cb37b70d0143a51fa5e049ae93198c4426befd2c250c3b03"}]}
      a["sources"] << {"type"=>"patch","path"=>"A-production.patch"} if bridge == "A"
      m["modules"].insert(-2,a)
      app = m["modules"].find {|x| x.is_a?(Hash) && x["name"] == "localsend"}
      app["sources"].reject! {|s| s["only-arches"]}
      app["sources"].unshift({"type"=>"file","path"=>"LocalSend-#{engine}.tar.gz","dest-filename"=>"LocalSend.tar.gz"})
      File.write(File.join(root,"matrix-#{engine}-#{bridge}.yml"),YAML.dump(m))
    end
  end
' "$output/flathub" "$descriptor"
for engine in control B; do
  for bridge in stock A; do
    case_name="$engine-$bridge"
    mkdir -p "$output/$case_name"
    cp "$output/flathub/matrix-$case_name.yml" "$output/$case_name/manifest.yml"
    (
      cd "$output/flathub"
      timeout --foreground 2400 flatpak-builder --verbose --force-clean --repo="$output/$case_name/repo" \
        "$output/$case_name/build" "matrix-$case_name.yml"
    ) 2>&1 | tee "$output/$case_name/build.log"
    flatpak build-export "$output/$case_name/repo" "$output/$case_name/build" diagnostic \
      > "$output/$case_name/export.log" 2>&1
    ostree --repo="$output/$case_name/repo" rev-parse app/org.localsend.localsend_app/x86_64/diagnostic \
      > "$output/$case_name/commit.txt"
    find "$output/$case_name/build/files/lib" -name 'libatk-bridge*.so*' -type f -exec sha256sum {} \; \
      > "$output/$case_name/bridge-SHA256SUMS"
    [[ -s "$output/$case_name/bridge-SHA256SUMS" ]]
    bash "$input/verify-packaged-bundle.sh" "$input/$engine/bundle" \
      "$output/$case_name/build/files" "$output/$case_name/bundle-verification"
    sha256sum "$output/$case_name/build/files/localsend_app" "$output/$case_name/build/files/lib/libapp.so" \
      "$output/$case_name/build/files/lib/libflutter_linux_gtk.so" > "$output/$case_name/app-SHA256SUMS"
    printf '%s\n' "$engine" > "$output/$case_name/engine-variant.txt"
    printf '%s\n' "$bridge" > "$output/$case_name/bridge-variant.txt"
    date -u +%FT%T.%N > "$output/$case_name/completed-at.txt"
  done
done
printf 'Four source-defined Flatpak packages built. Loaded namespace identities and GUI assertions remain pending.\n' > "$output/result.txt"
