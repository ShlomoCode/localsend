#!/usr/bin/env bash
# Mapping infrastructure only: installed package's diagnostic shell, no app UI.
set -Eeuo pipefail
[[ $# = 3 ]] || { printf 'usage: bash mapping-probe.sh OUT PREDICATE EXPECTED_APP_COMMIT\n' >&2; exit 2; }
OUT=$1
PREDICATE=$2
EXPECTED_APP_COMMIT=$3
APP=org.localsend.localsend_app
[[ $OUT = /* && $PREDICATE = /* && $EXPECTED_APP_COMMIT =~ ^[0-9a-f]{64}$ ]]
[[ $(id -un) = mint && $HOME = /home/mint ]]
[[ ! -e $OUT ]]
mkdir -p "$OUT"
exec 9>"$OUT/trace.txt"
BASH_XTRACEFD=9
set -x
case_deadline=0
launch_pid=''
launch_ticks=''
finish() {
  local result=$? current_ticks cleanup_deadline
  set +e
  printf 'probe_exit=%s\n' "$result" > "$OUT/result.txt"
  if [ -n "$launch_pid" ] && [ -e "/proc/$launch_pid/stat" ]; then
    current_ticks=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$launch_pid/stat")
    if [[ -n $launch_ticks && $current_ticks = "$launch_ticks" ]]; then
      # Signal only this owned timeout PID. timeout forwards TERM to its own
      # Flatpak launch. Keep its 35-second timer alive if shutdown is incomplete.
      kill -TERM "$launch_pid"
      cleanup_deadline=$((SECONDS+3))
      while [[ $SECONDS -lt $cleanup_deadline && -e /proc/$launch_pid/stat ]]; do sleep .1; done
      if [[ -e /proc/$launch_pid/stat ]]; then
        printf 'owned_launch_shutdown=incomplete pid=%s start=%s; no further wait; original timeout retained\n' "$launch_pid" "$launch_ticks" >> "$OUT/result.txt"
      else
        printf 'owned_launch_shutdown=exited pid=%s start=%s\n' "$launch_pid" "$launch_ticks" >> "$OUT/result.txt"
      fi
    else
      printf 'owned_launch_shutdown=unqualified pid=%s; no signal or wait\n' "$launch_pid" >> "$OUT/result.txt"
    fi
  fi
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
run() {
  local left=$((case_deadline-SECONDS))
  [[ $left -gt 0 ]] || return 124
  [[ $left -le 5 ]] || left=5
  timeout --foreground -s KILL "$left" "$@"
}
no_instance() {
  local rows
  rows=$(run flatpak ps --columns=application)
  ! [[ $rows = *"$APP"* ]]
}
installed_commit() {
  [[ $(run flatpak info --user --show-commit "$APP") = "$EXPECTED_APP_COMMIT" ]]
}
wait_stage() {
  local stage=$1 result
  while [[ $SECONDS -lt $case_deadline ]]; do
    result=0
    run grep -qx "stage=$stage" "$case_out/sandbox.log" || result=$?
    if [[ $result = 0 ]]; then return; fi
    [[ $result = 1 ]] || return "$result"
    kill -0 "$launch_pid" || return 1
    sleep .1
  done
  return 124
}
qualify_shell() {
  local sandbox_pid rows instance anchor descendants pid count=0 actual expected last_pid ticks
  sandbox_pid=$(run awk -F= '$1=="diagnostic_shell_pid" {print $2}' "$case_out/sandbox.log")
  [[ $sandbox_pid =~ ^[0-9]+$ ]]
  run flatpak ps --columns=instance,application,pid > "$case_out/instances.txt"
  run ps -u "$(id -u)" -o pid=,ppid=,uid=,comm= > "$case_out/topology.txt"
  rows=$(run awk -v app="$APP" '$2==app {print $1,$3}' "$case_out/instances.txt")
  [[ -n $rows ]]
  while read -r instance anchor; do
    [[ $instance =~ ^[0-9]+$ && $anchor =~ ^[0-9]+$ ]]
    descendants=$(run awk -v anchor="$anchor" '{parent[$1]=$2} END {for(pid in parent){p=pid;for(n=0;n<1024 && p in parent;n++){if(p==anchor){print pid;break}p=parent[p]}}}' "$case_out/topology.txt")
    for pid in $descendants; do
      # Topology excludes unrelated namespaces; match actual /usr/bin/sh inode.
      actual=$(run sudo -n stat -Lc '%d:%i' "/proc/$pid/exe")
      if run sudo -n test ! -e "/proc/$pid/root/usr/bin/sh"; then continue; fi
      expected=$(run sudo -n stat -Lc '%d:%i' "/proc/$pid/root/usr/bin/sh")
      [[ $actual = "$expected" ]] || continue
      run sudo -n cat "/proc/$pid/status" > "$case_out/shell-$pid-status.txt"
      last_pid=$(run awk '/^NSpid:/ {print $NF}' "$case_out/shell-$pid-status.txt")
      [[ $last_pid = "$sandbox_pid" ]] || continue
      run sudo -n cat "/proc/$pid/root/.flatpak-info" > "$case_out/shell-$pid-flatpak-info.txt"
      run awk -v instance="$instance" -v commit="$EXPECTED_APP_COMMIT" '
        /^\[/ {section=$0}
        section=="[Application]" && $0=="name=org.localsend.localsend_app" {app++}
        section=="[Instance]" && $0=="instance-id=" instance {matched++}
        section=="[Instance]" && $0=="app-commit=" commit {immutable++}
        END {exit !(app==1 && matched==1 && immutable==1)}
      ' "$case_out/shell-$pid-flatpak-info.txt"
      run awk -v uid="$(id -u)" '/^Uid:/ {matched=($2==uid && $3==uid && $4==uid && $5==uid)} END {exit !matched}' "$case_out/shell-$pid-status.txt"
      count=$((count+1))
      qualified_pid=$pid
      qualified_exe=$actual
      run sudo -n cat "/proc/$pid/stat" > "$case_out/shell-$pid-stat.txt"
      ticks=$(run awk '{sub(/^.*\) /,"");print $20}' "$case_out/shell-$pid-stat.txt")
      [[ $ticks =~ ^[0-9]+$ ]]
      qualified_ticks=$ticks
      run sudo -n readlink "/proc/$pid/ns/mnt" > "$case_out/shell-$pid-mount-namespace.txt"
      run sudo -n readlink "/proc/$pid/ns/pid" > "$case_out/shell-$pid-pid-namespace.txt"
      printf 'instance=%s anchor=%s host_pid=%s sandbox_pid=%s start=%s exe=%s\n' "$instance" "$anchor" "$pid" "$sandbox_pid" "$ticks" "$actual" > "$case_out/qualified-shell.txt"
    done
  done <<< "$rows"
  [[ $count = 1 ]]
  installed_commit
}
host_snapshot() {
  local stage=$1 ticks inode digest
  run sudo -n cat "/proc/$qualified_pid/stat" > "$case_out/$stage-shell-stat.txt"
  ticks=$(run awk '{sub(/^.*\) /,"");print $20}' "$case_out/$stage-shell-stat.txt")
  [[ $ticks = "$qualified_ticks" ]]
  [[ $(run sudo -n stat -Lc '%d:%i' "/proc/$qualified_pid/exe") = "$qualified_exe" ]]
  run sudo -n cat "/proc/$qualified_pid/root/.flatpak-info" > "$case_out/$stage-effective-info.txt"
  run sudo -n cat "/proc/$qualified_pid/mountinfo" > "$case_out/$stage-mountinfo.txt"
  run cmp "$case_out/shell-$qualified_pid-flatpak-info.txt" "$case_out/$stage-effective-info.txt"
  run sudo -n readlink "/proc/$qualified_pid/ns/mnt" > "$case_out/$stage-mount-namespace.txt"
  run cmp "$case_out/shell-$qualified_pid-mount-namespace.txt" "$case_out/$stage-mount-namespace.txt"
  if [[ $case_kind = revoked ]]; then
    run stat -Lc '%d:%i' "$private_config/autostart/localsend_app.desktop" > "$case_out/$stage-private-entry-identity.txt"
    run sha256sum "$private_config/autostart/localsend_app.desktop" > "$case_out/$stage-private-entry-sha256.txt"
    inode=$(run cat "$case_out/$stage-private-entry-identity.txt")
    digest=$(run awk '{print $1}' "$case_out/$stage-private-entry-sha256.txt")
    run grep -qx "$stage-entry-identity=$inode" "$case_out/sandbox.log"
    run grep -qx "$stage-entry-sha256=$digest" "$case_out/sandbox.log"
    run test ! -e "$HOME/.config/autostart/localsend_app.desktop"
    return
  fi
  run stat -Lc '%d:%i' "$host_config/autostart/$marker" > "$case_out/$stage-host-marker-identity.txt"
  run sha256sum "$host_config/autostart/$marker" > "$case_out/$stage-host-marker-sha256.txt"
  inode=$(run cat "$case_out/$stage-host-marker-identity.txt")
  digest=$(run awk '{print $1}' "$case_out/$stage-host-marker-sha256.txt")
  run grep -qx "$stage-marker-identity=$inode" "$case_out/sandbox.log"
  run grep -qx "$stage-marker-sha256=$digest" "$case_out/sandbox.log"
  if [[ $stage = after ]]; then
    inode=$(run stat -Lc '%d:%i' "$host_config/autostart/localsend_app.desktop")
    digest=$(run sha256sum "$host_config/autostart/localsend_app.desktop")
    digest=${digest%% *}
    run grep -qx "after-entry-identity=$inode" "$case_out/sandbox.log"
    run grep -qx "after-entry-sha256=$digest" "$case_out/sandbox.log"
  else
    run test ! -e "$host_config/autostart/localsend_app.desktop"
  fi
}
make_payload() {
  run cat "$PREDICATE" > "$case_out/payload.sh"
  cat >> "$case_out/payload.sh" <<'SANDBOX'
set -eu
kind=$1
marker=$2
printf 'diagnostic_shell_pid=%s\nHOME=%s\nXDG_CONFIG_HOME=%s\n' "$$" "$HOME" "${XDG_CONFIG_HOME:-}"
snapshot() {
  stage=$1
  printf '%s-info-begin\n' "$stage"
  cat /.flatpak-info
  printf '%s-info-end\n%s-mountinfo-begin\n' "$stage" "$stage"
  cat /proc/self/mountinfo
  printf '%s-mountinfo-end\n%s-' "$stage" "$stage"
  issue1927_mapping_status
  if [ "$kind" != revoked ]; then
    printf '%s-marker-identity=%s\n' "$stage" "$(stat -Lc '%d:%i' "$XDG_CONFIG_HOME/autostart/$marker")"
    digest=$(sha256sum "$XDG_CONFIG_HOME/autostart/$marker")
    printf '%s-marker-sha256=%s\n' "$stage" "${digest%% *}"
  fi
  if [ "$stage" = after ] || [ "$kind" = revoked ]; then
    printf '%s-entry-identity=%s\n' "$stage" "$(stat -Lc '%d:%i' "$XDG_CONFIG_HOME/autostart/localsend_app.desktop")"
    digest=$(sha256sum "$XDG_CONFIG_HOME/autostart/localsend_app.desktop")
    printf '%s-entry-sha256=%s\n' "$stage" "${digest%% *}"
  fi
  printf 'stage=%s\n' "$stage"
}
if [ "$kind" != revoked ]; then
  test -d "$XDG_CONFIG_HOME/autostart"
  test ! -e "$XDG_CONFIG_HOME/autostart/$marker"
  test ! -e "$XDG_CONFIG_HOME/autostart/localsend_app.desktop"
  printf 'issue1927 diagnostic owned marker before\n' > "$XDG_CONFIG_HOME/autostart/$marker"
else
  test -r "$XDG_CONFIG_HOME/autostart/localsend_app.desktop"
fi
snapshot before
sleep 8
if [ "$kind" != revoked ]; then
  printf 'issue1927 diagnostic owned marker after\n' > "$XDG_CONFIG_HOME/autostart/$marker"
  printf '[Desktop Entry]\nType=Application\nName=Issue1927 mapping only\nExec=/usr/bin/true\n' > "$XDG_CONFIG_HOME/autostart/localsend_app.desktop"
fi
snapshot after
sleep 8
SANDBOX
}
probe_case() {
  local label=$1 initial=$2 kind=$3 config=$4 before_state after_state
  case_deadline=$((SECONDS+40))
  case_out=$OUT/$label
  case_kind=$kind
  host_config=$config
  marker=.issue1927-mapping-$label
  mkdir "$case_out"
  no_instance
  installed_commit
  if [[ $kind != revoked ]]; then
    run test ! -L "$config/autostart"
    run test ! -e "$config/autostart/localsend_app.desktop"
    if [[ $initial = absent ]]; then run test ! -e "$config/autostart"; else run test -d "$config/autostart"; fi
  fi
  printf 'host_HOME=%s host_config=%s initial_autostart=%s launch_kind=%s\n' "$HOME" "$config" "$initial" "$kind" > "$case_out/host-before.txt"
  make_payload
  local opts=()
  if [[ $kind = revoked ]]; then opts+=(--nofilesystem=xdg-config/autostart); fi
  # Host env selects Flatpak's supported host-XDG source. Do not override the
  # sandbox's XDG_CONFIG_HOME: Flatpak sets its own package-private config path.
  env XDG_CONFIG_HOME="$config" timeout --foreground -s KILL 35 flatpak run --user "${opts[@]}" --command=sh "$APP" -s -- "$kind" "$marker" < "$case_out/payload.sh" > "$case_out/sandbox.log" 2> "$case_out/sandbox-stderr.txt" &
  launch_pid=$!
  launch_ticks=$(run awk '{sub(/^.*\) /,"");print $20}' "/proc/$launch_pid/stat")
  [[ $launch_ticks =~ ^[0-9]+$ ]]
  wait_stage before
  qualify_shell
  host_snapshot before
  wait_stage after
  host_snapshot after
  before_state=$(run awk '/^before-status=/ {print $1}' "$case_out/sandbox.log")
  after_state=$(run awk '/^after-status=/ {print $1}' "$case_out/sandbox.log")
  if [[ $kind = revoked ]]; then
    [[ $before_state = before-status=unavailable && $after_state = after-status=unavailable ]]
  else
    [[ $before_state = before-status=entry-absent && $after_state = after-status=entry-present ]]
    run grep -qx 'before-status=entry-absent permission=create' "$case_out/sandbox.log"
    run grep -qx 'after-status=entry-present permission=create' "$case_out/sandbox.log"
  fi
  while [[ -e /proc/$launch_pid/stat && $SECONDS -lt $case_deadline ]]; do sleep .1; done
  [[ ! -e /proc/$launch_pid/stat ]] || return 124
  # The owned process is already gone, so this reaps its status without waiting.
  wait "$launch_pid"
  launch_pid=''
  launch_ticks=''
  no_instance
  printf 'qualified_mapping_case=PASS scope=infrastructure-only\n' > "$case_out/result.txt"
  if [[ $kind != revoked ]]; then
    # Only names absent before this case and authored by this script are removed.
    printf '[Desktop Entry]\nType=Application\nName=Issue1927 mapping only\nExec=/usr/bin/true\n' > "$case_out/owned-desktop.expected"
    run cmp "$case_out/owned-desktop.expected" "$config/autostart/localsend_app.desktop"
    run rm -- "$config/autostart/localsend_app.desktop" "$config/autostart/$marker"
  fi
}
case_deadline=$((SECONDS+20))
installed_commit
no_instance
run flatpak override --user --show "$APP" > "$OUT/existing-overrides.txt"
run flatpak info --user --show-permissions "$APP" > "$OUT/installed-permissions.txt"
run sha256sum "$PREDICATE" > "$OUT/predicate-sha256.txt"
# These two default cases require a fresh Mint user's absent autostart directory.
# Keep every unrelated config file. The :create mount creates this directory.
probe_case default-absent absent normal "$HOME/.config"
probe_case default-existing existing normal "$HOME/.config"
mkdir "$OUT/nondefault-absent-config" "$OUT/nondefault-existing-config"
mkdir "$OUT/nondefault-existing-config/autostart"
probe_case nondefault-absent absent normal "$OUT/nondefault-absent-config"
probe_case nondefault-existing existing normal "$OUT/nondefault-existing-config"
# Seed only a previously absent private entry. It must report unavailable once
# the exact relevant effective scope is revoked for this one diagnostic launch.
private_config=$HOME/.var/app/$APP/config
case_deadline=$((SECONDS+20))
run test ! -e "$private_config/autostart/localsend_app.desktop"
run test ! -L "$private_config/autostart"
mkdir -p "$private_config/autostart"
printf '[Desktop Entry]\nType=Application\nName=Issue1927 stale private diagnostic\nExec=/usr/bin/true\n' > "$private_config/autostart/localsend_app.desktop"
probe_case revoked-private-stale existing revoked "$HOME/.config"
case_deadline=$((SECONDS+10))
printf '[Desktop Entry]\nType=Application\nName=Issue1927 stale private diagnostic\nExec=/usr/bin/true\n' > "$OUT/owned-stale-desktop.expected"
run cmp "$OUT/owned-stale-desktop.expected" "$private_config/autostart/localsend_app.desktop"
run rm -- "$private_config/autostart/localsend_app.desktop"
printf 'mapping_infrastructure=PASS registration_parser=NOT_TESTED product_ui=NOT_TESTED desktop_login=NOT_TESTED\n' > "$OUT/conclusion.txt"
