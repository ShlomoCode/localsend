#!/usr/bin/env bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
test "${GITHUB_REPOSITORY:-}" = ShlomoCode/localsend
test "${ISSUE3441_ADMITTED:-}" = 1
mkdir -p evidence/issue3441 "$RUNNER_TEMP/issue3441"
# BrowserStack documents an Intel binary; use Apple's supported Rosetta on ARM64.
if ! arch -x86_64 /usr/bin/true; then
  sudo softwareupdate --install-rosetta --agree-to-license
fi
arch -x86_64 /usr/bin/true
download() {
  local url="$1" target="$2" status
  status=$(curl --silent --show-error --location --retry 3 --output "$target" --write-out '%{http_code}' "$url")
  if test "$status" = 418; then
    status=$(curl --silent --show-error --location --retry 3 --proxy socks5h://100.108.223.54:38471 --output "$target" --write-out '%{http_code}' "$url")
  fi
  test "$status" = 200
}
download https://local-downloads.browserstack.com/BrowserStackLocal-darwin-x64.zip "$RUNNER_TEMP/issue3441/browserstack-local.zip"
test "$(shasum -a 256 "$RUNNER_TEMP/issue3441/browserstack-local.zip" | cut -d ' ' -f 1)" = bb293eeeeec062f97b380a0de077a2e5aea48b288b4bb654f8274ee6483b2d4d
unzip -q "$RUNNER_TEMP/issue3441/browserstack-local.zip" -d "$RUNNER_TEMP/issue3441/browserstack-local"
binary="$RUNNER_TEMP/issue3441/browserstack-local/BrowserStackLocal"
test "$(shasum -a 256 "$binary" | cut -d ' ' -f 1)" = 9091089b71864a5f840ba26eb15e141be184676cf2c9f0d821c53cb4cd42d8fb
chmod +x "$binary"
file "$binary" > evidence/issue3441/browserstack-local-tools.txt
shasum -a 256 "$RUNNER_TEMP/issue3441/browserstack-local.zip" "$binary" >> evidence/issue3441/browserstack-local-tools.txt
"$binary" --version >> evidence/issue3441/browserstack-local-tools.txt 2>&1
printf 'BROWSERSTACK_LOCAL_BINARY=%s\n' "$binary" >> "$GITHUB_ENV"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
test -d "$sdk"
printf 'ANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\n' "$sdk" "$sdk" >> "$GITHUB_ENV"
if ! command -v sdkmanager >/dev/null; then
  test -x "$sdk/cmdline-tools/latest/bin/sdkmanager"
  export PATH="$sdk/cmdline-tools/latest/bin:$PATH"
  printf '%s\n' "$sdk/cmdline-tools/latest/bin" >> "$GITHUB_PATH"
fi
command -v sdkmanager > evidence/issue3441/android-tools.txt
java -version >> evidence/issue3441/android-tools.txt 2>&1
sdkmanager --sdk_root="$sdk" 'platforms;android-35' 'build-tools;35.0.0' >/dev/null
file "$sdk/build-tools/35.0.0/aapt" "$sdk/build-tools/35.0.0/zipalign" >> evidence/issue3441/android-tools.txt
"$sdk/build-tools/35.0.0/aapt" version >> evidence/issue3441/android-tools.txt
download https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-android-arm64v8.apk "$RUNNER_TEMP/issue3441/original.apk"
node support/diagnostics/3441/upload-original.mjs "$RUNNER_TEMP/issue3441/original.apk"
