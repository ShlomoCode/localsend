#!/usr/bin/env bash
# Diagnostic only. Use the unchanged ISO launcher and actual installer GUI.
set -euo pipefail
cd "$HOME"
mkdir -p evidence/install
session=$(pgrep -u "$(id -u)" -x xfce4-session | head -1)
test -n "$session"
while IFS= read -r -d '' value; do
  case "$value" in DISPLAY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*|XAUTHORITY=*) export "$value";; esac
done < "/proc/$session/environ"
{ dpkg-query -W mx-installer gazelle-installer-data-mx; sha256sum /usr/sbin/minstall; /usr/sbin/minstall --version; /usr/sbin/minstall --help; } > evidence/install/installer-identity.txt 2>&1
# Config compatibility is version-dependent; do not guess on another ISO build.
test "$(dpkg-query -W -f='${Version}' mx-installer)" = 24.01.01mx23
printf 'LANG=%s\n' "${LANG:-}" >> evidence/install/installer-identity.txt
case "${LANG:-}" in en*|C*) ;; *) exit 2;; esac
case "${INSTALLER_TRACE:-0}" in 0|1) ;; *) exit 2;; esac
{ date -u; cat /etc/os-release; lsblk -f; cat /proc/cmdline; } > evidence/install/before.txt
{ sha256sum /usr/bin/minstall-launcher; cat /usr/bin/minstall-launcher; cat /usr/share/gazelle-installer-data/installer.conf; } > evidence/install/launcher-original.txt
dpkg-query -W > evidence/install/packages-before-observer.txt
# Normal distro accessibility tooling observes and operates actual widgets.
observer_packages=(python3-pyatspi scrot)
if test "${INSTALLER_TRACE:-0}" = 1; then observer_packages+=(strace); fi
printf 'demo\n' | sudo -S apt-get install -y "${observer_packages[@]}" > evidence/install/observer-install.log 2>&1
dpkg-query -W > evidence/install/packages-after-observer.txt
root_inventory='set -eu; printf "PATH=%s\n" "$PATH"; pwd; id; test "$(id -u)" = 0; cat /proc/self/status; for tool in mount umount; do command -v "$tool"; resolved=$(readlink -f "$(command -v "$tool")"); printf "%s\n" "$resolved"; stat -c "%a %u:%g %n" "$resolved"; dpkg-query -S "$resolved" "/bin/$tool" || true; done; dpkg-query -W mount util-linux; stat -c "%a %u:%g %n" /usr/sbin/minstall; mount --version'
printf 'demo\n' | sudo -S sh -c "$root_inventory" > evidence/install/root-inherited-toolchain.txt 2>&1
printf 'demo\n' | sudo -S env PATH=/usr/bin:/usr/sbin:/usr/local/bin sh -c "$root_inventory" > evidence/install/root-launcher-toolchain.txt 2>&1
# The original launcher owns authentication, automount, PATH and root runtime.
# QT accessibility instrumentation is propagated by its existing QT_ allowlist.
QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 /usr/bin/minstall-launcher > evidence/install/installer-output.log 2>&1 &
launcher_job=$!
tail -n +1 -F evidence/install/installer-output.log &
tail_job=$!
finish_observation() {
  kill "$tail_job" 2>/dev/null || true
  if test -n "${trace_actual_pid:-}" && test "$trace_actual_pid" -gt 1; then
    printf 'demo\n' | sudo -S kill -INT "$trace_actual_pid" 2>/dev/null || true
    if test -n "${trace_job:-}"; then wait "$trace_job" || true; fi
    printf 'demo\n' | sudo -S sh -c 'pid="$1"; date -u; cat "/proc/$pid/status" "/proc/$pid/mountinfo"; readlink "/proc/$pid/ns/mnt"; readlink "/proc/$pid/ns/user"; findmnt -T /mnt -o SOURCE,TARGET,FSTYPE,OPTIONS; findmnt -T /mnt/antiX -o SOURCE,TARGET,FSTYPE,OPTIONS || true; stat -Lc "%a %u:%g %n" /mnt /mnt/antiX /dev/vda /dev/vda1 2>/dev/null || true' detach "$trace_installer_pid" > evidence/install/trace-detached-target-state.txt 2>&1 || true
  fi
  printf 'demo\n' | sudo -S cat /var/log/minstall.log > evidence/install/minstall-final.log 2>&1 || true
  printf 'demo\n' | sudo -S sh -c 'date -u; ps -eo pid,ppid,uid,euid,args; findmnt /mnt/antiX || true; stat -Lc "%a %u:%g %n" /mnt /mnt/antiX /dev/vda /dev/vda1 2>/dev/null || true' > evidence/install/final-process-mount-state.txt 2>&1 || true
  scrot evidence/install/final-gui.png || true
  touch evidence/install/observation-finished
}
trap finish_observation EXIT
if test "${INSTALLER_TRACE:-0}" = 1; then
  trace_ready_deadline=$((SECONDS + 30))
  trace_installer_pid=
  while (( SECONDS < trace_ready_deadline )); do
    trace_installer_pid=$(pgrep -x minstall | head -1 || true)
    if test -n "$trace_installer_pid"; then break; fi
    sleep 0.2
  done
  test -n "$trace_installer_pid"
  { strace --version; dpkg-query -W strace mount util-linux; } > evidence/install/trace-tool-identity.txt
  printf 'demo\n' | sudo -S sh -c 'pid="$1"; cat "/proc/$pid/status" "/proc/$pid/mountinfo"; readlink "/proc/$pid/ns/mnt"; readlink "/proc/$pid/ns/user"; findmnt -T /mnt -o SOURCE,TARGET,FSTYPE,OPTIONS; findmnt -T /mnt/antiX -o SOURCE,TARGET,FSTYPE,OPTIONS || true; stat -Lc "%a %u:%g %n" /mnt /mnt/antiX 2>/dev/null || true' trace "$trace_installer_pid" > evidence/install/trace-before-state.txt 2>&1
  # Attach only after the original launcher has completed native authentication.
  # Follow real child exec/credentials and target creation/mount syscalls.
  printf 'demo\n' | sudo -S timeout --signal=INT --kill-after=5s 120s strace -ff -ttt -T -s 256 -e trace=%process,%creds,mount,mkdir,mkdirat,setns,unshare,newfstatat,stat,statx,write,writev -p "$trace_installer_pid" -o "$HOME/evidence/install/child-trace" > evidence/install/trace-attach.log 2>&1 &
  trace_job=$!
  trace_actual_pid=
  trace_ready_deadline=$((SECONDS + 10))
  while (( SECONDS < trace_ready_deadline )); do
    trace_actual_pid=$(printf 'demo\n' | sudo -S awk '/^TracerPid:/ {print $2}' "/proc/$trace_installer_pid/status")
    if test -n "$trace_actual_pid" && test "$trace_actual_pid" -gt 1; then break; fi
    sleep 0.2
  done
  if ! test -n "$trace_actual_pid" || ! test "$trace_actual_pid" -gt 1; then exit 1; fi
  printf 'demo\n' | sudo -S sh -c 'cat "/proc/$1/status"; tr "\0" " " < "/proc/$2/cmdline"; printf "\n"' attached "$trace_installer_pid" "$trace_actual_pid" > evidence/install/trace-attachment-confirmed.txt
  trace_case_deadline=$((SECONDS + 120))
