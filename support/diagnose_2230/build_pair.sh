#!/usr/bin/env bash
# Cloud-only preparation. This builds artifacts; it does not run either app.
set -Eeuo pipefail
evidence=${1:?Usage: build_pair.sh evidenceDir buildRoot}
build_root=${2:?buildRoot}
source_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
mkdir -p "$evidence/pair-build" "$build_root"
evidence=$(realpath "$evidence/pair-build")
build_root=$(realpath "$build_root")
[[ $(findmnt -n -T "$build_root" -o FSTYPE) == ext4 ]] || { echo 'Use Linux ext4 for buildRoot'; exit 1; }
exec > >(tee -a "$evidence/build-pair.log") 2>&1
active=toolchain
state=failed
trap 'printf "utc\tstate\tstage\n%s\t%s\t%s\n" "$(date -u --iso-8601=ns)" "$state" "$active" > "$evidence/build-state.tsv"' EXIT
for tool in git timeout sha256sum clang cmake ninja pkg-config rustup; do command -v "$tool"; done
pkg-config --modversion gtk+-3.0 ayatana-appindicator3-0.1 > "$evidence/native-dependencies.txt"
cat /etc/os-release > "$evidence/os-release.txt"
uname -a > "$evidence/kernel.txt"
# Parent installs the Linux build dependencies listed in linux_build.yml:
# clang cmake libgtk-3-dev ninja-build libayatana-appindicator3-dev.
run() {
  local label=$1 limit=$2; shift 2
  local rc=0
  local -a pipeline_codes
  printf '%s\t%s\tstart\n' "$(date -u --iso-8601=ns)" "$label" >> "$evidence/steps.tsv"
  if timeout --signal=TERM --kill-after=15s "${limit}s" "$@" 2>&1 | tee "$evidence/$label.log"; then
    rc=0
  else
    pipeline_codes=("${PIPESTATUS[@]}")
    rc=${pipeline_codes[0]}
    (( rc != 0 )) || rc=${pipeline_codes[1]}
  fi
  printf '%s\n' "$rc" > "$evidence/$label.exit"
  printf '%s\t%s\tend\t%s\n' "$(date -u --iso-8601=ns)" "$label" "$rc" >> "$evidence/steps.tsv"
  (( rc == 0 )) || return "$rc"
}
sdk="$build_root/flutter-3.41.9"
if [[ ! -d "$sdk" ]]; then
  run flutter-checkout 300 git clone --depth 1 --branch 3.41.9 https://github.com/flutter/flutter.git "$sdk"
