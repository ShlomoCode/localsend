#!/usr/bin/env bash
# Reproduce startup with declared dependencies of a released amd64 Debian package.
# Run in a fresh debian:13 container for each case; see the companion workflow.
set -euo pipefail

case "${1:-}" in
  control|legacy) case_name=$1 ;;
  *) echo 'Usage: repro_debian13_appindicator.sh control|legacy [absolute-deb-path]' >&2; exit 2 ;;
esac
package=${2:-/work/reproduction/LocalSend-1.17.0-linux-x86-64.deb}
test -f "$package"

export DEBIAN_FRONTEND=noninteractive
exec > >(tee "reproduction/$case_name.log") 2>&1
cat /etc/os-release
test "$(dpkg --print-architecture)" = amd64
apt-get update
# Recent Flutter engines load EGL dynamically; a desktop supplies these libraries.
apt-get install -y --no-install-recommends ca-certificates xvfb xauth xdotool libegl1 libegl-mesa0 libgles2

if [[ $case_name == control ]]; then
  apt-get install -y --no-install-recommends libayatana-appindicator3-1
else
  # Debian 13 no longer distributes the legacy library. Seed the real Buster
  # packages to model libraries retained across an upgrade, without faking them.
  echo 'deb [check-valid-until=no] https://archive.debian.org/debian buster main' \
    > /etc/apt/sources.list.d/legacy-appindicator.list
  # Bookworm supplies the transitional pixbuf package retained during upgrades.
  echo 'deb https://deb.debian.org/debian bookworm main' \
    > /etc/apt/sources.list.d/bookworm-compat.list
  cat > /etc/apt/preferences.d/legacy-appindicator <<'EOF'
Package: *
Pin: release n=buster
Pin-Priority: 100

Package: *
Pin: release n=bookworm
Pin-Priority: 100
EOF
  apt-get update
  apt-get install -y --no-install-recommends libgtk-3-0t64 libgdk-pixbuf-2.0-0
  apt-get install -y --no-install-recommends libappindicator3-1=0.4.92-7 gir1.2-appindicator3-0.1=0.4.92-7
  test "$(dpkg-query -W -f='${Status}' libappindicator3-1)" = 'install ok installed'
  if dpkg-query -W -f='${Status}' libayatana-appindicator3-1 2>/dev/null | grep -qx 'install ok installed'; then
    echo 'Harness error: Ayatana was installed before LocalSend; the reported environment was not reproduced.'
    exit 2
  fi
fi

dpkg-deb -f "$package" Package Version Architecture Depends
apt-get install -y --no-install-recommends "$package"
apt-get check
dpkg-query -W -f='${Package} ${Version} ${Status}\n' '*appindicator*'
binary=$(readlink -f "$(command -v localsend_app)")
ldd "$binary" || true

# The control must create a real app window, not merely avoid the loader error.
# xvfb-run gives both cases the same display environment.
set +e
xvfb-run -a bash -c '
  "$1" > "$2" 2>&1 &
  app_pid=$!
  trap "kill $app_pid 2>/dev/null || true" EXIT
  for attempt in {1..30}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      wait "$app_pid"
      app_status=$?
      if [[ $app_status == 0 ]]; then
        echo "Application exited without a stable window."
        exit 2
      fi
      exit "$app_status"
    fi
    if xdotool search --onlyvisible --pid "$app_pid" >/dev/null 2>&1; then
      sleep 2
      if kill -0 "$app_pid" 2>/dev/null && xdotool search --onlyvisible --pid "$app_pid" >/dev/null 2>&1; then
        echo "Application window appeared and remained active (PID $app_pid)."
        exit 0
      fi
    fi
    sleep 1
  done
  echo "Application did not create a window within 30 seconds."
  exit 2
' bash "$binary" "/work/reproduction/$case_name-startup.log"
status=$?
set -e
cat "reproduction/$case_name-startup.log"

if [[ $case_name == legacy ]] &&
    grep -Fq 'error while loading shared libraries: libayatana-appindicator3.so.1: cannot open shared object file' \
      "reproduction/$case_name-startup.log"; then
  echo '::error::Regression reproduced: APT accepted the declared dependencies, but LocalSend cannot load libayatana-appindicator3.so.1.'
  exit 1
fi

if [[ $status != 0 ]]; then
  echo "Harness/startup failure: exit $status; inspect the startup log."
  exit 2
fi
echo "PASS: $case_name installation starts successfully."
