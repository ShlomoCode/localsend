#!/usr/bin/env bash
# Source-only diagnostic. No app termination or transfer cancellation is used.
set -Eeuo pipefail
evidence=$(realpath "${1:?evidence}"); exe=$(readlink -f "${2:?official installed executable}")
[[ $(id -un) == tester && $(id -u) != 0 ]]
out="$evidence/receiver"; mkdir -p "$out"
scripts=$(cd "$(dirname "$0")" && pwd); lifetime="$scripts/wsl_lifetime_snapshot.sh"
bash "$lifetime" "$evidence" register receiver "$$"
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
# v1.14 locks shared_preferences_linux 2.3.2 and path_provider_linux 2.2.1.
# The latter uses the GTK application ID if available, otherwise the executable
# basename. Its getApplicationSupportPath also prefers an existing legacy
# executable directory whenever the application-ID directory does not exist.
# Seed that supported legacy directory on a fresh profile so both paths resolve
# here, including systems without the unversioned libgio-2.0.so used by its FFI.
# The storage version is 1; flutter.-prefixed keys/types follow v1.14.0 source.
[[ $(basename "$exe") == localsend_app ]]
[[ ! -e "$XDG_DATA_HOME/org.localsend.localsend_app" && ! -e "$XDG_DATA_HOME/localsend_app" ]] || {
  echo 'Fresh profile requires neither application-ID nor legacy data directory'; exit 1;
}
settings="$XDG_DATA_HOME/localsend_app/shared_preferences.json"
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
printf 'HOME=%s\nXDG_DATA_HOME=%s\nXDG_CONFIG_HOME=%s\nsettings=%s\n' "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$settings" > "$out/preferences-location.txt"
export LANG=C.UTF-8 LIBGL_ALWAYS_SOFTWARE=1 XDG_RUNTIME_DIR=/tmp/localsend-1461-runtime
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
# Xvfb selects an unused display and reports the actual number through its own
# descriptor. A pre-existing :99 or WSLg display is never reused or terminated.
display_receipt="$out/xvfb-display-number.txt"
[[ ! -e "$display_receipt" ]]
xvfb_exe=$(readlink -f "$(command -v Xvfb)")
Xvfb -displayfd 3 -screen 0 1280x900x24 -nolisten tcp 3>"$display_receipt" > "$out/xvfb.log" 2>&1 & xvfb_pid=$!
xvfb_start_tick=$(awk '{print $22}' "/proc/$xvfb_pid/stat")
printf '%s\n' "$xvfb_pid" > "$out/xvfb.pid"
printf '%s\n' "$xvfb_start_tick" > "$out/xvfb.start-tick"
printf '%s\n' "$xvfb_exe" > "$out/xvfb-executable.txt"
xvfb_owned() {
  kill -0 "$xvfb_pid" 2>/dev/null && [[ -r "/proc/$xvfb_pid/stat" ]] &&
    [[ $(awk '{print $22}' "/proc/$xvfb_pid/stat") == "$xvfb_start_tick" && $(readlink -f "/proc/$xvfb_pid/exe") == "$xvfb_exe" ]]
}
for ((attempt=0; attempt<80; attempt++)); do
  kill -0 "$xvfb_pid" || { echo 'Owned Xvfb exited before display assignment'; exit 1; }
  [[ ! -s "$display_receipt" ]] || break
  sleep 0.25
done
[[ -s "$display_receipt" ]]
display_number=$(cat "$display_receipt")
[[ "$display_number" =~ ^[0-9]+$ ]]
export DISPLAY=":$display_number"
xvfb_owned
date -u --iso-8601=ns > "$out/xvfb-assigned.utc"
for ((attempt=0; attempt<40; attempt++)); do
  xvfb_owned || { echo 'Owned Xvfb identity failed during display readiness'; exit 1; }
  xdotool getdisplaygeometry >/dev/null 2>&1 && break
  sleep 0.25