fi
[[ $(git -C "$sdk" describe --tags --exact-match HEAD) == 3.41.9 ]]
git -C "$sdk" rev-parse HEAD > "$evidence/flutter-source.sha"
flutter="$sdk/bin/flutter"
dart="$sdk/bin/dart"
export PATH="$sdk/bin:$PATH"
export FLUTTER_SUPPRESS_ANALYTICS=true CI=true
run flutter-version 300 "$flutter" --version --machine
run flutter-linux-artifacts 600 "$flutter" precache --linux
# Cargokit at these refs explicitly invokes rustup run stable, overriding the
# nested 1.93.1 file. Install once, then verify the actual compiler stays fixed.
run rust-stable-install 600 rustup toolchain install stable --profile minimal --no-self-update
rustup run stable rustc -Vv > "$evidence/rust-stable.identity"
rustup run stable cargo -V >> "$evidence/rust-stable.identity"
sha256sum "$(rustup which --toolchain stable rustc)" > "$evidence/rustc.sha256"
parent=b13bbeb3cd0a9d9ec89f4cace28f2c144fa03084
fix=da4464def254223af4614687947c6eaf1d7a646a
[[ $(git -C "$source_root" rev-parse "$fix^") == "$parent" ]]
git -C "$source_root" diff "$parent" "$fix" > "$evidence/exact-candidate.diff"
locks() {
  local destination=$1
  git ls-files '*Cargo.lock' '*pubspec.lock' | while IFS= read -r file; do sha256sum "$file"; done > "$destination"
}
for label in parent fix; do
  active=$label
  ref=$parent; [[ "$label" != fix ]] || ref=$fix
  checkout="$build_root/$label-$ref"
  [[ ! -e "$checkout" ]] || { echo "Refuse to overwrite $checkout"; exit 1; }
  run "$label-checkout" 300 git clone --no-hardlinks --no-checkout "$source_root" "$checkout"
  run "$label-detach" 60 git -C "$checkout" checkout --detach "$ref"
  mkdir -p "$evidence/$label"
  git -C "$checkout" rev-parse HEAD > "$evidence/$label/source.sha"
  [[ $(cat "$evidence/$label/source.sha") == "$ref" ]]
  cd "$checkout"
  cp .fvmrc "$evidence/$label/fvmrc.json"
  cp packages/localsend_isolates/rust-toolchain.toml "$evidence/$label/declared-rust-toolchain.toml"
  locks "$evidence/$label/locks-before.sha256"
  git status --porcelain > "$evidence/$label/status-before.txt"
  [[ ! -s "$evidence/$label/status-before.txt" ]]
  rustup run stable rustc -Vv > "$evidence/$label/rust-stable.identity"
  rustup run stable cargo -V >> "$evidence/$label/rust-stable.identity"
  cmp "$evidence/rust-stable.identity" "$evidence/$label/rust-stable.identity"
  # Keep each checkout's committed FRB bindings; ordinary model/asset codegen
  # follows the supported Linux workflow and its complete diff is retained.
  cd "$checkout/packages/localsend_isolates"
  run "$label-isolates-pub-get" 600 "$flutter" pub get --enforce-lockfile
  cd "$checkout/packages/localsend_isolates/rust_builder/cargokit/build_tool"
  run "$label-cargokit-pub-get" 600 "$flutter" pub get --enforce-lockfile
  cd "$checkout/app"
  run "$label-app-pub-get" 600 "$flutter" pub get --enforce-lockfile
  run "$label-codegen" 600 "$dart" run build_runner build -d
  git -C "$checkout" diff --binary > "$evidence/$label/after-codegen.diff"
  git -C "$checkout" diff --exit-code -- packages/localsend_isolates/lib/rust packages/localsend_isolates/rust/src/frb_generated.rs
  run "$label-build-linux" 2400 "$flutter" build linux --release
  cd "$checkout"
  locks "$evidence/$label/locks-after.sha256"
  cmp "$evidence/$label/locks-before.sha256" "$evidence/$label/locks-after.sha256"
  git diff --binary > "$evidence/$label/after-build.diff"
  git status --porcelain > "$evidence/$label/status-after.txt"
  rustup run stable rustc -Vv > "$evidence/$label/rust-after.identity"
  rustup run stable cargo -V >> "$evidence/$label/rust-after.identity"
  cmp "$evidence/rust-stable.identity" "$evidence/$label/rust-after.identity"
  sha256sum "$(rustup which --toolchain stable rustc)" > "$evidence/$label/rustc-after.sha256"
  cmp "$evidence/rustc.sha256" "$evidence/$label/rustc-after.sha256"
  bundle="$checkout/app/build/linux/x64/release/bundle"
  [[ -f "$bundle/localsend_app" && -x "$bundle/localsend_app" && -d "$bundle/lib" && -d "$bundle/data" ]]
  cp -a "$bundle" "$evidence/$label/bundle"
  (cd "$evidence/$label/bundle" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$evidence/$label/bundle-files.sha256"
  sha256sum "$evidence/$label/bundle/localsend_app" > "$evidence/$label/executable.sha256"
  printf 'ready\t%s\t%s\n' "$(date -u --iso-8601=ns)" "$ref" > "$evidence/$label/build-ready.tsv"
done
active=complete
state=prepared
