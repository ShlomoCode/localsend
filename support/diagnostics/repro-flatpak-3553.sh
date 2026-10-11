#!/usr/bin/env bash
set -Eeuo pipefail

# Diagnostic reproduction for LocalSend 1.18.2 with host fontconfig caches.
REPO_ROOT="${GITHUB_WORKSPACE:-$PWD}"
OUT="${OUT:-$REPO_ROOT/evidence}"
TMP="${RUNNER_TEMP:-/tmp}"
mkdir -p "$OUT" "$OUT/cache-snapshots"
OUT="$(realpath "$OUT")"
exec > >(tee -a "$OUT/run.log") 2>&1

declare -a GROUP_PIDS=()
untrack_group() {
  local index
  for index in "${!GROUP_PIDS[@]}"; do
    if [[ "${GROUP_PIDS[$index]}" == "$1" ]]; then unset 'GROUP_PIDS[index]'; fi
  done
}
cleanup() {
  local p
  for p in "${GROUP_PIDS[@]:-}"; do
    kill -TERM -- "-$p" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  [[ -z "${XVFB_PID:-}" ]] || kill "$XVFB_PID" 2>/dev/null || true
  [[ -z "${OPENBOX_PID:-}" ]] || kill "$OPENBOX_PID" 2>/dev/null || true
}
trap cleanup EXIT

cache_dir="$HOME/.cache/fontconfig"
app_cache_dir="$HOME/.var/app/org.localsend.localsend_app/cache"
baseline="$OUT/cache-snapshots/baseline"
mkdir -p "$cache_dir"
fc-cache -f > "$OUT/host-fc-cache.txt" 2>&1 || true
fc-list : file | sort > "$OUT/host-font-inventory.txt"
fc-conflist > "$OUT/host-fontconfig-configs.txt" 2>&1 || true
cp -a "$cache_dir" "$baseline"

