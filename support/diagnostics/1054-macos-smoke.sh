#!/usr/bin/env bash
# Cloud-only capability observation. Do not change TCC or the original app.
set -euo pipefail
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  printf 'This diagnostic may run only in the approved cloud Actions job.\n' >&2
  exit 2
fi
evidence="$GITHUB_WORKSPACE/evidence/macos-smoke"
scratch="$RUNNER_TEMP/issue1054-macos-smoke"
mkdir -p "$evidence" "$scratch"
mount="$scratch/mount"
app_pid=''
cleanup() {
  if [ -n "$app_pid" ]; then kill "$app_pid" 2>/dev/null || true; fi
  hdiutil detach "$mount" > "$evidence/detach.txt" 2>&1 || true
}
trap cleanup EXIT
# BSD macOS has no timeout executable. Bound each command and retain its status.
observe() {
  local label="$1" seconds="$2" child start code
  shift 2
  "$@" > "$evidence/$label.stdout.txt" 2> "$evidence/$label.stderr.txt" &
  child=$!; start=$SECONDS
  while kill -0 "$child" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$seconds" ]; then
      kill "$child" 2>/dev/null || true
      sleep 1
      kill -9 "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      printf '124\n' > "$evidence/$label.exit-code.txt"
      return 0
    fi
    sleep 1
  done
  code=0; wait "$child" || code=$?
  printf '%s\n' "$code" > "$evidence/$label.exit-code.txt"
}
cat > "$evidence/scope.txt" <<'EOF'
Issue 1054 comment 2260628784 (2024-07-31) specifies Windows 10 to macOS;
the application version and macOS version are unspecified. Official 1.15.3
was published 2024-07-29 and is a date-eligible control, not an asserted
reporter version. This is only a macOS GUI and permission capability smoke.
There is no Windows peer, transfer, mutation, or reproduction in this run.
No TCC database changes, application patches, or signing modifications.
EOF
git rev-parse HEAD > "$evidence/harness-commit.txt"
git status --porcelain > "$evidence/harness-status.txt"
printf '%s\n' "${GITHUB_RUN_ID:-}" "${GITHUB_RUN_ATTEMPT:-}" "${RUNNER_NAME:-}" "${ImageOS:-}" "${ImageVersion:-}" > "$evidence/runner.txt"
observe os 10 sw_vers
observe architecture 10 uname -a
observe console 10 stat -f '%Su' /dev/console
observe processes-before 10 ps -axo pid,ppid,uid,comm
observe gui-session 10 launchctl print "gui/$(id -u)"
observe sip 10 csrutil status
observe desktop-before 15 screencapture -x "$evidence/desktop-before.png"
observe system-events-before 15 osascript -e 'tell application "System Events" to get {name, unix id} of every process'
url='https://github.com/localsend/localsend/releases/download/v1.15.3/LocalSend-1.15.3.dmg'
printf '%s\n' "$url" > "$evidence/artifact-url.txt"
curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 --dump-header "$evidence/download-headers.txt" "$url" -o "$scratch/LocalSend-1.15.3.dmg"
shasum -a 256 "$scratch/LocalSend-1.15.3.dmg" > "$evidence/download.sha256"
mkdir -p "$mount"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$scratch/LocalSend-1.15.3.dmg" > "$evidence/attach.txt" 2>&1
original=$(find "$mount" -maxdepth 2 -name LocalSend.app -type d -print -quit)
test -n "$original"
ditto "$original" "$scratch/LocalSend.app"
app="$scratch/LocalSend.app"
info="$app/Contents/Info.plist"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")
plutil -convert json -o "$evidence/app-info.json" "$info"
observe signature 15 codesign -dv --verbose=4 "$app"
observe signature-verify 15 codesign --verify --deep --strict --verbose=2 "$app"
if [ "$(cat "$evidence/signature-verify.exit-code.txt")" != 0 ]; then
  printf 'Official application signature verification failed; launch withheld.\n' > "$evidence/installation-failure.txt"
  exit 1
