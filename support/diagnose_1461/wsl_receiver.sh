#!/usr/bin/env bash
# Source-only diagnostic. No app termination or transfer cancellation is used.
set -Eeuo pipefail
evidence=$(realpath "${1:?evidence}"); exe=$(readlink -f "${2:?official installed executable}")
[[ $(id -un) == tester && $(id -u) != 0 ]]
out="$evidence/receiver"; mkdir -p "$out"
exec > >(tee -a "$out/startup.log") 2>&1
[[ -f "$exe" && -x "$exe" && ! -e "$out/session.env" ]]
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' localsend > "$out/package.tsv"
grep -Eq $'\t1\\.14\\.0([+-][^\t]+)?\tamd64$' "$out/package.tsv"
dpkg -V localsend > "$out/package-verification.txt"; [[ ! -s "$out/package-verification.txt" ]]
sha256sum "$exe" > "$out/executable.sha256"
cat /etc/os-release > "$out/os-release.txt"; uname -a > "$out/kernel.txt"
[[ "$HOME" == /home/tester ]]
export XDG_DATA_HOME=/home/tester/.local/share XDG_CONFIG_HOME=/home/tester/.config
dest=/home/tester/LocalSend1461
mkdir -p "$dest"
[[ -z $(find "$dest" -mindepth 1 -maxdepth 1 -print -quit) ]]
findmnt -T "$dest" -o TARGET,SOURCE,FSTYPE,OPTIONS > "$out/destination-filesystem.txt"
[[ $(findmnt -n -T "$dest" -o FSTYPE) == ext4 ]]
# v1.14 persistence version is 1; Linux uses shared_preferences_linux, NOT
# Windows-only portable settings.json. Keys/types follow v1.14.0 source.
settings="$XDG_DATA_HOME/org.localsend.localsend_app/shared_preferences.json"
mkdir -p "$(dirname "$settings")"
[[ ! -e "$settings" ]] || { echo 'Fresh tester profile required'; exit 1; }
cat > "$settings" <<'JSON'
{
  "flutter.ls_version": 1,
  "flutter.ls_alias": "WSL1461",
  "flutter.ls_locale": "en",
  "flutter.ls_theme": "light",
  "flutter.ls_port": 41631,
  "flutter.ls_https": false,
  "flutter.ls_destination": "/home/tester/LocalSend1461",
  "flutter.ls_quick_save": false,
  "flutter.ls_save_to_gallery": false,
  "flutter.ls_auto_finish": false,
  "flutter.ls_minimize_to_tray": false
}
JSON
cp "$settings" "$out/settings-before.json"
export DISPLAY=:99 LANG=C.UTF-8 LIBGL_ALWAYS_SOFTWARE=1 XDG_RUNTIME_DIR=/tmp/localsend-1461-runtime
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
Xvfb "$DISPLAY" -screen 0 1280x900x24 -nolisten tcp > "$out/xvfb.log" 2>&1 & xvfb_pid=$!
for ((attempt=0; attempt<40; attempt++)); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.25; done
xdotool getdisplaygeometry
eval "$(dbus-launch --sh-syntax)"
openbox > "$out/openbox.log" 2>&1 & wm_pid=$!
"$exe" > "$out/app.log" 2>&1 & app_pid=$!
printf 'DISPLAY=%q\nAPP_PID=%q\nDEST=%q\nSETTINGS=%q\nEXE=%q\n' "$DISPLAY" "$app_pid" "$dest" "$settings" "$exe" > "$out/session.env"
awk '{print $22}' "/proc/$app_pid/stat" > "$out/app.start-tick"
ip -4 -o addr show dev eth0 scope global > "$out/guest-eth0-address.txt"
guest_ip=$(awk '{split($4,a,"/");print a[1]}' "$out/guest-eth0-address.txt")
[[ "$guest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
printf '%s\n' "$guest_ip" > "$out/guest-ipv4.txt"
printf 'GUEST_IP=%q\nALIAS=%q\nPORT=41631\n' "$guest_ip" WSL1461 >> "$out/session.env"
for ((attempt=0; attempt<60; attempt++)); do
  kill -0 "$app_pid" || { echo 'Receiver exited before readiness'; exit 1; }
  windows=$(xdotool search --onlyvisible --pid "$app_pid" 2>/dev/null || true)
  if [[ -n "$windows" && $(wc -l <<< "$windows") == 1 ]]; then
    window=$windows
    xdotool windowactivate --sync "$window"
    xdotool windowsize "$window" 1200 820 windowmove "$window" 20 20
    timeout 8 ffmpeg -nostdin -y -loglevel error -f x11grab -video_size 1280x900 -i "$DISPLAY" -frames:v 1 "$out/readiness.png"
    timeout 8 tesseract "$out/readiness.png" "$out/readiness" --psm 11 tsv txt >/dev/null 2>&1
    ss -ltnp > "$out/listeners.txt"
    if grep -q WSL1461 "$out/readiness.txt" && grep -q Receive "$out/readiness.txt" &&
       grep -E ':41631[[:space:]].*pid='"$app_pid"',' "$out/listeners.txt" >/dev/null; then
      printf 'WINDOW=%q\n' "$window" >> "$out/session.env"
      printf 'ready\t%s\t%s\n' "$(date -u --iso-8601=ns)" "$app_pid" > "$out/ready.tsv"
      break
    fi
  fi
  sleep 1
done
[[ -s "$out/ready.tsv" ]] || { echo 'Readiness failed; live app is preserved'; exit 1; }
# Cleanup the display only after the actual app exits. A control timeout does
# not kill LocalSend, delete partial files, or create an artificial error.
status=0; wait "$app_pid" || status=$?
cp "$settings" "$out/settings-after.json"
printf 'exited\t%s\t%s\n' "$(date -u --iso-8601=ns)" "$status" > "$out/app-exited.tsv"
kill "$wm_pid" "$xvfb_pid" "${DBUS_SESSION_BUS_PID:-}" 2>/dev/null || true
exit "$status"
