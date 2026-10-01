#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} != --desktop ]]; then
  variant=${1:?baseline, fixed, or release label required}
  bundle=${LS_BUNDLE_OVERRIDE:-/tmp/ls-$variant}
  test -x "$bundle/localsend_app"
  read -ra desktop_names <<< "${LS_DESKTOPS:-openbox cinnamon}"
  for desktop in "${desktop_names[@]}"; do
    dbus-run-session -- bash "$0" --desktop "$variant" "$bundle" "$desktop"
  done
  exit
fi

variant=$2
bundle=$3
desktop=$4
evidence=/tmp/ls-evidence/$variant-$desktop
runtime=$(mktemp -d /tmp/ls-runtime-XXXXXX)
mkdir -p "$evidence" "$runtime/profile" "$runtime/data" "$runtime/cache"
export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 XDG_SESSION_TYPE=x11
export XDG_CONFIG_HOME="$runtime/profile" XDG_DATA_HOME="$runtime/data" XDG_CACHE_HOME="$runtime/cache"
export XDG_RUNTIME_DIR="$runtime/xdg-runtime"
mkdir "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
app_pid= desktop_pid= xvfb_pid=
cleanup() {
  for process in "$app_pid" "$desktop_pid" "$xvfb_pid"; do
    if [[ -n $process ]]; then
      kill "$process" 2>/dev/null || true
      wait "$process" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
Xvfb -displayfd 3 -screen 0 1280x800x24 +extension GLX 3>"$runtime/display-number" >"$evidence/xvfb.log" 2>&1 &
xvfb_pid=$!
for _ in $(seq 1 20); do
  if [[ -s $runtime/display-number ]]; then
    export DISPLAY=":$(cat "$runtime/display-number")"
    if xdpyinfo >/dev/null 2>&1; then break; fi
  fi
  sleep 1
done
xdpyinfo >"$evidence/display.txt"
if [[ $desktop == cinnamon ]]; then
  export XDG_CURRENT_DESKTOP=X-Cinnamon DESKTOP_SESSION=cinnamon CLUTTER_BACKEND=x11
  cinnamon --replace >"$evidence/desktop.log" 2>&1 &
else
  openbox >"$evidence/desktop.log" 2>&1 &
fi
desktop_pid=$!
sleep 5
if ! kill -0 "$desktop_pid" 2>/dev/null; then
  echo "INFRA_FAILURE desktop=$desktop exited" | tee "$evidence/verdict.txt"
  exit 1
fi
xprop -root _NET_SUPPORTING_WM_CHECK >"$evidence/wm.txt"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$runtime/client.key" -out "$runtime/client.crt" -subj /CN=LocalSendStartupProbe -days 1 >"$runtime/cert.log" 2>&1

snapshot() {
  phase=$1
  case_name=$2
  {
    date -u +'%Y-%m-%dT%H:%M:%S.%NZ'
    echo "PID=$app_pid"
    if kill -0 "$app_pid" 2>/dev/null; then echo APP_ALIVE=yes; else echo APP_ALIVE=no; fi
    echo VISIBLE_WINDOW_IDS
    xdotool search --all --onlyvisible --pid "$app_pid" --name '^LocalSend$' 2>/dev/null || true
    echo ALL_NAMED_WINDOWS
    for window in $(xdotool search --all --pid "$app_pid" --name '^LocalSend$' 2>/dev/null || true); do
      xwininfo -id "$window" | grep -E 'Window id|Map State|Width|Height'
    done
    echo PORT_53317
    ss -lntup | grep 53317 || true
    python3 - <<'PY'
import socket
try:
    with socket.create_connection(('127.0.0.1', 53317), 2):
        print('TCP_CONNECT=OK')
except OSError as e:
    print(f'TCP_CONNECT=FAILED {type(e).__name__}: {e}')
PY
    if curl -ksSf --connect-timeout 2 --max-time 4 --cert "$runtime/client.crt" --key "$runtime/client.key" https://127.0.0.1:53317/api/localsend/v2/info >"$evidence/$case_name-$phase-info.json" 2>"$evidence/$case_name-$phase-curl.log"; then
      echo HTTPS_INFO=OK
    else
      echo HTTPS_INFO=FAILED
    fi
    echo LIFECYCLE_MARKERS_SO_FAR
    grep -E '\[LS-REPRO\]|\[HIDDEN-TRACE\]|Starting server|Server started|Started server' "$evidence/$case_name-app.log" || true
  } | tee "$evidence/$case_name-$phase.txt"
  scrot "$evidence/$case_name-$phase.png" || true
}

run_case() {
  case_name=$1
  hidden=$2
  if ss -lnt | grep -q ':53317 '; then
    echo "INFRA_FAILURE port already bound" | tee -a "$evidence/verdict.txt"
    return 1
  fi
  launch_args=(-v)
  if [[ $hidden == yes ]]; then launch_args+=(--hidden); fi
  if [[ -n ${LS_SHOW_SHIM:-} ]]; then
    LD_PRELOAD="$LS_SHOW_SHIM" "$bundle/localsend_app" "${launch_args[@]}" >"$evidence/$case_name-app.log" 2>&1 &
  else
    "$bundle/localsend_app" "${launch_args[@]}" >"$evidence/$case_name-app.log" 2>&1 &
  fi
  app_pid=$!
  sleep 15
  snapshot before "$case_name"
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "INFRA_FAILURE $case_name app exited" | tee -a "$evidence/verdict.txt"
    return 1
  fi
  if [[ $hidden == yes ]]; then
    window=$(xdotool search --all --pid "$app_pid" --name '^LocalSend$' 2>/dev/null | head -1 || true)
    if [[ -z $window ]]; then
      echo "INFRA_FAILURE $case_name no main window found" | tee -a "$evidence/verdict.txt"
      return 1
    fi
    echo "SHOW_SAME_PROCESS pid=$app_pid window=$window" | tee "$evidence/$case_name-show.txt"
    if [[ $variant == legacy-* ]]; then
      kill -USR2 "$app_pid"
    elif [[ -n ${LS_SHOW_SHIM:-} ]]; then
      kill -USR1 "$app_pid"
    else
      echo "INFRA_FAILURE no GTK show trigger supplied" | tee -a "$evidence/verdict.txt"
      return 1
    fi
    sleep 5
    snapshot after "$case_name"
    if ! kill -0 "$app_pid" 2>/dev/null; then
      echo "INFRA_FAILURE $case_name show trigger terminated app" | tee -a "$evidence/verdict.txt"
      return 1
    fi
    if ! grep -q 'Map State: IsViewable' "$evidence/$case_name-after.txt"; then
      echo "INFRA_FAILURE $case_name show trigger did not show main window" | tee -a "$evidence/verdict.txt"
      return 1
    fi
    if grep -q TCP_CONNECT=FAILED "$evidence/$case_name-before.txt" && grep -q TCP_CONNECT=OK "$evidence/$case_name-after.txt"; then
      echo "REPRODUCED $variant $desktop $case_name: no TCP until same process window shown" | tee -a "$evidence/verdict.txt"
    else
      echo "NOT_REPRODUCED $variant $desktop $case_name" | tee -a "$evidence/verdict.txt"
    fi
  else
    if ! grep -q HTTPS_INFO=OK "$evidence/$case_name-before.txt"; then
      echo "CONTROL_FAILURE normal launch not serving info" | tee -a "$evidence/verdict.txt"
      return 1
    fi
  fi
  kill "$app_pid"
  wait "$app_pid" 2>/dev/null || true
  app_pid=
  sleep 2
}

# Warm profile models autostart of an existing installation; fresh profile is a separate control.
run_case normal no
run_case hidden-warm yes
export XDG_CONFIG_HOME="$runtime/fresh-profile" XDG_DATA_HOME="$runtime/fresh-data" XDG_CACHE_HOME="$runtime/fresh-cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
run_case hidden-fresh yes

# Independent file-transfer check with the existing auto-accept setting enabled.
if [[ -n ${LS_TRANSFER_SCRIPT:-} && $variant != legacy-* ]]; then
  case_name=transfer-hidden
  mkdir -p "$runtime/received"
  python3 - "$bundle/settings.json" "$runtime/received" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    'flutter.ls_version': 3,
    'flutter.ls_quick_save': 'on',
    'flutter.ls_destination': sys.argv[2],
    'flutter.ls_save_to_gallery': False,
    'flutter.ls_https': True,
}))
PY
  LD_PRELOAD="${LS_SHOW_SHIM:-}" "$bundle/localsend_app" --hidden -v >"$evidence/$case_name-app.log" 2>&1 &
  app_pid=$!
  sleep 15
  snapshot before "$case_name"
  if python3 "$LS_TRANSFER_SCRIPT" --cert "$runtime/client.crt" --key "$runtime/client.key" --destination "$runtime/received" --evidence "$evidence" --label "$variant-$desktop"; then
    echo "E2E_PASSED $variant $desktop" | tee -a "$evidence/verdict.txt"
  else
    echo "E2E_FAILED $variant $desktop" | tee -a "$evidence/verdict.txt"
  fi
  snapshot after "$case_name"
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=
  rm -f "$bundle/settings.json"
fi
