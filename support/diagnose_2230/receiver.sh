#!/usr/bin/env bash
# Run as tester inside Ubuntu 24.04 WSL2. Keep this process alive across cases.
set -Eeuo pipefail
evidence=${1:?Usage: receiver.sh evidenceDir [installedExecutable]}
exe=$(readlink -f "${2:-/usr/share/localsend/localsend_app}")
mkdir -p "$evidence/receiver"
evidence=$(realpath "$evidence")
out="$evidence/receiver"
rm -f "$out/ready.tsv" "$out/session.env"
exec > >(tee -a "$out/startup.log") 2>&1
date -u --iso-8601=ns
[[ $(id -un) == tester && $(id -u) != 0 ]] || { echo 'Must run as normal user tester'; exit 1; }
[[ -x "$exe" ]] || { echo "Missing installed executable: $exe"; exit 1; }
for tool in Xvfb dbus-launch openbox xdotool tesseract ffmpeg ss timeout; do command -v "$tool"; done
cat /etc/os-release | tee "$out/os-release.txt"
uname -a | tee "$out/kernel.txt"
grep -qi microsoft /proc/sys/kernel/osrelease
grep -q 'VERSION_ID="24.04"' /etc/os-release
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' localsend | tee "$out/package.tsv"
grep -Eq $'\t1\\.16\\.1([+-][^\t]+)?\tamd64$' "$out/package.tsv"
dpkg -V localsend > "$out/package-verification.txt" || { cat "$out/package-verification.txt"; exit 1; }
[[ ! -s "$out/package-verification.txt" ]] || { echo 'Installed package files differ'; exit 1; }
sha256sum "$exe" > "$out/executable.sha256"
settings="$(dirname "$exe")/settings.json"
# 1.16.1 portable persistence reads flutter-prefixed JSON beside the executable.
# Parent must create/chown this extra file before running the installed app.
[[ -w "$settings" || ( ! -e "$settings" && -w "$(dirname "$exe")" ) ]] || {
  echo "Parent must provide tester-writable $settings"; exit 1;
}
dest=/home/tester/文档/Books
mkdir -p "$dest"
findmnt -T "$dest" -o TARGET,SOURCE,FSTYPE,OPTIONS > "$out/destination-filesystem.txt"
[[ $(findmnt -n -T "$dest" -o FSTYPE) == ext4 ]] || { echo 'Destination must be Linux ext4'; exit 1; }
probe=$(mktemp "$dest/.writable.XXXXXX")
printf 'Linux destination write probe\n' > "$probe"
sha256sum "$probe" > "$out/destination-write.sha256"
rm "$probe"
cat > "$settings" <<'JSON'
{
  "flutter.ls_version": 2,
  "flutter.ls_alias": "Ubuntu2230",
  "flutter.ls_locale": "en",
  "flutter.ls_theme": "light",
  "flutter.ls_port": 53317,
  "flutter.ls_https": false,
  "flutter.ls_destination": "/home/tester/文档/Books",
  "flutter.ls_quick_save": false,
  "flutter.ls_quick_save_from_favorites": false,
  "flutter.ls_save_to_gallery": false,
  "flutter.ls_auto_finish": false,
  "flutter.ls_minimize_to_tray": false
}
JSON
cp "$settings" "$out/settings-before.json"
export DISPLAY=:99 LANG=C.UTF-8 LIBGL_ALWAYS_SOFTWARE=1
export XDG_RUNTIME_DIR=/tmp/localsend-2230-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
Xvfb "$DISPLAY" -screen 0 1280x900x24 -nolisten tcp > "$out/xvfb.log" 2>&1 & xvfb_pid=$!
for attempt in $(seq 1 20); do
  if xdotool getdisplaygeometry >/dev/null 2>&1; then break; fi
  sleep 0.25
done
xdotool getdisplaygeometry
eval "$(dbus-launch --sh-syntax)"
openbox > "$out/openbox.log" 2>&1 & wm_pid=$!
"$exe" > "$out/app.log" 2>&1 & app_pid=$!
cleanup() {
  cp "$settings" "$out/settings-after.json" || true
  kill "$app_pid" "$wm_pid" "$xvfb_pid" "${DBUS_SESSION_BUS_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
printf 'DISPLAY=%q\nAPP_PID=%q\nDEST=%q\n' "$DISPLAY" "$app_pid" "$dest" > "$out/session.env"
for attempt in $(seq 1 60); do
  kill -0 "$app_pid" || { echo 'Receiver exited before readiness'; exit 1; }
  windows=$(xdotool search --onlyvisible --pid "$app_pid" 2>/dev/null || true)
  if [[ -n "$windows" ]]; then
    window=$(head -n 1 <<< "$windows")
    xdotool windowactivate --sync "$window"
    xdotool windowsize "$window" 1200 820 windowmove "$window" 20 20
    timeout 8 ffmpeg -nostdin -y -loglevel error -f x11grab -video_size 1280x900 -i "$DISPLAY" -frames:v 1 "$out/readiness.png"
    timeout 8 tesseract "$out/readiness.png" "$out/readiness" --psm 11 tsv txt >/dev/null 2>&1
    ss -ltnp > "$out/listeners.txt"
    if grep -q 'Ubuntu2230' "$out/readiness.txt" && grep -q 'Receive' "$out/readiness.txt" &&
       grep -E ':53317[[:space:]].*pid='"$app_pid"',' "$out/listeners.txt" >/dev/null; then
      printf 'WINDOW=%q\n' "$window" >> "$out/session.env"
      printf 'ready\t%s\t%s\n' "$(date -u --iso-8601=ns)" "$app_pid" > "$out/ready.tsv"
      break
    fi
  fi
  sleep 1
done
[[ -s "$out/ready.tsv" ]] || { echo 'Rendered alias/window/listener readiness failed'; exit 1; }
wait "$app_pid"
