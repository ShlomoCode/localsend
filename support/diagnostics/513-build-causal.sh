#!/bin/bash
# Cloud-only source builds and initial Flatpak assembly; no completed bundle edits.
set -euo pipefail
diagnostic_root=$PWD
mkdir -p evidence/causal /home/runner/513-build
build_root=/home/runner/513-build
git clone https://github.com/ShlomoCode/localsend "$build_root/source"
git -C "$build_root/source" checkout c1ce322fb3acf08e44f329b8b7208b8b0d91e244
git clone https://github.com/MixinNetwork/flutter-plugins "$build_root/plugins"
git -C "$build_root/plugins" checkout 2ef30a7e96c185c926a7a2d210fc5f6b7d803248
git -C "$build_root/plugins" diff af1fb55a82eab1912e6bb8a11d5bf284f7ed687d^ af1fb55a82eab1912e6bb8a11d5bf284f7ed687d -- packages/desktop_drop/lib packages/desktop_drop/linux > "$build_root/portal.patch"
cp -a "$build_root/plugins/packages/desktop_drop" "$build_root/drop-positive"
git -C "$build_root/plugins" apply -R "$build_root/portal.patch"
cp -a "$build_root/plugins/packages/desktop_drop" "$build_root/drop-negative"
# These two standalone path overrides retain identical dependencies and version.
sed -i '/^resolution: workspace$/d' "$build_root"/drop-{positive,negative}/pubspec.yaml
cp "$build_root/portal.patch" evidence/causal/isolated-portal.patch
diff -u "$build_root/drop-negative/pubspec.yaml" "$build_root/drop-positive/pubspec.yaml" > evidence/causal/plugin-pubspec-equality.txt
git clone --recurse-submodules https://github.com/flathub/org.localsend.localsend_app "$build_root/flathub"
git -C "$build_root/flathub" rev-parse HEAD > evidence/causal/flathub-source-sha.txt
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
sudo flatpak install -y flathub org.freedesktop.Sdk//26.08 org.freedesktop.Platform//26.08 org.freedesktop.Sdk.Extension.vala//26.08
cd "$build_root/source"
fvm use 3.41.9 --skip-pub-get
fvm flutter --version > "$diagnostic_root/evidence/causal/sdk.txt"
cp app/pubspec.yaml "$build_root/app-pubspec.original"
cp pubspec.lock "$build_root/lock.original"
for condition in normal negative positive; do
  # Each native intervention gets its own checkout, CMake cache and objects.
  # Switching symlink targets in an existing build can reuse older plugin objects.
  git -C "$build_root/source" worktree add --detach "$build_root/source-$condition" c1ce322fb3acf08e44f329b8b7208b8b0d91e244
  cd "$build_root/source-$condition"
  fvm use 3.41.9 --skip-pub-get
  cp "$build_root/app-pubspec.original" app/pubspec.yaml
  cp "$build_root/lock.original" pubspec.lock
  if [[ "$condition" != normal ]]; then
    sed -i "/^dependency_overrides:/a\  desktop_drop:\n    path: $build_root/drop-$condition" app/pubspec.yaml
  fi
  (cd app && fvm flutter pub get && fvm flutter build linux --release) > "$diagnostic_root/evidence/causal/build-$condition.txt" 2>&1
  cp pubspec.lock "$diagnostic_root/evidence/causal/lock-$condition.yaml"
  git diff > "$diagnostic_root/evidence/causal/source-diff-$condition.patch"
  plugin_source=$(realpath app/linux/flutter/ephemeral/.plugin_symlinks/desktop_drop)
  printf 'checkout=%s\nplugin_source=%s\n' "$PWD" "$plugin_source" > "$diagnostic_root/evidence/causal/native-provenance-$condition.txt"
  sha256sum "$plugin_source/linux/desktop_drop_plugin.cc" "$plugin_source/lib/src/channel.dart" >> "$diagnostic_root/evidence/causal/native-provenance-$condition.txt"
  native_plugin=$(find app/build/linux/x64/release/bundle -name '*desktop_drop*.so' -print -quit)
  sha256sum "$native_plugin" >> "$diagnostic_root/evidence/causal/native-provenance-$condition.txt"
  cp "$native_plugin" "$diagnostic_root/evidence/causal/$condition-desktop-drop.so"
  strings "$native_plugin" > "$diagnostic_root/evidence/causal/native-strings-$condition.txt"
  cp app/build/linux/x64/release/.ninja_log "$diagnostic_root/evidence/causal/ninja-$condition.log"
  manifest_root="$build_root/manifest-$condition"
  cp -a "$build_root/flathub" "$manifest_root"
  tar -C app/build/linux/x64/release/bundle -czf "$manifest_root/LocalSend.tar.gz" .
  # Retain the supported Flathub modules/permissions; change only tar input.
  # SDK26 CMake defaults to lib64; the supported /app prefix expects lib.
  ruby -ryaml -e 'p=ARGV[0];m=YAML.load_file(p);s=m["modules"].last["sources"];s.reject!{|x|x["dest-filename"]=="LocalSend.tar.gz"};s.unshift({"type"=>"file","path"=>"LocalSend.tar.gz"});walk=lambda{|mods|mods.each{|x|next unless x.is_a?(Hash);if x["buildsystem"]=="cmake-ninja";(x["config-opts"]||=[])<<"-DCMAKE_INSTALL_LIBDIR=lib";end;walk.call(x["modules"]||[])}};walk.call(m["modules"]);File.write(p,m.to_yaml)' "$manifest_root/org.localsend.localsend_app.yml"
  cp "$manifest_root/org.localsend.localsend_app.yml" "$diagnostic_root/evidence/causal/manifest-$condition.yml"
  (cd "$manifest_root" && flatpak-builder --force-clean --repo="$build_root/flatpak-repo" --default-branch="$condition" "$build_root/flatpak-build" org.localsend.localsend_app.yml) > "$diagnostic_root/evidence/causal/package-$condition.txt" 2>&1
  flatpak build-bundle "$build_root/flatpak-repo" "$diagnostic_root/evidence/causal/$condition.flatpak" org.localsend.localsend_app "$condition"
  ostree --repo="$build_root/flatpak-repo" checkout --user-mode "app/org.localsend.localsend_app/x86_64/$condition" "$build_root/packaged-$condition"
  packaged_plugin=$(find "$build_root/packaged-$condition/files" -name '*desktop_drop*.so' -print -quit)
  sha256sum "$packaged_plugin" >> "$diagnostic_root/evidence/causal/native-provenance-$condition.txt"
  cp "$packaged_plugin" "$diagnostic_root/evidence/causal/$condition-packaged-desktop-drop.so"
  # Supported Flatpak packaging strips debug sections and adds .gnu_debuglink.
  # Compare executable/data content after removing those non-runtime sections.
  objcopy --strip-all --remove-section=.gnu_debuglink "$native_plugin" "$build_root/compiled-$condition.canonical.so"
  objcopy --strip-all --remove-section=.gnu_debuglink "$packaged_plugin" "$build_root/packaged-$condition.canonical.so"
  cmp "$build_root/compiled-$condition.canonical.so" "$build_root/packaged-$condition.canonical.so"
  sha256sum "$build_root"/{compiled,packaged}-"$condition".canonical.so >> "$diagnostic_root/evidence/causal/native-provenance-$condition.txt"
  readelf -n "$native_plugin" "$packaged_plugin" > "$diagnostic_root/evidence/causal/native-build-id-$condition.txt"
done
sha256sum "$diagnostic_root"/evidence/causal/*.flatpak > "$diagnostic_root/evidence/causal/package-sha256.txt"
