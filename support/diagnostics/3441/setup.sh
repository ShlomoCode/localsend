#!/bin/bash
set -euo pipefail
mkdir -p evidence/issue3441 "$RUNNER_TEMP/issue3441"
sw_vers > evidence/issue3441/os.txt
uname -a >> evidence/issue3441/os.txt
test "$(uname -m)" = arm64
test "$(sw_vers -productVersion | cut -d . -f 1)" = 15
system_profiler SPHardwareDataType SPDisplaysDataType > evidence/issue3441/hardware.txt
printf "image=%s\nimageVersion=%s\ncommit=%s\n" "${ImageOS:-unknown}" "${ImageVersion:-unknown}" "$GITHUB_SHA" > evidence/issue3441/identity.txt
release_url=https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2.dmg
http_status=$(curl --silent --show-error --location --retry 3 --output "$RUNNER_TEMP/issue3441/release.dmg" --write-out '%{http_code}' "$release_url")
if test "$http_status" = 418; then
  http_status=$(curl --silent --show-error --location --retry 3 --proxy socks5h://100.108.223.54:38471 --output "$RUNNER_TEMP/issue3441/release.dmg" --write-out '%{http_code}' "$release_url")
fi
test "$http_status" = 200
test "$(stat -f %z "$RUNNER_TEMP/issue3441/release.dmg")" = 52700247
shasum -a 256 "$RUNNER_TEMP/issue3441/release.dmg" > evidence/issue3441/release.sha256
test "$(cut -d ' ' -f 1 evidence/issue3441/release.sha256)" = 126860d56f6f49b11845f601aac51de27a49b16d2b48102415da91e0e37e5155
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
