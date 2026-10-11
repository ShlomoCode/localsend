#!/usr/bin/env bash
# Manual cloud build only. Build success does not establish issue causality.
set -euo pipefail
parent=165d7fe3f90bba1f0c44c2e8dc9b21b8a64d8a88
fix=76a356a2dd12404d2ce482b8b6aa4cf3afc7b6be
current=e768240d1ad95f0f162b852b5ff37bec71cde1ef
root="$GITHUB_WORKSPACE"
source_dir="$root/source"
out="$root/artifacts"
mkdir -p "$out"
case "$REVISION" in
  pair) labels=(parent fix); refs=("$parent" "$fix"); rust=1.93.1 ;;
  current) labels=(current); refs=("$current"); rust=1.97.1 ;;
  *) echo "Unsupported revision: $REVISION" >&2; exit 1 ;;
esac
if [[ "$1" == select ]]; then
  git clone --no-checkout https://github.com/ShlomoCode/localsend.git "$source_dir"
  git -C "$source_dir" checkout --detach "${refs[0]}"
  flutter=$(jq -r .flutter "$source_dir/.fvmrc")
  [[ "$flutter" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  echo "flutter=$flutter" >> "$GITHUB_OUTPUT"
  if [[ "$REVISION" == pair ]]; then
    # Only the two candidate UI files may differ in the controlled pair.
    git -C "$source_dir" diff --name-only "$parent" "$fix" > "$out/pair-source-differences.txt"
    printf '%s\n' app/lib/pages/receive_options_page.dart app/lib/widget/responsive_list_view.dart > "$out/expected-pair-differences.txt"
    diff -u "$out/expected-pair-differences.txt" "$out/pair-source-differences.txt"
    [[ "$(git -C "$source_dir" show "$fix:.fvmrc" | jq -r .flutter)" == "$flutter" ]]
  fi
  exit 0
fi
[[ "$1" == build ]]
rustup toolchain install "$rust" --profile minimal
export RUSTUP_TOOLCHAIN="$rust"
{
  printf 'selection=%s\nrunner=%s\nimage=%s\nimage_version=%s\n' "$REVISION" "$RUNNER_OS/$RUNNER_ARCH" "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
  uname -a
  cat /etc/os-release
  flutter --version --machine
  rustc -Vv
  cargo -V
  clang --version
  cmake --version
  ninja --version
  dpkg-query -W clang cmake libgtk-3-dev ninja-build libayatana-appindicator3-dev
} > "$out/environment.txt"
for i in "${!refs[@]}"; do
  label="${labels[$i]}"
  ref="${refs[$i]}"
  dest="$out/$label"
  mkdir -p "$dest/runtime-locks"
  git -C "$source_dir" reset --hard
  git -C "$source_dir" clean -ffdx
  git -C "$source_dir" checkout --detach "$ref"
  [[ "$(git -C "$source_dir" rev-parse HEAD)" == "$ref" ]]
  [[ "$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$source_dir/packages/localsend_isolates/rust-toolchain.toml")" == "$rust" ]]
  {
    printf 'label=%s\nsource_sha=%s\nsource_tree=%s\n' "$label" "$ref" "$(git -C "$source_dir" rev-parse HEAD^{tree})"
    printf 'application_version=%s\n' "$(sed -n 's/^version: //p' "$source_dir/app/pubspec.yaml")"
    printf 'flutter_pin=%s\nrust_pin=%s\n' "$(jq -r .flutter "$source_dir/.fvmrc")" "$rust"
    echo 'artifact_kind=rebuilt source diagnostic; not the published 1.17 release'
    echo 'codegen=committed generated sources; no build_runner or FRB regeneration'
  } > "$dest/identity.txt"
  # Record committed locks in both pre-workspace and pub-workspace layouts.
  (cd "$source_dir"; git ls-files '*pubspec.lock' Cargo.lock | xargs sha256sum) > "$dest/committed-locks-before.txt"
  # Cargokit creates a runner in build/. Seed its resolved lock in the second
  # variant at the same absolute path, without editing tracked source files.
  if [[ "$label" == fix ]]; then
    cp -a "$out/parent/runtime-locks/." "$source_dir/"
  fi
  trap 'git -C "$source_dir" diff --binary > "$dest/source-after-build.diff"; git -C "$source_dir" status --short > "$dest/source-after-build.status"' EXIT
  (cd "$source_dir/app"; flutter pub get --enforce-lockfile) 2>&1 | tee "$dest/pub-get.log"
  (cd "$source_dir"; cargo fetch --locked --manifest-path packages/localsend_isolates/rust/Cargo.toml) 2>&1 | tee "$dest/cargo-fetch.log"
  (cd "$source_dir/app"; CARGO_NET_OFFLINE=true flutter build linux --release) 2>&1 | tee "$dest/build.log"
  git -C "$source_dir" diff --binary > "$dest/source-after-build.diff"
  git -C "$source_dir" status --short > "$dest/source-after-build.status"
  (cd "$source_dir"; git ls-files '*pubspec.lock' Cargo.lock | xargs sha256sum) > "$dest/committed-locks-after.txt"
  diff -u "$dest/committed-locks-before.txt" "$dest/committed-locks-after.txt"
  git -C "$source_dir" diff --exit-code
  # Retain and compare the dynamically resolved Cargokit lock byte-for-byte.
  (cd "$source_dir"; find app/build -name pubspec.lock -type f -exec cp --parents '{}' "$dest/runtime-locks/" \;)
  (cd "$source_dir"; find app/build -name pubspec.lock -type f -print0 | sort -z | xargs -0 -r sha256sum) > "$dest/runtime-locks.txt"
  if [[ "$label" == fix ]]; then
    diff -u "$out/parent/committed-locks-before.txt" "$dest/committed-locks-before.txt"
    diff -u "$out/parent/runtime-locks.txt" "$dest/runtime-locks.txt"
  fi
  tar -czf "$dest/localsend-source-$label-$ref-linux-x86-64.tar.gz" -C "$source_dir/app/build/linux/x64/release/bundle" .
  (cd "$dest"; sha256sum *.tar.gz > SHA256SUMS)
  trap - EXIT
done
