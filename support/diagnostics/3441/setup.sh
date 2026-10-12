#!/bin/bash
set -euo pipefail
mkdir -p evidence/issue3441 "$RUNNER_TEMP/issue3441"
sw_vers > evidence/issue3441/os.txt
uname -a >> evidence/issue3441/os.txt
test "$(uname -m)" = arm64
test "$(sw_vers -productVersion | cut -d . -f 1)" = 15
system_profiler SPHardwareDataType SPDisplaysDataType > evidence/issue3441/hardware.txt
printf "image=%s\nimageVersion=%s\ncommit=%s\n" "${ImageOS:-unknown}" "${ImageVersion:-unknown}" "$GITHUB_SHA" > evidence/issue3441/identity.txt
curl --fail --location --retry 3 https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2.dmg -o "$RUNNER_TEMP/issue3441/release.dmg"
test "$(stat -f %z "$RUNNER_TEMP/issue3441/release.dmg")" = 52700247
shasum -a 256 "$RUNNER_TEMP/issue3441/release.dmg" > evidence/issue3441/release.sha256
hdiutil attach -readonly -nobrowse -mountpoint "$RUNNER_TEMP/issue3441/mount" "$RUNNER_TEMP/issue3441/release.dmg"
trap 'hdiutil detach "$RUNNER_TEMP/issue3441/mount"' EXIT
app=$(find "$RUNNER_TEMP/issue3441/mount" -maxdepth 1 -name '*.app' -print -quit)
test -n "$app"
sudo ditto "$app" /Applications/LocalSend.app
codesign --verify --deep --strict --verbose=2 /Applications/LocalSend.app 2> evidence/issue3441/codesign-before.txt
codesign -dv --verbose=4 /Applications/LocalSend.app 2>> evidence/issue3441/codesign-before.txt
/usr/libexec/PlistBuddy -c Print /Applications/LocalSend.app/Contents/Info.plist > evidence/issue3441/app-info.txt
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/LocalSend.app/Contents/Info.plist)
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/LocalSend.app/Contents/Info.plist)
test "$version" = 1.18.2
test ! -e /Applications/LocalSend.app/Contents/MacOS/settings.json
# Native preferences remain outside the signed app; require a fresh hosted user.
if defaults read "$bundle" > evidence/issue3441/preferences-before.txt 2>/dev/null; then
  echo 'Existing native app preferences; refuse an unrecorded reused profile' >&2
  exit 1
fi
printf 'APP_BUNDLE=%s\nRECEIVER_DESTINATION=%s/Downloads\n' "$bundle" "$HOME" >> "$GITHUB_ENV"
mkdir -p "$HOME/Downloads"
swiftc support/diagnostics/3441/ax.swift -o "$RUNNER_TEMP/issue3441/ax"
open -a /Applications/LocalSend.app --args --verbose
