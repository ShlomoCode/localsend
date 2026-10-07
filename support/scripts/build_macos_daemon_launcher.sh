#!/usr/bin/env bash
set -euo pipefail

# Build the native receiver independently of Flutter. The UI app is a runtime
# argument; this bundle neither links nor starts a Flutter engine.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$repo_root/build/daemon-launcher}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
cd "$repo_root"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$output/cargo}"
metadata="$(cargo metadata --no-deps --format-version 1)"
target_directory="$(printf '%s' "$metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
log="$output/rust-link.log"
if ! cargo rustc -p localsend-daemon --lib -- --print native-static-libs >"$log" 2>&1; then
  cat "$log" >&2
  exit 1
fi
# rustc supplies the complete native dependency list for this host and crate.
native_libs="$(sed -n 's/.*native-static-libs: //p' "$log" | tail -n 1)"
if [[ -z "$native_libs" ]]; then
  echo "rustc did not provide native-static-libs; see $log" >&2
  exit 1
fi
read -r -a link_flags <<< "$native_libs"
bundle="$output/LocalSend Receiver.app"
mkdir -p "$bundle/Contents/MacOS"
cp app/macos/Launcher/Info.plist "$bundle/Contents/Info.plist"
MACOSX_DEPLOYMENT_TARGET=12.0 xcrun swiftc \
  app/macos/Launcher/DaemonIPC.swift app/macos/Launcher/main.swift \
  -import-objc-header packages/daemon/include/localsend_daemon.h \
  -module-cache-path "$output/swift-module-cache" \
  -framework AppKit -framework Security \
  "$target_directory/debug/liblocalsend_daemon.a" "${link_flags[@]}" \
  -o "$bundle/Contents/MacOS/LocalSendLauncher"

# Opt in with an actual signing identity for sandbox validation. The default
# development bundle remains unsigned to accept explicit config/UI paths.
if [[ -n "${LOCALSEND_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$LOCALSEND_SIGN_IDENTITY" \
    --entitlements app/macos/Launcher/Launcher.entitlements "$bundle"
fi
printf 'Built %s\n' "$bundle"
printf 'Development receive prototype: explicit config and UI paths; signed cross-app IPC is not yet supported.\n'
printf 'Run: "%s/Contents/MacOS/LocalSendLauncher" --config /absolute/daemon.json --ui-app /absolute/LocalSend.app\n' "$bundle"
printf 'Sandbox Downloads check: "%s/Contents/MacOS/LocalSendLauncher" --verify-downloads-only\n' "$bundle"
