#!/usr/bin/env bash
# Cloud-only native source gate. Do not run on the LocalSend development host.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  echo 'This native build/test gate is restricted to GitHub Actions.' >&2
  exit 2
fi

if [[ $# != 1 ]]; then
  echo "Usage: $0 OUTPUT_DIR" >&2
  exit 2
fi

assets=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$1"
output=$(cd "$1" && pwd)
if [[ -e "$output/run-started" ]]; then
  echo "Refusing to reuse a native-gate output directory: $output" >&2
  exit 2
fi
touch "$output/run-started"
exec > >(tee "$output/gate.log") 2>&1
trap 'result=$?; printf "%s\n" "$result" > "$output/exit-code.txt"' EXIT

pin=42d3d75a56efe1a2e9902f52dc8006099c45d937
gtest_pin=7f036c5563af7d0329f20e8bb42effb04629f0c0
gtest_hash=a888ce3e5b5f174415c3cf99c9364489fd386c3d4ed672a94c528a6cf6b160ed
gtest_root="$output/googletest-$gtest_pin"
source_root="$output/stock-source"
candidate_root="$output/candidate-source"
linux_path=engine/src/flutter/shell/platform/linux
base="https://raw.githubusercontent.com/flutter/flutter/$pin/$linux_path"

for command in curl sha256sum git g++ pkg-config xvfb-run xauth awk timeout tar; do
  command -v "$command" >/dev/null
done
pkg-config --exists gtk+-3.0

printf 'Flutter 3.41.9 source pin: %s\n' "$pin"
printf 'GoogleTest Flutter DEPS revision: %s\n' "$gtest_pin"
printf 'Fixture only: Xvfb, system GTK/ATK, standalone native binary. No app/UI claim.\n'
uname -a > "$output/environment.txt"
g++ --version >> "$output/environment.txt"
pkg-config --modversion gtk+-3.0 atk >> "$output/environment.txt"
dpkg-query -W libgtk-3-0t64 libgtk-3-dev libatk1.0-0t64 \
  >> "$output/environment.txt" 2>&1 || true

mkdir -p "$source_root/$linux_path/testing"
download() {
  local path=$1 hash=$2
  curl --fail --location --silent --show-error --retry 3 \
    "$base/$path" -o "$source_root/$linux_path/$path"
  printf '%s  %s\n' "$hash" "$source_root/$linux_path/$path" | sha256sum --check -
  printf '%s  %s\n' "$hash" "$linux_path/$path" >> "$output/pinned-source-SHA256SUMS"
}
download fl_socket_accessible.cc d178f01498278cd79f9f4f61d51de6620c9af08fe8e8b5aa75c6a465057cd75b
download fl_socket_accessible.h 779ffe70f651beb4dee76dbf4b8551a1e5d55257ba056629353c225fe0315735
download testing/fl_test_gtk_logs.h 6cc46c435c7e888b0fd65065824291fb51481b47f7793c37afffc480b568caaf
download testing/fl_test_gtk_logs.cc b151551c9247119115bfd89b9e4f2d9e122ccafb4d2cc6ef9692e7c7eb5d6d59

curl --fail --location --silent --show-error --retry 3 \
  "https://raw.githubusercontent.com/flutter/flutter/$pin/DEPS" \
  -o "$output/flutter-DEPS"
printf '%s  %s\n' \
  0d0b2b9c4b103613bb242635328497bc8a47d64f31309f2dfa93e66abb20d4f3 \
  "$output/flutter-DEPS" | sha256sum --check -

gtest_archive="$output/googletest-$gtest_pin.tar.gz"
curl --fail --location --silent --show-error --retry 3 \
  "https://codeload.github.com/google/googletest/tar.gz/$gtest_pin" \
  -o "$gtest_archive"
printf '%s  %s\n' "$gtest_hash" "$gtest_archive" | sha256sum --check -
tar -xzf "$gtest_archive" -C "$output"
printf '%s\n' "$gtest_pin" > "$output/googletest-revision.txt"
printf '%s  %s\n' "$gtest_hash" "googletest-$gtest_pin.tar.gz" \
  > "$output/googletest-archive-SHA256SUMS"
find "$gtest_root/googletest" -type f -print0 | sort -z | xargs -0 sha256sum \
  > "$output/googletest-source-SHA256SUMS"

(cd "$assets" && sha256sum --check assets-SHA256SUMS)
cp "$assets/fl_socket_accessible_test.cc" "$source_root/$linux_path/"
cp -a "$source_root" "$candidate_root"
git -C "$candidate_root" apply --check "$assets/flutter-parent-production.patch"
git -C "$candidate_root" apply "$assets/flutter-parent-production.patch"
cp "$assets/flutter-parent-production.patch" "$output/"
cp "$assets/assets-SHA256SUMS" "$output/"

# Use the exact pinned initializer implementation. No Flutter/GTK behavior shim
# and no mock_gtk.cc are linked. These are the same five regression test bodies
# prepared for flutter_linux_unittests, with controlled host geometry.
read -r -a gtk_flags <<< "$(pkg-config --cflags gtk+-3.0)"
read -r -a link_flags <<< "$(pkg-config --libs gtk+-3.0)"
compile_fixture() {
  local tree=$1 binary=$2
  g++ -std=c++17 -g -O0 -Wall -Wextra -I "$tree/engine/src" \
    -I "$gtest_root/googletest/include" -I "$gtest_root/googletest" \
    "${gtk_flags[@]}" \
    "$tree/$linux_path/fl_socket_accessible.cc" \
    "$tree/$linux_path/fl_socket_accessible_test.cc" \
    "$tree/$linux_path/testing/fl_test_gtk_logs.cc" \
    "$gtest_root/googletest/src/gtest-all.cc" \
    "$gtest_root/googletest/src/gtest_main.cc" \
    "${link_flags[@]}" -pthread -o "$binary"
}
compile_fixture "$source_root" "$output/stock-native-tests" \
  2>&1 | tee "$output/stock-build.log"
compile_fixture "$candidate_root" "$output/candidate-native-tests" \
  2>&1 | tee "$output/candidate-build.log"
sha256sum "$output/stock-native-tests" "$output/candidate-native-tests" \
  > "$output/binary-SHA256SUMS"
find "$candidate_root" -type f -print0 | sort -z | xargs -0 sha256sum \
  > "$output/candidate-source-SHA256SUMS"

set +e
timeout 60s xvfb-run -a "$output/stock-native-tests" \
  --gtest_filter=FlSocketAccessibleTest.ChildHasHostParent:FlSocketAccessibleTest.ForwardsLiveHostGeometry \
  --gtest_output="xml:$output/stock-native.xml" \
  > "$output/stock-native.log" 2>&1
stock_status=$?
set -e
cat "$output/stock-native.log"
printf '%s\n' "$stock_status" > "$output/stock-exit-code.txt"
if [[ $stock_status != 1 ]]; then
  echo "Stock control must report ordinary gtest failures (exit 1), not pass or crash." >&2
  exit 1
fi
awk '/<testsuite name="FlSocketAccessibleTest"/ {
  if ($0 ~ /tests="2"/ && $0 ~ /failures="2"/ && $0 ~ /errors="0"/) found=1
} END { exit !found }' "$output/stock-native.xml"

timeout 60s xvfb-run -a "$output/candidate-native-tests" \
  --gtest_filter=FlSocketAccessibleTest.* \
  --gtest_output="xml:$output/candidate-native.xml" \
  2>&1 | tee "$output/candidate-native.log"
awk '/<testsuite name="FlSocketAccessibleTest"/ {
  if ($0 ~ /tests="5"/ && $0 ~ /failures="0"/ && $0 ~ /errors="0"/ && $0 ~ /skipped="0"/) found=1
} END { exit !found }' "$output/candidate-native.xml"
printf 'Stock parent/geometry negative controls failed as expected; all five candidate native tests passed.\n' \
  | tee "$output/result.txt"