cache_manifest() {
  local target="$1" f
  mkdir -p "$target"
  : > "$target/manifest.txt"
  while IFS= read -r -d '' f; do
    cp -a "$f" "$target/" 2>/dev/null || true
    stat -c '%n %F %s bytes inode=%i links=%h %y' "$f" >> "$target/manifest.txt" 2>&1 || true
    if [[ -L "$f" ]]; then readlink "$f" >> "$target/manifest.txt"; fi
    sha256sum "$f" >> "$target/manifest.txt" 2>&1 || true
    od -An -tx1 -N32 "$f" >> "$target/manifest.txt" 2>&1 || true
  done < <(find "$cache_dir" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
  # upload-artifact dereferences symlinks; tar retains the original aliases.
  tar -czf "$target.tar.gz" -C "$cache_dir" .
}

save_app_cache() {
  mkdir -p "$app_cache_dir"
  tar -czf "$1" -C "$app_cache_dir" .
}

reset_app_cache() {
  save_app_cache "$OUT/app-cache-before-$1.tar.gz"
  rm -rf "$app_cache_dir"
  mkdir -p "$app_cache_dir"
}

restore_app_cache() {
  rm -rf "$app_cache_dir"
  mkdir -p "$app_cache_dir"
  if [[ "$suspect_cache_state" == warm ]]; then
    tar -xzf "$OUT/app-cache-before-warm-$suspect_version.tar.gz" -C "$app_cache_dir"
  fi
}

restore_brave_cache() {
  rm -rf "$cache_dir"
  mkdir -p "$cache_dir"
  tar -xzf "$OUT/cache-snapshots/brave-$1.tar.gz" -C "$cache_dir"
}

restore_baseline() {
  rm -rf "$cache_dir"
  mkdir -p "$(dirname "$cache_dir")"
  cp -a "$baseline" "$cache_dir"
}

find_localsend_pid() {
  local pid comm exe
  for pid in $(pgrep -x 'localsend(_app)?' 2>/dev/null || true); do
    comm=$(sudo cat "/proc/$pid/comm" 2>/dev/null || true)
    exe=$(sudo readlink "/proc/$pid/exe" 2>/dev/null || true)
    if [[ "$exe" == */localsend_app || "$exe" == */localsend ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

capture_case() {
  local pid="$1" dir="$2" start end started_ns ended_ns hz pct i
  started_ns=$(date +%s%N)
  start=$(sudo awk '{print $14+$15}' "/proc/$pid/task/$pid/stat" 2>/dev/null || echo 0)
  hz=$(getconf CLK_TCK)
  for ((i=0; i<12; i++)); do
    sudo awk '{print $14, $15}' "/proc/$pid/task/$pid/stat" >> "$dir/main-thread-cpu-ticks.txt" 2>/dev/null || break
    sleep 1
  done
  ended_ns=$(date +%s%N)
  end=$(sudo awk '{print $14+$15}' "/proc/$pid/task/$pid/stat" 2>/dev/null || echo "$start")
  pct=$(awk -v a="$start" -v b="$end" -v hz="$hz" -v s="$started_ns" -v e="$ended_ns" 'BEGIN {d=b-a; t=(e-s)/1e9; if(d<0||t<=0)d=0; else printf "%.1f", 100*d/(hz*t)}')
  printf '%s\n' "$pct" > "$dir/main-thread-cpu-percent.txt"
  printf 'CLK_TCK=%s elapsed_seconds=%.2f\n' "$hz" "$(awk -v s="$started_ns" -v e="$ended_ns" 'BEGIN {print (e-s)/1e9}')" > "$dir/sample.txt"
  sudo readlink -f "/proc/$pid/exe" > "$dir/exe.txt" 2>&1 || true
  sudo cat "/proc/$pid/maps" > "$dir/maps.txt" 2>&1 || true
  ps -eLo pid,tid,ppid,pgid,stat,pcpu,comm,args --sort=-pcpu > "$dir/ps.txt" 2>&1 || true
  xdotool search --onlyvisible --name '.*' 2>/dev/null | while read -r wid; do
    xprop -id "$wid" WM_NAME WM_CLASS _NET_WM_PID 2>/dev/null || true
  done > "$dir/windows.txt"
  import -window root "$dir/screenshot.png" 2>&1 || true
  ss -ltnp > "$dir/listeners.txt" 2>&1 || true
  sudo timeout 8s gdb -q -batch -ex 'set debuginfod enabled off' -ex 'set pagination off' -ex "set sysroot /proc/$pid/root" -ex "attach $pid" -ex 'thread apply all bt' -ex detach > "$dir/gdb.txt" 2>&1 || true
  printf '%s' "$pct"
}

launch_case() {
  local label="$1" command="$2" dir="$OUT/$1" pid app_pid result cpu windows port elapsed=0
  mkdir -p "$dir"
  echo "=== CASE $label ==="
  # A new session gives each case a private process group for bounded cleanup.
  setsid bash -c "$command" >"$dir/stdout.txt" 2>"$dir/stderr.txt" &
  pid=$!
  GROUP_PIDS+=("$pid")
  app_pid=""
  for ((elapsed=0; elapsed<20; elapsed++)); do
    app_pid=$(find_localsend_pid || true)
    [[ -n "$app_pid" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if [[ -z "$app_pid" ]]; then
    echo -e "$label\tinfrastructure_failure_no_executable\t\t\t$dir" >> "$OUT/summary.tsv"
    echo "No LocalSend executable process found for $label (launcher pid $pid)"
    ps -eLo pid,tid,ppid,pgid,stat,pcpu,comm,args --sort=-pcpu > "$dir/ps.txt" 2>&1 || true
    { xdotool search --onlyvisible --name '.*' 2>/dev/null || true; } | while read -r wid; do
      xprop -id "$wid" WM_NAME WM_CLASS _NET_WM_PID 2>/dev/null || true
    done > "$dir/windows.txt"
    import -window root "$dir/screenshot.png" 2>&1 || true
    ss -ltnp > "$dir/listeners.txt" 2>&1 || true
    if kill -0 "$pid" 2>/dev/null; then echo timeout > "$dir/launcher-result.txt"
    else
      local launcher_exit=0
      wait "$pid" 2>/dev/null || launcher_exit=$?
      echo "exit=$launcher_exit" > "$dir/launcher-result.txt"
    fi
    kill -TERM -- "-$pid" 2>/dev/null || true
    timeout 4s tail --pid="$pid" -f /dev/null 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    untrack_group "$pid"
    return 0
  fi
  echo "$app_pid" > "$dir/localsend.pid"
  cpu=$(capture_case "$app_pid" "$dir")
  windows=$(wc -l < "$dir/windows.txt" | tr -d ' ')
  port=$(grep -c '53317' "$dir/listeners.txt" || true)
  local app_windows=0 black_window=0 wid window_pid mean window_title
  while read -r wid; do
    window_pid=$(xprop -id "$wid" _NET_WM_PID 2>/dev/null | sed -n 's/.*= //p')
    window_title=$(xdotool getwindowname "$wid" 2>/dev/null || true)
    # Flatpak's window PID is inside its namespace; the host PID may differ.
    [[ "$window_pid" == "$app_pid" || "$window_title" == *LocalSend* ]] || continue
    ((app_windows+=1))
    import -window "$wid" "$dir/window-$wid.png" 2>/dev/null || true
    mean=$(identify -format '%[fx:mean]' "$dir/window-$wid.png" 2>/dev/null || echo 1)
    if awk -v m="$mean" 'BEGIN {exit !(m<0.03)}'; then black_window=1; fi
  done < <(xdotool search --onlyvisible --name '.*' 2>/dev/null || true)
  local process_state
  process_state=$(sudo awk '{print $3}' "/proc/$app_pid/stat" 2>/dev/null || true)
  printf 'all_visible_windows=%s app_windows=%s black_app_window=%s app_port_53317=%s process_state=%s\n' "$windows" "$app_windows" "$black_window" "$port" "$process_state" > "$dir/ui-state.txt"
  if [[ -z "$process_state" || "$process_state" == Z || "$process_state" == X ]]; then
    result=infrastructure_failure_exited_during_capture
    if kill -0 "$pid" 2>/dev/null; then
      echo running > "$dir/launcher-result.txt"
    else
      local capture_launcher_exit=0
      wait "$pid" 2>/dev/null || capture_launcher_exit=$?
      echo "exit=$capture_launcher_exit" > "$dir/launcher-result.txt"
    fi
  elif [[ "$app_windows" -gt 0 && "$port" -gt 0 ]]; then result=started
  elif [[ "$port" -eq 0 && ( "$app_windows" -eq 0 || "$black_window" -eq 1 ) ]] && awk -v p="$cpu" 'BEGIN {exit !(p>=80)}'; then result=hang_candidate
  else result=started_or_slow
  fi
  echo -e "$label\t$result\t$app_pid\t$cpu\t$dir" >> "$OUT/summary.tsv"
  echo "Result: $label $result; executable pid=$app_pid main-thread CPU=${cpu}% windows=$windows port53317=$port"
  kill -TERM -- "-$pid" 2>/dev/null || true
  kill -TERM "$app_pid" 2>/dev/null || true
  timeout 4s tail --pid="$pid" -f /dev/null 2>/dev/null || true
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  untrack_group "$pid"
}

wait_for_window() {
  local label="$1" i window
  for ((i=0; i<20; i++)); do
    window=$(xdotool search --onlyvisible --class '[Bb]rave-browser' 2>/dev/null | sed -n '1p' || true)
    if [[ -n "$window" ]]; then return 0; fi
    sleep 1
  done
  echo "Brave window did not appear for $label" | tee -a "$OUT/infrastructure-failures.txt"
  return 1
}

environment() {
  {
    date -u --iso-8601=seconds
    uname -a
    locale
    printf 'GUI_MODE=%s DISPLAY=%s XDG_CURRENT_DESKTOP=%s XDG_SESSION_TYPE=%s\n' "${GUI_MODE:-virtual}" "${DISPLAY:-}" "${XDG_CURRENT_DESKTOP:-}" "${XDG_SESSION_TYPE:-}"
    cat /etc/os-release
    dpkg-query -W -f='${Package} ${Version}\n' flatpak fontconfig xvfb openbox dbus-x11 imagemagick xdotool gdb strace 2>/dev/null || true
    fc-cache --version 2>&1 || true
    flatpak --version 2>&1 || true
    flatpak --user info org.localsend.localsend_app 2>&1 || true
    flatpak --user info --show-runtime org.localsend.localsend_app 2>&1 || true
    flatpak --user info --show-commit org.localsend.localsend_app 2>&1 || true
    flatpak run --user --command=fc-cache org.localsend.localsend_app --version 2>&1 || true
    flatpak run --user --command=sh org.localsend.localsend_app -c 'printf "LANG=%s LC_ALL=%s LANGUAGE=%s\n" "$LANG" "$LC_ALL" "$LANGUAGE"; locale' 2>&1 || true
    printf 'Expected app commit: %s\n' "${EXPECTED_APP_COMMIT:-not-provided}"
    printf 'Expected runtime commit: %s\n' "${EXPECTED_RUNTIME_COMMIT:-not-provided}"
  } > "$OUT/environment.txt"
}

printf 'case\tresult\tpid\tmain_thread_cpu_percent\tevidence_dir\n' > "$OUT/summary.tsv"
cat > "$OUT/font-cache-prime.html" <<'HTML'
<!doctype html><meta charset="utf-8"><style>body{font:24px sans-serif}p{font-family:serif}</style>
<h1>LocalSend font cache reproduction</h1><p>Brave host fontconfig cache priming: abcdefghijklmnopqrstuvwxyz 0123456789</p>
HTML

echo 'Fetching and installing the official LocalSend 1.18.2 deb.'
deb="$TMP/LocalSend-1.18.2-linux-x86-64.deb"
curl --fail --location --retry 3 'https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-linux-x86-64.deb' -o "$deb"
sha256sum "$deb" > "$OUT/localsend-deb-sha256.txt"
dpkg-deb -I "$deb" > "$OUT/localsend-deb-control.txt"
deb_package=$(dpkg-deb -f "$deb" Package)
sudo apt-get install -y "$deb"
dpkg-query -L "$deb_package" > "$OUT/localsend-deb-files.txt" 2>&1 || true
deb_exe=""
while IFS= read -r candidate; do
  if [[ "$candidate" == */localsend_app && -f "$candidate" && -x "$candidate" ]]; then
    deb_exe="$candidate"
    break
  fi
done < "$OUT/localsend-deb-files.txt"
if [[ -z "$deb_exe" || ! -x "$deb_exe" ]]; then
  echo 'Could not find installed LocalSend executable from dpkg -L.' | tee -a "$OUT/infrastructure-failures.txt"
  exit 2
fi
printf '%s\n' "$deb_exe" > "$OUT/localsend-deb-executable.txt"
rm -f "$deb"

flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user --noninteractive -y flathub org.localsend.localsend_app
runtime_branch="${RUNTIME_BRANCH:-26.08}"
flatpak install --user --noninteractive -y flathub "org.freedesktop.Platform/x86_64/$runtime_branch"
flatpak update --user --noninteractive -y --commit="$EXPECTED_RUNTIME_COMMIT" "org.freedesktop.Platform/x86_64/$runtime_branch"
flatpak update --user --noninteractive -y --commit="$EXPECTED_APP_COMMIT" org.localsend.localsend_app
environment
actual_app_commit=$(flatpak info --user --show-commit org.localsend.localsend_app)
actual_runtime_ref=$(flatpak info --user --show-runtime org.localsend.localsend_app)
actual_runtime_commit=$(flatpak info --user --show-commit "$actual_runtime_ref")
if [[ "$actual_app_commit" != "${EXPECTED_APP_COMMIT:-a7a6bc3f9debbbfd90c2e8874a83a5606db10b53dffc187449b0684991e7740c}" || \
      "$actual_runtime_commit" != "${EXPECTED_RUNTIME_COMMIT:-92659297ffdb4f9f14dd1562bd919b48160b0dc42c99653dcfc0688096af41df}" || \
      "$actual_runtime_ref" != "org.freedesktop.Platform/x86_64/$runtime_branch" ]]; then
  printf 'Expected app/runtime commits differ: app=%s runtime=%s\n' "$actual_app_commit" "$actual_runtime_commit" | tee -a "$OUT/infrastructure-failures.txt"
  exit 5
fi

case "${GUI_MODE:-virtual}" in
  virtual)
    export DISPLAY=:99
    Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 & XVFB_PID=$!
    sleep 2
    openbox > "$OUT/openbox.log" 2>&1 & OPENBOX_PID=$!
    sleep 2
    dbus-update-activation-environment DISPLAY
    ;;
  native)
    # Use the existing Cinnamon display and session bus supplied by the guest.
    if [[ -z "${DISPLAY:-}" || -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || ! xdpyinfo > "$OUT/native-display.txt" 2>&1; then
      echo 'Native GUI requires a working display and desktop session bus.' | tee -a "$OUT/infrastructure-failures.txt"
      exit 8
    fi
    ;;
  *)
    echo "Unknown GUI_MODE: $GUI_MODE" | tee -a "$OUT/infrastructure-failures.txt"
    exit 8
    ;;
esac

flatpak run --user --command=sh org.localsend.localsend_app -c 'printf "XDG_CACHE_HOME=%s FONTCONFIG_FILE=%s\n" "$XDG_CACHE_HOME" "$FONTCONFIG_FILE"; cat /etc/fonts/conf.d/50-flatpak.conf; ls -l /run/host/user-fonts-cache' > "$OUT/flatpak-fontconfig-host-cache.txt" 2>&1
flatpak run --user --command=sh org.localsend.localsend_app -c 'find /run/host/user-fonts /run/host/fonts -type f 2>/dev/null | sort' > "$OUT/flatpak-host-font-inventory.txt" 2>&1 || true

launch_case clean_deb "$deb_exe"
if ! awk -F '\t' '$1=="clean_deb" && $2=="started" {found=1} END {exit !found}' "$OUT/summary.tsv"; then
  echo 'Known-working deb control did not start; repair the GUI harness first.' | tee -a "$OUT/infrastructure-failures.txt"
  exit 7
fi

launch_case clean_flatpak 'flatpak run --user org.localsend.localsend_app'
save_app_cache "$OUT/app-cache-warm-baseline.tar.gz"
suspect_version=""
suspect_cache_state=""

for version in 1.96.61 1.96.59; do
  restore_baseline
  rm -rf "$app_cache_dir"
  mkdir -p "$app_cache_dir"
  tar -xzf "$OUT/app-cache-warm-baseline.tar.gz" -C "$app_cache_dir"
  brave_deb="$TMP/brave-browser_${version}_amd64.deb"
  curl --fail --location --retry 3 "https://github.com/brave/brave-browser/releases/download/v${version}/brave-browser_${version}_amd64.deb" -o "$brave_deb"
  sha256sum "$brave_deb" >> "$OUT/brave-deb-sha256.txt"
  sudo apt-get install -y --allow-downgrades "$brave_deb"
  dpkg-query -W -f='${Package} ${Version}\n' brave-browser >> "$OUT/brave-package-versions.txt" 2>&1 || true
  rm -f "$brave_deb"
  profile="$TMP/brave-profile-$version"
  cache_manifest "$OUT/cache-snapshots/before-brave-$version"
  mkdir -p "$profile"
  setsid brave-browser --no-first-run --no-default-browser-check --disable-background-networking \
    --user-data-dir="$profile" --window-size=1000,700 "file://$OUT/font-cache-prime.html" >"$OUT/brave-$version.stdout.txt" 2>"$OUT/brave-$version.stderr.txt" &
  brave_pid=$!; GROUP_PIDS+=("$brave_pid")
  if ! wait_for_window "$version"; then
    echo -e "brave_$version\tinfrastructure_failure_no_window\t$brave_pid\t\t$OUT" >> "$OUT/summary.tsv"
    exit 3
  fi
  sleep 8
  import -window root "$OUT/brave-$version.png" 2>/dev/null || true
  kill -TERM -- "-$brave_pid" 2>/dev/null || true
  timeout 4s tail --pid="$brave_pid" -f /dev/null 2>/dev/null || true
  kill -KILL -- "-$brave_pid" 2>/dev/null || true
  wait "$brave_pid" 2>/dev/null || true
  untrack_group "$brave_pid"

  # Brave writes its normal host cache in place; no cache bytes are fabricated.
  if ! find "$cache_dir" -maxdepth 1 -name '*cache-12' -type f -print -quit | grep -q .; then
    echo "Brave $version did not generate host fontconfig cache files" | tee -a "$OUT/infrastructure-failures.txt"
    exit 4
  fi
  cache_manifest "$OUT/cache-snapshots/brave-$version"
  save_app_cache "$OUT/app-cache-before-warm-$version.tar.gz"
  launch_case "flatpak_after_brave_$version" 'flatpak run --user org.localsend.localsend_app'
  if awk -F '\t' -v label="flatpak_after_brave_$version" '$1==label && $2=="hang_candidate" {found=1} END {exit !found}' "$OUT/summary.tsv"; then
    suspect_version="$version"
    suspect_cache_state=warm
  fi
  restore_brave_cache "$version"
  reset_app_cache "cold-$version"
  launch_case "flatpak_cold_cache_after_brave_$version" 'flatpak run --user org.localsend.localsend_app'
  if awk -F '\t' -v label="flatpak_cold_cache_after_brave_$version" '$1==label && $2=="hang_candidate" {found=1} END {exit !found}' "$OUT/summary.tsv"; then
    suspect_version="$version"
    suspect_cache_state=cold
  fi
  launch_case "deb_after_brave_$version" "$deb_exe"
  cache_snapshot="$OUT/cache-snapshots/active-$version"
  cache_manifest "$cache_snapshot"
  restore_baseline
done

if [[ -n "$suspect_version" ]]; then
  # Move generated cache aside as one unit, test empty, then restore the exact bytes.
  printf 'version=%s app_cache=%s\n' "$suspect_version" "$suspect_cache_state" > "$OUT/suspect.txt"
  restore_brave_cache "$suspect_version"
  restore_app_cache
  launch_case flatpak_suspect_repeat 'flatpak run --user org.localsend.localsend_app'
  cache_manifest "$OUT/cache-snapshots/retry-suspect"
  moved="$OUT/cache-snapshots/moved-aside"
  rm -rf "$moved"
  mv "$cache_dir" "$moved"
  mkdir -p "$cache_dir"
  restore_app_cache
  launch_case flatpak_after_cache_moved 'flatpak run --user org.localsend.localsend_app'
  rm -rf "$cache_dir"
  mkdir -p "$cache_dir"
  cp -a "$moved"/. "$cache_dir/"
  cache_manifest "$OUT/cache-snapshots/restored"
  restore_app_cache
  launch_case flatpak_after_cache_restore 'flatpak run --user org.localsend.localsend_app'
  restore_brave_cache "$suspect_version"
  restore_app_cache
  launch_case flatpak_after_cache_restore_repeat 'flatpak run --user org.localsend.localsend_app'
  restore_baseline
fi

environment
if grep -q 'infrastructure_failure' "$OUT/summary.tsv"; then
  echo 'One or more cases failed to launch; see infrastructure failure rows and evidence.'
  exit 6
fi
echo 'Reproduction run complete.'
