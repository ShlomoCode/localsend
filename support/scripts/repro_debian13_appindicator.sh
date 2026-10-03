#!/usr/bin/env bash
# Historical reproduction of the released 1.17.0 amd64 Debian package.
# Run in a fresh debian:13 container for each case; see the companion workflow.
set -euo pipefail

case "${1:-}" in
  control|legacy) case_name=$1 ;;
  *) echo 'Usage: repro_debian13_appindicator.sh control|legacy' >&2; exit 2 ;;
esac

export DEBIAN_FRONTEND=noninteractive
exec > >(tee "reproduction/$case_name.log") 2>&1
cat /etc/os-release
test "$(dpkg --print-architecture)" = amd64
apt-get update
apt-get install -y --no-install-recommends ca-certificates xvfb xauth xdotool

if [[ $case_name == control ]]; then
  apt-get install -y --no-install-recommends libayatana-appindicator3-1
else
  # Debian 13 no longer distributes the legacy library. Seed the real Buster
  # packages to model libraries retained across an upgrade, without faking them.
  echo 'deb [check-valid-until=no] https://archive.debian.org/debian buster main' \
    > /etc/apt/sources.list.d/legacy-appindicator.list
  cat > /etc/apt/preferences.d/legacy-appindicator <<'EOF'
Package: *
Pin: release n=buster
Pin-Priority: 100
EOF
  apt-get update
  apt-get install -y --no-install-recommends libappindicator3-1/buster gir1.2-appindicator3-0.1/buster
fi

package=/work/reproduction/LocalSend-1.17.0-linux-x86-64.deb
dpkg-deb -f "$package" Package Version Architecture Depends
apt-get install -y --no-install-recommends "$package"
apt-get check
dpkg-query -W -f='${Package} ${Version} ${Status}\n' '*appindicator*'
binary=$(readlink -f "$(command -v localsend_app)")
ldd "$binary" || true

if [[ $case_name == legacy ]]; then
  test "$(dpkg-query -W -f='${Status}' libappindicator3-1)" = 'install ok installed'
  if dpkg-query -W -f='${Status}' libayatana-appindicator3-1 2>/dev/null | grep -qx 'install ok installed'; then
    echo 'Harness error: Ayatana was installed; the reported environment was not reproduced.'
    exit 2
  fi
fi

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
      exit $?
    fi
    if xdotool search --onlyvisible --pid "$app_pid" >/dev/null 2>&1; then
      echo "Application window appeared (PID $app_pid)."
      exit 0
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