fi
python3 "$HOME/mx-install-gui.py" --cloud-vm --evidence-dir "$HOME/evidence/install/gui" > evidence/install/gui-driver.log 2>&1 &
driver_job=$!
seen_pid=
while kill -0 "$driver_job" 2>/dev/null; do
  if test "${INSTALLER_TRACE:-0}" = 1 && (( SECONDS >= trace_case_deadline )); then
    kill "$driver_job" 2>/dev/null || true
    exit 1
  fi
  if grep -q 'FAILED Phase\|MANUALLY ABORTED' evidence/install/installer-output.log; then
    kill "$driver_job" 2>/dev/null || true
    exit 1
  fi
  installer_pid=$(pgrep -x minstall | head -1 || true)
  if test -n "$installer_pid" && test "$installer_pid" != "$seen_pid"; then
    seen_pid=$installer_pid
    printf 'demo\n' | sudo -S sh -c 'pid="$1"; date -u; cat "/proc/$pid/status"; readlink "/proc/$pid/exe"; readlink "/proc/$pid/cwd"; tr "\0" "\n" < "/proc/$pid/environ" | grep -E "^(PATH|HOME|XDG_RUNTIME_DIR|LANG|QT_LINUX_ACCESSIBILITY_ALWAYS_ON)="; for tool in /usr/bin/mount /bin/mount /usr/bin/umount /bin/umount; do readlink -f "$tool"; stat -Lc "%a %u:%g %n" "$tool"; done; stat -Lc "%a %u:%g %n" /mnt /mnt/antiX /dev/vda /dev/vda1 2>/dev/null || true' inventory "$installer_pid" > evidence/install/installer-process-inventory.txt 2>&1
  fi
  sleep 2
done
wait "$driver_job"
wait "$launcher_job"
# A native authentication policy may legitimately require no visible prompt.
# The original launcher and observed real installer must still establish root.
grep -Eq '^Uid:[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]*$' evidence/install/installer-process-inventory.txt
grep -Eq '^/usr/sbin/minstall$' evidence/install/installer-process-inventory.txt
grep -Eq '^\+\+[[:space:]]+Finished[[:space:]]+\+\+[[:space:]]*$' evidence/install/installer-output.log
if grep -q 'FAILED Phase\|MANUALLY ABORTED' evidence/install/installer-output.log; then exit 1; fi
finish_observation
trap - EXIT
cat evidence/install/installer-output.log
printf 'demo\n' | sudo -S poweroff
