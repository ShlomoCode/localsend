#!/bin/bash
# Cloud-only normal hosted dependency resolution and shipping-path validation.
set -euo pipefail
diagnostic_root=$PWD
mkdir -p evidence/hosted /home/runner/513-hosted
build_root=/home/runner/513-hosted
git clone --branch "$PRODUCTION_REF" https://github.com/ShlomoCode/localsend "$build_root/source"
cd "$build_root/source"
git rev-parse HEAD > "$diagnostic_root/evidence/hosted/production-head.txt"
git diff c1ce322fb3acf08e44f329b8b7208b8b0d91e244 HEAD > "$diagnostic_root/evidence/hosted/production.patch"
fvm use 3.41.9 --skip-pub-get
fvm flutter --version > "$diagnostic_root/evidence/hosted/sdk.txt"
(cd app && fvm flutter pub get) > "$diagnostic_root/evidence/hosted/pub-get.txt" 2>&1
cp pubspec.lock "$diagnostic_root/evidence/hosted/lock-hosted.yaml"
git diff > "$diagnostic_root/evidence/hosted/source-diff-hosted.patch"
if [[ "$HOSTED_PHASE" == resolve ]]; then exit 0; fi
# A validation artifact must use the exact already-committed hosted lock.
git diff --exit-code
(cd app && fvm flutter analyze) > "$diagnostic_root/evidence/hosted/analyze.txt" 2>&1
(cd app && fvm flutter test) > "$diagnostic_root/evidence/hosted/tests-app.txt" 2>&1
(cd packages/localsend_isolates && fvm flutter test) > "$diagnostic_root/evidence/hosted/tests-isolates.txt" 2>&1
(cd app && fvm flutter build linux --release) > "$diagnostic_root/evidence/hosted/build-hosted.txt" 2>&1
plugin_source=$(realpath app/linux/flutter/ephemeral/.plugin_symlinks/desktop_drop)
printf 'checkout=%s\nplugin_source=%s\n' "$PWD" "$plugin_source" > "$diagnostic_root/evidence/hosted/native-provenance-hosted.txt"
sha256sum "$plugin_source/linux/desktop_drop_plugin.cc" "$plugin_source/lib/src/channel.dart" >> "$diagnostic_root/evidence/hosted/native-provenance-hosted.txt"
native_plugin=$(find app/build/linux/x64/release/bundle -name '*desktop_drop*.so' -print -quit)
sha256sum "$native_plugin" >> "$diagnostic_root/evidence/hosted/native-provenance-hosted.txt"
cp "$native_plugin" "$diagnostic_root/evidence/hosted/hosted-desktop-drop.so"
strings "$native_plugin" > "$diagnostic_root/evidence/hosted/native-strings-hosted.txt"
cp app/build/linux/x64/release/.ninja_log "$diagnostic_root/evidence/hosted/ninja-hosted.log"
git clone --recurse-submodules https://github.com/flathub/org.localsend.localsend_app "$build_root/manifest"
git -C "$build_root/manifest" checkout 1b93d4aed3c0867e95feb2d4022a3f6a6b232e7e
git -C "$build_root/manifest" rev-parse HEAD > "$diagnostic_root/evidence/hosted/flathub-source-sha.txt"
tar -C app/build/linux/x64/release/bundle -czf "$build_root/manifest/LocalSend.tar.gz" .
ruby -ryaml -e 'p=ARGV[0];m=YAML.load_file(p);s=m["modules"].last["sources"];s.reject!{|x|x["dest-filename"]=="LocalSend.tar.gz"};s.unshift({"type"=>"file","path"=>"LocalSend.tar.gz"});walk=lambda{|mods|mods.each{|x|next unless x.is_a?(Hash);if x["buildsystem"]=="cmake-ninja";(x["config-opts"]||=[])<<"-DCMAKE_INSTALL_LIBDIR=lib";end;walk.call(x["modules"]||[])}};walk.call(m["modules"]);File.write(p,m.to_yaml)' "$build_root/manifest/org.localsend.localsend_app.yml"
cp "$build_root/manifest/org.localsend.localsend_app.yml" "$diagnostic_root/evidence/hosted/manifest-hosted.yml"
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
sudo flatpak install -y flathub org.freedesktop.Sdk//26.08 org.freedesktop.Platform//26.08 org.freedesktop.Sdk.Extension.vala//26.08
(cd "$build_root/manifest" && flatpak-builder --force-clean --repo="$build_root/flatpak-repo" --default-branch=hosted "$build_root/flatpak-build" org.localsend.localsend_app.yml) > "$diagnostic_root/evidence/hosted/package-hosted.txt" 2>&1
flatpak build-bundle "$build_root/flatpak-repo" "$diagnostic_root/evidence/hosted/hosted.flatpak" org.localsend.localsend_app hosted
ostree --repo="$build_root/flatpak-repo" checkout --user-mode app/org.localsend.localsend_app/x86_64/hosted "$build_root/packaged"
packaged_plugin=$(find "$build_root/packaged/files" -name '*desktop_drop*.so' -print -quit)
sha256sum "$packaged_plugin" >> "$diagnostic_root/evidence/hosted/native-provenance-hosted.txt"
cp "$packaged_plugin" "$diagnostic_root/evidence/hosted/hosted-packaged-desktop-drop.so"
objcopy -O binary "$native_plugin" "$build_root/compiled.canonical"
objcopy -O binary "$packaged_plugin" "$build_root/packaged.canonical"
cmp "$build_root/compiled.canonical" "$build_root/packaged.canonical"
sha256sum "$build_root"/{compiled,packaged}.canonical >> "$diagnostic_root/evidence/hosted/native-provenance-hosted.txt"
readelf -n "$native_plugin" "$packaged_plugin" > "$diagnostic_root/evidence/hosted/native-build-id-hosted.txt"
readelf -l -S "$native_plugin" "$packaged_plugin" > "$diagnostic_root/evidence/hosted/native-load-layout-hosted.txt"
sha256sum "$diagnostic_root/evidence/hosted/hosted.flatpak" > "$diagnostic_root/evidence/hosted/package-sha256.txt"