done
xvfb_owned
xdotool getdisplaygeometry
eval "$(dbus-launch --sh-syntax)"
openbox > "$out/openbox.log" 2>&1 & wm_pid=$!
bash "$lifetime" "$evidence" register wm "$wm_pid"
bash "$lifetime" "$evidence" register dbus "${DBUS_SESSION_BUS_PID:?original dbus pid}"
"$exe" > "$out/app.log" 2>&1 & app_pid=$!
printf 'DISPLAY=%q\nAPP_PID=%q\nDEST=%q\nSETTINGS=%q\nEXE=%q\n' "$DISPLAY" "$app_pid" "$dest" "$settings" "$exe" > "$out/session.env"
printf 'XVFB_PID=%q\nXVFB_START_TICK=%q\nXVFB_EXE=%q\nDISPLAY_NUMBER=%q\nDISPLAY_RECEIPT=%q\n' \
  "$xvfb_pid" "$xvfb_start_tick" "$xvfb_exe" "$display_number" "$display_receipt" >> "$out/session.env"
awk '{print $22}' "/proc/$app_pid/stat" > "$out/app.start-tick"
ip -4 -o addr show dev eth0 scope global > "$out/guest-eth0-address.txt"
guest_ip=$(awk '{split($4,a,"/");print a[1]}' "$out/guest-eth0-address.txt")
[[ "$guest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
printf '%s\n' "$guest_ip" > "$out/guest-ipv4.txt"
printf 'GUEST_IP=%q\nALIAS=%q\nPORT=41631\n' "$guest_ip" WSL1461 >> "$out/session.env"
exact_readiness_word() {
  awk -F '\t' -v word="$2" 'NR>1 && $1==5 && $11>=50 && $12==word {n++} END{exit n!=1}' "$1"
}
for ((attempt=0; attempt<60; attempt++)); do
  xvfb_owned || { echo 'Owned Xvfb exited during actual app readiness'; exit 1; }
  kill -0 "$app_pid" || { echo 'Receiver exited before readiness'; exit 1; }
  windows=$(xdotool search --onlyvisible --pid "$app_pid" 2>/dev/null || true)
  if [[ -n "$windows" && $(wc -l <<< "$windows") == 1 ]]; then
    window=$windows
    [[ $(timeout 3 xdotool getwindowpid "$window") == "$app_pid" ]]
    xdotool windowactivate --sync "$window"
    xdotool windowsize "$window" 1200 820 windowmove "$window" 20 20
    timeout 8 ffmpeg -nostdin -y -loglevel error -f x11grab -video_size 1280x900 -i "$DISPLAY" -frames:v 1 "$out/readiness.png"
    timeout 8 tesseract "$out/readiness.png" "$out/readiness" --psm 11 tsv txt >/dev/null 2>&1
    receive_observed=0; receive_source=original
    if exact_readiness_word "$out/readiness.tsv" Receive; then
      receive_observed=1
    elif grep -q WSL1461 "$out/readiness.txt" && exact_readiness_word "$out/readiness.tsv" LocalSend; then
      # E13's original frame visibly has Receive, but its tiny navigation label
      # was OCR'd as "feceive" with confidence 0. That spelling never qualifies.
      # v1.14 HomePage's desktop NavigationRail contains the LocalSend heading
      # then Receive/Send/Settings. At the imposed 1200x820 size, the retained
      # E13 frame places these in the top-left 320x320 of the actual app window.
      # Read the owned window's native origin; crop only that bounded region
      # from the original pixels and enlarge it, retaining both representations.
      timeout 3 xdotool getwindowgeometry --shell "$window" > "$out/readiness-window-geometry.txt"
      read -r native_x native_y native_w native_h <<< "$(awk -F= '$1=="X"{x=$2} $1=="Y"{y=$2} $1=="WIDTH"{w=$2} $1=="HEIGHT"{h=$2} END{print x,y,w,h}' "$out/readiness-window-geometry.txt")"
      [[ "$native_x" =~ ^[0-9]+$ && "$native_y" =~ ^[0-9]+$ && "$native_w" =~ ^[0-9]+$ && "$native_h" =~ ^[0-9]+$ ]]
      (( native_w >= 320 && native_h >= 320 && native_x+native_w <= 1280 && native_y+native_h <= 900 ))
      [[ $(timeout 3 xdotool getwindowpid "$window") == "$app_pid" ]]
      cp "$out/readiness.png" "$out/readiness-navigation-source.png"
      date -u --iso-8601=ns > "$out/readiness-navigation-observed.utc"
      printf 'source_png\twindow\tpid\tx\ty\twidth\theight\tscale\n%s\t%s\t%s\t%s\t%s\t320\t320\t4\n' \
        "$out/readiness-navigation-source.png" "$window" "$app_pid" "$native_x" "$native_y" > "$out/readiness-navigation-transform.tsv"
      timeout 8 ffmpeg -nostdin -y -loglevel error -i "$out/readiness-navigation-source.png" \
        -vf "crop=320:320:$native_x:$native_y,scale=iw*4:ih*4:flags=lanczos" -frames:v 1 "$out/readiness-navigation.png"
      timeout 8 tesseract "$out/readiness-navigation.png" "$out/readiness-navigation" --psm 11 tsv txt > "$out/readiness-navigation-ocr.log" 2>&1
      [[ $(timeout 3 xdotool getwindowpid "$window") == "$app_pid" ]]
      if exact_readiness_word "$out/readiness-navigation.tsv" Receive; then
        receive_observed=1; receive_source=owned_navigation_crop_scaled_4
      fi
    fi
    ss -ltnp > "$out/listeners.txt"
    if (( receive_observed )) && grep -q WSL1461 "$out/readiness.txt" && kill -0 "$app_pid" &&
       [[ $(readlink -f "/proc/$app_pid/exe") == "$exe" && $(awk '{print $22}' "/proc/$app_pid/stat") == "$(cat "$out/app.start-tick")" && $(timeout 3 xdotool getwindowpid "$window") == "$app_pid" ]] &&
       grep -E ':41631[[:space:]].*pid='"$app_pid"',' "$out/listeners.txt" >/dev/null; then
      # Bind liveness references only after the existing strict executable/
      # start-tick readiness gate, never to the pre-exec child shell image.
      bash "$lifetime" "$evidence" register app "$app_pid" "$exe" "$(cat "$out/app.start-tick")"
      bash "$lifetime" "$evidence" register xvfb "$xvfb_pid" "$xvfb_exe" "$xvfb_start_tick"
      printf 'receive_source\texact_word\tminimum_confidence\twindow\tpid\n%s\tReceive\t50\t%s\t%s\n' \
        "$receive_source" "$window" "$app_pid" > "$out/readiness-observation.tsv"
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
snapshot_status=0
timeout --kill-after=1s 2s bash "$lifetime" "$evidence" snapshot receiver-ready-before-wait || snapshot_status=$?
printf '%s\n' "$snapshot_status" > "$out/lifetime/receiver-ready-before-wait.exit"
printf 'wait-start-observed\t%s\t%s\n' "$(date -u --iso-8601=ns)" "$(cat /proc/uptime)" > "$out/lifetime/wait-start.tsv"
status=0; wait "$app_pid" || status=$?
# This is observation after wait, not the true app-exit instant. Retain status
# before any secondary receipt/settings operation or display cleanup can fail.
printf 'wait-return-observed\t%s\tstatus=%s\t%s\n' "$(date -u --iso-8601=ns)" "$status" "$(cat /proc/uptime)" > "$out/lifetime/wait-return.tsv" || true
snapshot_status=0
timeout --kill-after=1s 2s bash "$lifetime" "$evidence" snapshot receiver-after-wait-before-cleanup || snapshot_status=$?
printf '%s\n' "$snapshot_status" > "$out/lifetime/receiver-after-wait-before-cleanup.exit" || true
cp "$settings" "$out/settings-after.json"
printf 'exited\t%s\t%s\n' "$(date -u --iso-8601=ns)" "$status" > "$out/app-exited.tsv"
kill "$wm_pid" "${DBUS_SESSION_BUS_PID:-}" 2>/dev/null || true
if xvfb_owned; then kill "$xvfb_pid" 2>/dev/null || true; fi
exit "$status"