fi
observe entitlements 15 codesign -d --entitlements :- "$app"
shasum -a 256 "$app/Contents/MacOS/$executable" > "$evidence/executable.sha256"
printf '%s\n' "$bundle" "$executable" > "$evidence/app-identity.txt"
observe app-launch 15 open -n -a "$app"
if [ "$(cat "$evidence/app-launch.exit-code.txt")" != 0 ]; then
  printf 'Launch Services rejected the original application.\n' > "$evidence/installation-failure.txt"
  exit 1
fi
sleep 8
observe processes-after 10 ps -axo pid,ppid,uid,comm
cat > "$scratch/windows.swift" <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
let bundle = CommandLine.arguments[1]
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
let pids = Set(apps.map { $0.processIdentifier })
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
  guard let pid = $0[kCGWindowOwnerPID as String] as? Int32, let layer = $0[kCGWindowLayer as String] as? Int else { return false }
  return pids.contains(pid) && layer == 0
}
let output: [String: Any] = [
  "bundleIdentifier": bundle,
  "applications": apps.map { ["pid": $0.processIdentifier, "executable": $0.executableURL?.path ?? "", "terminated": $0.isTerminated] as [String: Any] },
  "windows": windows.map { ["id": $0[kCGWindowNumber as String] ?? 0, "title": $0[kCGWindowName as String] ?? "", "bounds": $0[kCGWindowBounds as String] ?? [:]] },
  "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
  "accessibilityTrusted": AXIsProcessTrusted()
]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
SWIFT
observe native-window-observation 40 swift "$scratch/windows.swift" "$bundle"
observe launched-app-pid 10 env WINDOW_JSON="$evidence/native-window-observation.stdout.txt" osascript -l JavaScript -e 'ObjC.import("Foundation"); const p=ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey("WINDOW_JSON")); const a=JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p,4,null))); if(a.applications.length) a.applications[0].pid;'
app_pid=$(tr -d '[:space:]' < "$evidence/launched-app-pid.stdout.txt")
if ! [[ "$app_pid" =~ ^[0-9]+$ ]]; then app_pid=''; fi
printf '%s\n' "$app_pid" > "$evidence/launch-pid.txt"
observe app-unified-log 20 log show --last 2m --style compact --predicate "process == \"$executable\""
cat > "$scratch/app-ui.applescript" <<'APPLESCRIPT'
on run argv
  set targetBundle to item 1 of argv
  tell application "System Events"
    set matches to every process whose bundle identifier is targetBundle
    set observations to {}
    repeat with p in matches
      set end of observations to {name of p, unix id of p, name of every window of p, role of every UI element of p}
    end repeat
    return observations
  end tell
end run
APPLESCRIPT
observe app-accessibility 15 osascript "$scratch/app-ui.applescript" "$bundle"
observe desktop-after 15 screencapture -x "$evidence/desktop-after.png"
# Parse through Foundation instead of requiring jq or another installation.
if [ -f "$evidence/native-window-observation.stdout.txt" ]; then
  window_id=$(WINDOW_JSON="$evidence/native-window-observation.stdout.txt" osascript -l JavaScript -e 'ObjC.import("Foundation"); const p=ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey("WINDOW_JSON")); const a=JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p,4,null))); if(a.windows.length) a.windows[0].id;' 2>> "$evidence/window-id.stderr.txt" || true)
  if [[ "$window_id" =~ ^[0-9]+$ ]]; then observe app-window 15 screencapture -x -l "$window_id" "$evidence/app-window.png"; fi
fi
cat > "$scratch/pixels.swift" <<'SWIFT'
import AppKit
import Foundation
for path in CommandLine.arguments.dropFirst() {
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: data) else { continue }
  var colors = Set<String>()
  for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 32)) {
    for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 32)) {
      if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) { colors.insert("\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255))") }
    }
  }
  print("\(path): width=\(rep.pixelsWide) height=\(rep.pixelsHigh) sampledDistinctColors=\(colors.count) nonuniform=\(colors.count > 1)")
}
SWIFT
observe screenshot-pixels 40 swift "$scratch/pixels.swift" "$evidence/desktop-before.png" "$evidence/desktop-after.png" "$evidence/app-window.png"
printf 'Smoke commands completed. Review window ownership, captured pixels, and permission statuses; completion alone does not prove accessible GUI.\n' > "$evidence/completion.txt"
