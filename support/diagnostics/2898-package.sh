#!/usr/bin/env bash
set -Eeuo pipefail
E="$GITHUB_WORKSPACE/evidence/cloud/packages"
mkdir -p "$E"
cd /tmp/issue2754-build
sha256sum -c source-bundle.tar.gz.sha256
[ "$(cat provenance/source-sha.txt)" = c1ce322fb3acf08e44f329b8b7208b8b0d91e244 ]
grep -qx exit_status=0 provenance/build-result.txt
cmp provenance/lock-hashes-before.txt provenance/lock-hashes-after.txt
test ! -s provenance/source-diff-after.patch
cp -a provenance "$E/source-build-provenance"
cp source-bundle.tar.gz.sha256 "$E/"
cd "$GITHUB_WORKSPACE/source/app"
mkdir -p build/linux/x64/release/bundle
tar -xzf /tmp/issue2754-build/source-bundle.tar.gz -C build/linux/x64/release/bundle
find build/linux/x64/release/bundle -maxdepth 2 -type f | head -40 > "$E/bundle-file-layout.txt"
mkdir -p /tmp/issue2898-packager
cat > /tmp/issue2898-packager/pubspec.yaml <<PACKAGER
name: issue2898_packager
environment:
  sdk: "^3.10.0"
dependencies:
  flutter_app_packager: 0.6.11
  unified_distributor: 0.2.12
PACKAGER
(cd /tmp/issue2898-packager && dart pub get) > "$E/packager-pub-get.log" 2>&1
cp /tmp/issue2898-packager/pubspec.lock "$E/packager-pubspec.lock"
git -C "$GITHUB_WORKSPACE/source" rev-parse HEAD > "$E/packaging-source-sha.txt"
cp linux/packaging/deb/make_config.yaml "$E/candidate-config.yaml"
sed -i "s/^  - libayatana-appindicator3-1$/  - libappindicator3-1 | libayatana-appindicator3-1/" linux/packaging/deb/make_config.yaml
cp linux/packaging/deb/make_config.yaml "$E/baseline-config.yaml"
dart --packages=/tmp/issue2898-packager/.dart_tool/package_config.json "$GITHUB_WORKSPACE/support/diagnostics/2898-packager.dart" 2>&1 | tee "$E/current-baseline-package.log"
find dist -name "*.deb" -exec cp {} "$E/current-baseline.deb" \;
test -f "$E/current-baseline.deb"
rm -rf dist
cp "$E/candidate-config.yaml" linux/packaging/deb/make_config.yaml
dart --packages=/tmp/issue2898-packager/.dart_tool/package_config.json "$GITHUB_WORKSPACE/support/diagnostics/2898-packager.dart" 2>&1 | tee "$E/current-candidate-package.log"
find dist -name "*.deb" -exec cp {} "$E/current-candidate.deb" \;
test -f "$E/current-candidate.deb"
for variant in current-baseline current-candidate; do
  dpkg-deb -I "$E/$variant.deb" > "$E/$variant-metadata.txt"
  mkdir -p "$E/$variant-payload"
  dpkg-deb -x "$E/$variant.deb" "$E/$variant-payload"
  (cd "$E/$variant-payload" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$E/$variant-payload-hashes.txt"
done
cmp "$E/current-baseline-payload-hashes.txt" "$E/current-candidate-payload-hashes.txt"
# Repack the historical release payload; record this separately from the source-built current package.
curl -L --fail --retry 3 https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.deb -o "$E/release-baseline.deb"
dpkg-deb -R "$E/release-baseline.deb" /tmp/issue2898-release-candidate
sed -i "s/libappindicator3-1 | libayatana-appindicator3-1/libayatana-appindicator3-1/" /tmp/issue2898-release-candidate/DEBIAN/control
dpkg-deb --build /tmp/issue2898-release-candidate "$E/release-candidate.deb"
for variant in release-baseline release-candidate; do
  dpkg-deb -I "$E/$variant.deb" > "$E/$variant-metadata.txt"
  mkdir -p "$E/$variant-payload"
  dpkg-deb -x "$E/$variant.deb" "$E/$variant-payload"
  (cd "$E/$variant-payload" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$E/$variant-payload-hashes.txt"
done
cmp "$E/release-baseline-payload-hashes.txt" "$E/release-candidate-payload-hashes.txt"
sha256sum "$E/"*.deb > "$E/package-hashes.txt"
rm -rf "$E/"*-payload
