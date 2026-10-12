#!/usr/bin/env bash
set -euo pipefail
export ISSUE1035_ROOT="$PWD"
mkdir -p evidence releases profiles
date --iso-8601=ns > evidence/runner-start.txt
printf '%s\n' "$GITHUB_SHA" > evidence/source-head.txt
sha256sum support/diagnostics/1035/*.sh .github/workflows/build_linux_tar_x64.yml > evidence/source-SHA256SUMS
cat /etc/os-release > evidence/os-release.txt
uname -a > evidence/uname.txt
printf '%s\n' 'Ubuntu22.04 x64/XFCE/Xvfb differs from reported Fedora39/Cinnamon; release unknown.' > evidence/report-boundary.txt
desktop_pid=
desktop_start=
nm_original=$(timeout 5 systemctl is-active NetworkManager 2>/dev/null || true)
printf '%s\n' "$nm_original" > evidence/NetworkManager-original-state.txt
cleanup() {
  rc=$?
  trap - EXIT TERM INT
  date --iso-8601=ns > evidence/cleanup-start.txt
  # A real terminal gives its executed shell a separate controlling-terminal
  # session. Reconcile these recorded PTY groups before the XFCE group.
  for receipt in evidence/*/terminal-process-group.txt; do
    test -f "$receipt" || continue
    read -r leader start group session < "$receipt"
    if ! ps -eo pgid= | awk -v pg="$group" '$1==pg{found=1}END{exit !found}'; then
      printf '%s already absent\n' "$group" >> evidence/cleanup-pty-groups.txt
      continue
    fi
    if test -r "/proc/$leader/stat" &&
       test "$(awk '{print $22}' "/proc/$leader/stat")" = "$start" &&
       test "$(ps -o pgid= -p "$leader" | tr -d ' ')" = "$group" &&
       test "$(ps -o sid= -p "$leader" | tr -d ' ')" = "$session" &&
       test "$group" = "$leader" && test "$session" = "$leader"; then
      ps -eo pid,ppid,pgid,lstart,args | awk -v pg="$group" '$3==pg' >> evidence/cleanup-pty-before.txt
      kill -TERM -- "-$group" 2>/dev/null || true
      for n in $(seq 1 5); do
        if ! ps -eo pgid= | awk -v pg="$group" '$1==pg{found=1}END{exit !found}'; then break; fi
        sleep 1
      done
      if ps -eo pgid= | awk -v pg="$group" '$1==pg{found=1}END{exit !found}'; then kill -KILL -- "-$group" 2>/dev/null || true; fi
      ps -eo pid,ppid,pgid,lstart,args | awk -v pg="$group" '$3==pg' >> evidence/cleanup-pty-after.txt
    else
      printf '%s live PTY group identity unavailable; no group kill\n' "$group" >> evidence/cleanup-refused.txt
      rc=92
    fi
  done
  if test -n "$desktop_pid" && test -r "/proc/$desktop_pid/stat"; then
    current_start=$(awk '{print $22}' "/proc/$desktop_pid/stat")
    current_group=$(ps -o pgid= -p "$desktop_pid" | tr -d ' ')
    if test "$current_start" = "$desktop_start" && test "$current_group" = "$desktop_pid"; then
      ps -eo pid,ppid,pgid,lstart,args | awk -v pg="$desktop_pid" '$3==pg' > evidence/cleanup-owned-before.txt
      kill -TERM -- "-$desktop_pid" 2>/dev/null || true
      for n in $(seq 1 8); do
        if ! ps -eo pgid= | awk -v pg="$desktop_pid" '$1==pg{found=1}END{exit !found}'; then break; fi
        sleep 1
      done
      # Exact recorded group only, after the bounded TERM grace.
      if ps -eo pgid= | awk -v pg="$desktop_pid" '$1==pg{found=1}END{exit !found}'; then
        kill -KILL -- "-$desktop_pid" 2>/dev/null || true
      fi
      wait "$desktop_pid" 2>/dev/null || true
      ps -eo pid,ppid,pgid,lstart,args | awk -v pg="$desktop_pid" '$3==pg' > evidence/cleanup-owned-after.txt
    else
      printf 'Owned desktop identity changed; group cleanup refused\n' > evidence/cleanup-refused.txt
      rc=92
    fi
  fi
  if test "$nm_original" != active; then
    timeout --signal=KILL 8s sudo systemctl stop NetworkManager > evidence/NetworkManager-restoration.txt 2>&1 || true
  fi
  date --iso-8601=ns > evidence/cleanup-end.txt
  printf '%s\n' "$rc" > evidence/runner-exit.txt
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM INT
printf 'apt\n' > evidence/stage.txt
# The global 870-second work deadline takes precedence over every stage ceiling.
timeout --signal=TERM --kill-after=5s 355s sudo bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y xfce4 xfce4-terminal dbus-x11 xvfb xauth x11-utils xdotool scrot ffmpeg tesseract-ocr tesseract-ocr-eng libfuse2 libayatana-appindicator3-1 libsecret-1-0 libopengl0 libegl1 libegl-mesa0 libgles2 libgl1-mesa-dri network-manager at-spi2-core' > evidence/apt.log 2>&1
printf 'download\n' > evidence/stage.txt
timeout --signal=TERM --kill-after=5s 115s bash -c '
  set -euo pipefail
  for version in 1.14.0 1.18.2; do
    curl -fL --connect-timeout 15 --max-time 45 -o "releases/$version.AppImage" "https://github.com/localsend/localsend/releases/download/v$version/LocalSend-$version-linux-x86-64.AppImage"
  done
  printf "%s\n" "e89e885a1de2122dbe5b2b7ec439dca00accee1e63237d4685946a48a35ca8d2  releases/1.14.0.AppImage" "19f21613d1834f6caa69517113670461a3f10b80a2a315f86548c0663d9c0aaf  releases/1.18.2.AppImage" > evidence/release-SHA256SUMS
  sha256sum -c evidence/release-SHA256SUMS
  chmod +x releases/*.AppImage
  mkdir -p evidence/releases
  cp releases/*.AppImage evidence/releases/
' > evidence/download.log 2>&1
printf 'desktop\n' > evidence/stage.txt
desktop_deadline=$((SECONDS + 115))
timeout --signal=TERM --kill-after=5s 15s sudo systemctl start NetworkManager
timeout 5 busctl --system get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager Version > evidence/NetworkManager-version.txt
timeout 5 systemctl status NetworkManager --no-pager > evidence/NetworkManager-status.txt
timeout 5 busctl --system list > evidence/system-bus.txt
test -c /dev/fuse
if command -v fusermount >/dev/null; then timeout 5 fusermount --version > evidence/fuse.txt; else timeout 5 fusermount3 --version > evidence/fuse.txt; fi
for command in startxfce4 xfce4-terminal Xvfb dbus-run-session xdotool xprop xwininfo scrot ffmpeg ffprobe tesseract; do command -v "$command"; done > evidence/tool-paths.txt
timeout 5 dpkg-query -W xfce4 xfce4-session xfwm4 network-manager libfuse2 libgles2 xvfb xfce4-terminal > evidence/package-versions.txt
timeout 5 dpkg-query -L libgles2 > evidence/libgles2-files.txt
timeout 5 ldconfig -p > evidence/native-library-cache.txt
grep -F 'libGLESv2.so.2' evidence/native-library-cache.txt > evidence/GLES-runtime-control.txt
# setsid provides an exact owned process group. The supervisor remains alive
# after the observation exits, so its PID/start identity is available to cleanup.
export ISSUE1035_DESKTOP_SECONDS=$((desktop_deadline - SECONDS))
test "$ISSUE1035_DESKTOP_SECONDS" -gt 0
setsid bash -c '
  set +e
  timeout --foreground --signal=TERM --kill-after=5s 475s dbus-run-session -- xvfb-run -a -s "-screen 0 1280x900x24" bash support/diagnostics/1035/desktop.sh
  status=$?
  printf "%s\n" "$status" > evidence/desktop-exit.txt
  sleep 120
' > evidence/desktop.log 2>&1 &
desktop_pid=$!
desktop_start=$(awk '{print $22}' "/proc/$desktop_pid/stat")
printf '%s %s\n' "$desktop_pid" "$desktop_start" > evidence/desktop-supervisor-identity.txt
while ! test -f evidence/desktop-ready.txt; do
  test "$SECONDS" -lt "$desktop_deadline"
  if test -f evidence/desktop-exit.txt; then exit 62; fi
  kill -0 "$desktop_pid"
  sleep 0.2
done
scenario_deadline=$((SECONDS + 350))
while ! test -f evidence/desktop-exit.txt; do
  if test "$SECONDS" -ge "$scenario_deadline"; then
    printf 'scenario six-minute ceiling reached before complete observations\n' > evidence/scenario-deadline.txt
    exit 63
  fi
  kill -0 "$desktop_pid"
  sleep 1
done
status=$(cat evidence/desktop-exit.txt)
test "$status" = 0
printf 'observations-retained; no fix attribution\n' > evidence/complete.txt
