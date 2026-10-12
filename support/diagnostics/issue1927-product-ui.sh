#!/usr/bin/env bash
# Product observations only: no permission-store, portal, cache or internal setters.
set -Eeuo pipefail
cd /home/mint
OUT=$(realpath evidence)/product
mkdir "$OUT"
exec 9>"$OUT/trace.txt"; BASH_XTRACEFD=9; set -x
[[ $(id -un) == mint && $HOME == /home/mint ]]
[[ ${ISSUE1927_CONDITIONS_DEADLINE:-} =~ ^[0-9]+$ ]]
FINAL_DEADLINE=$((SECONDS+ISSUE1927_CONDITIONS_DEADLINE-$(date +%s)))
# Reserve cleanup inside the original 780-second product allowance.
PHASE_DEADLINE=$((FINAL_DEADLINE-15))
APP=org.localsend.localsend_app
HOST_CONFIG=$HOME/.config
HOST_DIR=$HOST_CONFIG/autostart
ENTRY=$HOST_DIR/localsend_app.desktop
BACKUP=$OUT/original-autostart
original_inode= generated_inode= owned_entry_hash= private_fixture_hash= restore_pending=0
launcher_pid= launcher_ticks= current_condition=setup wid=
UI_OWNER=$BASHPID
source /home/mint/issue1927-ui.sh
# All old helper observers inherit the one product phase deadline, including
# helpers with shorter local gates. Failure cannot renew the product budget.
run_ui_observer() {
  local left=$((PHASE_DEADLINE-SECONDS)) local_left
  if [[ -n ${transition_deadline:-} ]]; then
    local_left=$((transition_deadline-SECONDS)); ((local_left<left)) && left=$local_left
  fi
  ((left>0)) || return 124
  ((left<=8)) || left=8
  timeout --foreground -s KILL "$left" "$@"
}
run() { local transition_deadline=$PHASE_DEADLINE; run_ui_observer "$@"; }
phase_sleep() { run sleep "$1"; }
inventory() {
  run bash -c 'cd "$1" && find . -xdev -printf "%P\0%y\0%D:%i\0%m\0%U:%G\0%s\0%T@\0%l\0"' _ "$1" > "$OUT/$2-inventory.nul"
  run bash -c 'cd "$1" && find . -xdev -type f -exec sha256sum -z -- {} +' _ "$1" > "$OUT/$2-sha256.nul"
}
restore_host() {
  run stat -c 'path=%n type=%F device=%d inode=%i' "$HOST_DIR" "$BACKUP" > "$OUT/restore-before-paths.txt" 2>&1 || true
  # Remove only the app entry whose bytes were last observed after our own UI
  # write. Unknown arrivals and any replaced directory remain intact.
  if [[ -e $ENTRY || -L $ENTRY ]]; then
    [[ -n $owned_entry_hash && -f $ENTRY && ! -L $ENTRY ]] || return 1
    [[ $(run sha256sum "$ENTRY") == "$owned_entry_hash" ]] || return 1
    run rm -- "$ENTRY" || return
  fi
  if [[ -e $HOST_DIR || -L $HOST_DIR ]]; then
    [[ -n $generated_inode && ! -L $HOST_DIR && -d $HOST_DIR && $(run stat -c '%d:%i' "$HOST_DIR") == "$generated_inode" ]] || return 1
    run rmdir -- "$HOST_DIR" || return
  fi
  if [[ $original_inode != absent ]]; then
    [[ ! -L $BACKUP && $(run stat -c '%d:%i' "$BACKUP") == "$original_inode" ]] || return 1
    inventory "$BACKUP" backup-before-restore || return
    run cmp "$OUT/original-inventory.nul" "$OUT/backup-before-restore-inventory.nul" || return
    run cmp "$OUT/original-sha256.nul" "$OUT/backup-before-restore-sha256.nul" || return
    run mv -T --no-clobber -- "$BACKUP" "$HOST_DIR" || return
    [[ ! -e $BACKUP && $(run stat -c '%d:%i' "$HOST_DIR") == "$original_inode" ]] || return 1
    inventory "$HOST_DIR" restored || return
    run cmp "$OUT/original-inventory.nul" "$OUT/restored-inventory.nul" || return
    run cmp "$OUT/original-sha256.nul" "$OUT/restored-sha256.nul" || return
  fi
  printf 'restored original_inode=%s generated_inode=%s\n' "$original_inode" "$generated_inode" >> "$OUT/cleanup.txt"
  generated_inode=
  restore_pending=0
}
finish() {
  local result=$? ticks
  [[ $BASHPID == "$UI_OWNER" ]] || return "$result"
  trap - EXIT ERR; trap '' TERM INT; set +e
  # Cleanup grants no verdicts and uses one bounded allowance for all commands.
  PHASE_DEADLINE=$((SECONDS+15))
  ((PHASE_DEADLINE<=FINAL_DEADLINE)) || PHASE_DEADLINE=$FINAL_DEADLINE
  stop_ui_recording
  if [[ -n ${XRES_CONTROL_PID:-} && -r /proc/$XRES_CONTROL_PID/stat ]]; then
    ticks=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$XRES_CONTROL_PID/stat")
    [[ $ticks != "${XRES_CONTROL_TICKS:-}" ]] || kill -TERM "$XRES_CONTROL_PID"
  fi
  if [[ -n $launcher_pid && -r /proc/$launcher_pid/stat ]]; then
    ticks=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$launcher_pid/stat")
    if [[ $ticks == "$launcher_ticks" ]]; then kill -TERM "$launcher_pid"; fi
    printf 'owned_launcher_cleanup pid=%s start=%s observed=%s\n' "$launcher_pid" "$launcher_ticks" "$ticks" >> "$OUT/cleanup.txt"
  fi
  if [[ -n $private_fixture_hash ]]; then
    if [[ -f $PRIVATE_ENTRY && ! -L $PRIVATE_ENTRY && $(run sha256sum "$PRIVATE_ENTRY") == "$private_fixture_hash" ]]; then run rm -- "$PRIVATE_ENTRY"; else result=40; fi
  fi
  if [[ $restore_pending == 1 ]]; then restore_host || { printf 'restoration incomplete; originals/unknown arrivals retained\n' >> "$OUT/cleanup.txt"; result=40; }; fi
  printf 'exit=%s condition=%s\n' "$result" "$current_condition" > "$OUT/result.txt"
  exit "$result"
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# Snapshots retain contradictory observations on first failure, never retry UI.
snapshot() {
  local label=$1
  date -u --iso-8601=ns > "$OUT/$label-time.txt"
  run loginctl list-sessions > "$OUT/$label-sessions.txt" || true
  run flatpak ps --columns=instance,application,pid > "$OUT/$label-instances.txt" || true
  run ps -eo pid,ppid,uid,comm,args > "$OUT/$label-processes.txt" || true
  run import -window root "$OUT/$label-desktop.png" || true
  run stat -Lc 'device=%d inode=%i size=%s mtime=%y' "$HOST_DIR" "$ENTRY" > "$OUT/$label-host-stat.txt" 2>&1 || true
  if [[ -f $ENTRY && ! -L $ENTRY ]]; then run cat "$ENTRY" > "$OUT/$label-host-entry.desktop" || true; fi
  if [[ -n $wid ]]; then run import -window "$wid" "$OUT/$label-settings.png" || true; fi
}
fail() {
  printf '%s condition=%s failed=%s; no subsequent product inputs\n' "$(date -u --iso-8601=ns)" "$current_condition" "$1" >> "$OUT/verdicts.txt"
  snapshot failure-terminal
  exit 40
}
# The first failure stops the sequence and retains the current branch.
trap 'fail "line-$LINENO-command-$BASH_COMMAND"' ERR
stop_ui_recording() {
  local ticks
  [[ -n ${recording_pid:-} && ${recording_owner:-} == "$BASHPID" ]] || return 0
  if [[ -r /proc/$recording_pid/stat ]]; then
    ticks=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$recording_pid/stat") || return
    [[ $ticks == "${recording_ticks:-}" ]] || return 1
    kill -INT "$recording_pid" 2>/dev/null || true
    phase_sleep .2 || true
    if [[ -r /proc/$recording_pid/stat && $(awk '{sub(/^.*\) /,"");print $20}' "/proc/$recording_pid/stat") == "$ticks" ]]; then
      kill -KILL "$recording_pid" 2>/dev/null || true
    fi
  fi
  recording_pid=
}
stabilize_window() {
  run xdotool windowactivate --sync "$wid"
  run xdotool windowmove "$wid" 0 0
  run xdotool windowsize "$wid" 1000 700
  phase_sleep 2
  run xdotool getwindowgeometry --shell "$wid" > "$OUT/window-geometry.txt"
}
start_ui_recording() {
  local label=$1
  [[ -z ${recording_pid:-} ]]
  recording_started=$SECONDS
  local dimensions
  dimensions=$(run xdpyinfo | awk '/dimensions:/{print $2}')
  [[ $dimensions =~ ^[0-9]+x[0-9]+$ ]]
  ffmpeg -nostdin -y -f x11grab -video_size "$dimensions" -framerate 15 -i "$DISPLAY" -t 5 -c:v libx264 -pix_fmt yuv420p -progress "$OUT/$label-recording-progress.txt" "$OUT/$label.mp4" > "$OUT/$label-recording.log" 2>&1 &
  recording_pid=$!; recording_owner=$BASHPID
  recording_ticks=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$recording_pid/stat")
  [[ $recording_ticks =~ ^[0-9]+$ ]]
  while ! run awk -F= '$1=="frame" && $2>0 {ready=1} END{exit !ready}' "$OUT/$label-recording-progress.txt"; do
    kill -0 "$recording_pid"
    phase_sleep .1
  done
  printf '%s recording_started_pid=%s ticks=%s\n' "$(date -u --iso-8601=ns)" "$recording_pid" "$recording_ticks" >> "$OUT/inputs.txt"
}
finish_recording() {
  local label=$1 left=$((recording_started+6-SECONDS)) result=0
  ((left<=0)) || phase_sleep "$left"
  while [[ -r /proc/$recording_pid/stat ]] && ((SECONDS<PHASE_DEADLINE)); do
    [[ $(run awk '{sub(/^.*\) /,"");print $1}' "/proc/$recording_pid/stat") != Z ]] || break
    phase_sleep .1
  done
  ((SECONDS<PHASE_DEADLINE)) || return 124
  wait "$recording_pid" || result=$?
  recording_pid=
  [[ $result == 0 ]]
  run ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1 "$OUT/$label.mp4" > "$OUT/$label-frames.txt"
  run awk -F= '$1=="nb_read_frames" && $2>=60 {ok=1} END{exit !ok}' "$OUT/$label-frames.txt"
}
session_environment() {
  local label=$1 desktop_pid
  desktop_pid=$(run pgrep -u "$(id -u)" -x cinnamon)
  [[ $desktop_pid =~ ^[0-9]+$ ]]
  run cat "/proc/$desktop_pid/stat" > "$OUT/$label-desktop-stat.txt"
  run bash -c 'tr "\0" "\n" < "/proc/$1/environ"' _ "$desktop_pid" > "$OUT/$label-session-environment-all.txt"
  run grep -E '^(DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE|XDG_DATA_DIRS)=' "$OUT/$label-session-environment-all.txt" > "$OUT/$label-session-environment.txt"
  while IFS= read -r assignment; do export "$assignment"; done < "$OUT/$label-session-environment.txt"
  if [[ ${2:-true} == true ]]; then
    start_xres_control "$label"
    XRES_CONTROL_TICKS=$(run awk '{sub(/^.*\) /,"");print $20}' "/proc/$XRES_CONTROL_PID/stat")
  fi
}
relogin() {
  local label=$1 old_pid new_pid old_ticks
  session_environment "$label-old" false
  old_pid=$(run pgrep -u "$(id -u)" -x cinnamon)
  old_ticks=$(run awk '{sub(/^.*\) /,"");print $20}' "/proc/$old_pid/stat")
  printf '%s real-login-boundary old_pid=%s old_start=%s\n' "$(date -u --iso-8601=ns)" "$old_pid" "$old_ticks" >> "$OUT/login-boundaries.txt"
  # The qualified Mint live account's LightDM autologin creates a new real
  # desktop/session. This is not manually executing a desktop entry.
  run sudo systemctl restart lightdm
  while ((SECONDS<PHASE_DEADLINE)); do
    new_pid=$(run pgrep -u "$(id -u)" -x cinnamon || true)
    if [[ $new_pid =~ ^[0-9]+$ && $new_pid != "$old_pid" ]]; then break; fi
    phase_sleep 1
  done
  [[ $new_pid =~ ^[0-9]+$ && $new_pid != "$old_pid" ]]
  phase_sleep 5
  session_environment "$label-new"
  snapshot "$label-new-session"
}
no_instance() {
  local label=$1 status=0
  run flatpak ps --columns=instance,application,pid > "$OUT/$label-no-instance.txt"
  run awk '$2=="org.localsend.localsend_app" {found=1} END{exit found}' "$OUT/$label-no-instance.txt" || status=$?
  [[ $status == 0 ]]
}
login_absence() {
  local label=$1 observe_until=$((SECONDS+15))
  while ((SECONDS<observe_until)); do no_instance "$label-$SECONDS"; phase_sleep 1; done
  snapshot "$label-no-login-app"
}
visible_identity() {
  local label=$1 prior=${2:-} pid
  pid=$(qualified_app_pid "$label" "$PHASE_DEADLINE")
  wid=$(qualified_visible_window "$label" "$pid" "$PHASE_DEADLINE")
  printf '%s\n' "$wid" > "$OUT/$label-window.txt"
  [[ -z $prior ]] || cmp "$OUT/$prior-process-identity.txt" "$OUT/$label-process-identity.txt"
}
owned_launch() {
  local label=$1; shift
  local left=$((PHASE_DEADLINE-SECONDS))
  ((left>0))
  timeout --foreground --signal=TERM --kill-after=2 "$left" "$@" > "$OUT/$label-launch.log" 2>&1 &
  launcher_pid=$!
  launcher_ticks=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$launcher_pid/stat")
  [[ $launcher_ticks =~ ^[0-9]+$ ]]
  printf '%s launcher_pid=%s start=%s command=' "$(date -u --iso-8601=ns)" "$launcher_pid" "$launcher_ticks" >> "$OUT/launchers.txt"
  printf '%q ' "$@" >> "$OUT/launchers.txt"; printf '\n' >> "$OUT/launchers.txt"
}
await_visible() {
  local label=$1 attempt=0 result=0
  while ((SECONDS<PHASE_DEADLINE)); do
    attempt=$((attempt+1)); result=0
    run xdotool search --onlyvisible --name '^LocalSend$' > "$OUT/$label-visible-$attempt.txt" 2> "$OUT/$label-visible-$attempt.stderr" || result=$?
    [[ ! -s $OUT/$label-visible-$attempt.stderr ]]
    if [[ $result == 0 ]]; then
      wid=$(run cat "$OUT/$label-visible-$attempt.txt"); [[ $wid =~ ^[0-9]+$ ]]
      phase_sleep 1
      wait_rendered_application "$label"
      visible_identity "$label"
      return
    fi
    [[ $result == 1 ]]; phase_sleep .5
  done
  return 124
}
open_settings() {
  local label=$1 x y width height observed_window
  # Reuse source-qualified geometry/theme. Navigation input is located by
  # current OCR text, not a remembered coordinate alone.
  stabilize_window initialized
  visible_identity "$label-before-settings-input"
  observed_window=$wid
  run xdotool getwindowgeometry --shell "$wid" > "$OUT/$label-navigation-geometry.txt"
  width=$(run awk -F= '$1=="WIDTH" {print $2}' "$OUT/$label-navigation-geometry.txt")
  height=$(run awk -F= '$1=="HEIGHT" {print $2}' "$OUT/$label-navigation-geometry.txt")
  run import -window "$wid" "$OUT/$label-navigation.png"
  observe_navigation_rail "$OUT/$label-navigation.png" "$OUT/$label-navigation" "$width" "$height"
  read -r x y < <(run awk -F '\t' '$1=="settings" {print $2, $3}' "$OUT/$label-navigation-coordinates.tsv")
  [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]
  # OCR coordinates are relative to this exact owned client, not its frame
  # or screen origin. Reject a moved, resized or replaced window before input.
  visible_identity "$label-after-navigation-observation" "$label-before-settings-input"
  [[ $wid == "$observed_window" ]]
  run xdotool getwindowgeometry --shell "$wid" > "$OUT/$label-navigation-before-click-geometry.txt"
  run cmp "$OUT/$label-navigation-geometry.txt" "$OUT/$label-navigation-before-click-geometry.txt"
  start_ui_recording "$label-settings-input"
  printf '%s window=%s semantic=Settings coordinate=%s,%s\n' "$(date -u --iso-8601=ns)" "$wid" "$x" "$y" >> "$OUT/inputs.txt"
  run xdotool mousemove --window "$wid" "$x" "$y" click 1
  finish_recording "$label-settings-input"
  run import -window "$wid" "$OUT/$label-settings.png"
}
launch_settings() {
  local label=$1; shift
  no_instance "$label-prelaunch"
  owned_launch "$label" flatpak run --user "$@" --command=/app/localsend_app "$APP"
  await_visible "$label"
  open_settings "$label"
}
close_app() {
  local label=$1
  visible_identity "$label-before-close"
  start_ui_recording "$label-close"
  printf '%s window=%s semantic=Close key=Alt+F4\n' "$(date -u --iso-8601=ns)" "$wid" >> "$OUT/inputs.txt"
  run xdotool windowactivate "$wid" key alt+F4
  finish_recording "$label-close"
  while ! no_instance "$label-exit-$SECONDS"; do phase_sleep .5; done
  wid=
  if [[ -n $launcher_pid ]]; then wait "$launcher_pid"; fi
  launcher_pid= launcher_ticks=
}
entry_read() {
  local label=$1 hidden=$2 expected
  [[ -f $ENTRY && ! -L $ENTRY ]]
  run stat -Lc 'device=%d inode=%i size=%s mtime=%y' "$ENTRY" > "$OUT/$label-entry-stat.txt"
  run cat "$ENTRY" > "$OUT/$label-entry.desktop"
  expected='Exec="/usr/bin/flatpak" "run" "--command=/app/localsend_app" "org.localsend.localsend_app"'
  [[ $hidden == OFF ]] || expected="$expected \"--hidden\""
  # This selected writer emits fully quoted tokens with no escapes in these
  # fixed arguments. Exact byte/vector matching rejects extra keys or argv.
  run awk -v expected="$expected" '/^\[/ {if($0!="[Desktop Entry]")bad=1;groups++} /^Exec=/ {n++;if($0!=expected)bad=1} /^Type=/ {if($0!="Type=Application")bad=1;t++} /^Hidden=/ {if($0!="Hidden=false")bad=1} /^X-GNOME-Autostart-enabled=/ {if($0!="X-GNOME-Autostart-enabled=true")bad=1} END{exit !(groups==1 && n==1 && t==1 && !bad)}' "$OUT/$label-entry.desktop"
  printf '%s\nrun\n--command=/app/localsend_app\n%s\n' /usr/bin/flatpak "$APP" > "$OUT/$label-entry-argv.txt"
  [[ $hidden == OFF ]] || printf '%s\n' --hidden >> "$OUT/$label-entry-argv.txt"
  owned_entry_hash=$(run sha256sum "$ENTRY")
}
entry_absent() { [[ ! -e $ENTRY && ! -L $ENTRY ]]; }
observe_state() {
  local label=$1 expected=$2 hidden=${3:-} state
  state=$(observed_switch_row 'Autostart after login' "$label-autostart")
  if [[ $expected == OBSERVE ]]; then
    [[ ${state##* } == ON || ${state##* } == OFF ]]
    printf '%s label=%s baseline_reopened_actual=%s\n' "$(date -u --iso-8601=ns)" "$label" "${state##* }" >> "$OUT/verdicts.txt"
  else
    [[ ${state##* } == "$expected" ]]
  fi
  [[ -z $hidden ]] || { state=$(observed_switch_row 'Start hidden' "$label-hidden"); [[ ${state##* } == "$hidden" ]]; }
  snapshot "$label"
}
click_switch() {
  local label=$1 phrase=$2 before=$3 after=$4 kind=$5 y state
  visible_identity "$label-before-input"
  y=$(require_switch_state "$phrase" "$label-current-label" "$before")
  start_ui_recording "$label"
  printf '%s window=%s semantic=%s before=%s coordinate=825,%s\n' "$(date -u --iso-8601=ns)" "$wid" "$phrase" "$before" "$y" >> "$OUT/inputs.txt"
  run xdotool mousemove --window "$wid" 825 "$y" click 1
  finish_recording "$label"
  while ((SECONDS<PHASE_DEADLINE)); do
    state=$(observed_switch_row "$phrase" "$label-after-$SECONDS" || true)
    if [[ ${state##* } == "$after" ]]; then
      case "$kind" in
        host-visible) entry_read "$label-observed" OFF;;
        host-hidden) entry_read "$label-observed" ON;;
        host-absent) entry_absent;;
        sandbox)
          local pid old_entry
          pid=$(qualified_app_pid "$label-sandbox" "$PHASE_DEADLINE")
          old_entry="/proc/$pid/root$HOME/.config/autostart/localsend_app.desktop"
          run sudo cat "$old_entry" > "$OUT/$label-sandbox-entry.desktop"
          run sudo stat -Lc '%d:%i' "$old_entry" > "$OUT/$label-sandbox-entry-inode.txt"
          run awk '/^Exec=/ {n++;if($0!="Exec=/app/localsend_app")bad=1} END{exit !(n==1 && !bad)}' "$OUT/$label-sandbox-entry.desktop"
          if [[ -e $ENTRY || -L $ENTRY ]]; then
            [[ -f $ENTRY && ! -L $ENTRY ]]
            run cat "$ENTRY" > "$OUT/$label-legacy-host-entry.desktop"
            run stat -Lc '%d:%i' "$ENTRY" > "$OUT/$label-legacy-host-entry-inode.txt"
            run cmp "$OUT/$label-sandbox-entry.desktop" "$OUT/$label-legacy-host-entry.desktop"
            run cmp "$OUT/$label-sandbox-entry-inode.txt" "$OUT/$label-legacy-host-entry-inode.txt"
            owned_entry_hash=$(run sha256sum "$ENTRY")
            printf 'baseline legacy HOME entry maps to host; identical bytes/inode; Exec=/app/localsend_app\n' > "$OUT/$label-legacy-host-view.txt"
          else
            entry_absent
            printf 'baseline legacy HOME entry private; host entry absent\n' > "$OUT/$label-legacy-host-view.txt"
          fi;;
      esac
      snapshot "$label-observed"
      return
    fi
    phase_sleep .5
  done
  return 124
}
installed_identity() {
  local label=$1
  EXPECTED_APP_COMMIT=$(run flatpak info --user --show-commit "$APP")
  [[ $EXPECTED_APP_COMMIT =~ ^[0-9a-f]{64}$ ]]; export EXPECTED_APP_COMMIT
  printf '%s\n' "$EXPECTED_APP_COMMIT" > "$OUT/$label-app-commit.txt"
  run flatpak info --user "$APP" > "$OUT/$label-app-info.txt"
  run flatpak info --user --show-metadata "$APP" > "$OUT/$label-app-metadata.txt"
  run flatpak override --user --show "$APP" > "$OUT/$label-overrides.txt"
}
actual_argv() {
  local label=$1 hidden=$2 pid ticks before after
  local -a args
  read -r _ _ pid before < "$OUT/$label-process-identity.txt"
  run sudo cat "/proc/$pid/cmdline" > "$OUT/$label-actual-cmdline.nul"
  mapfile -d '' -t args < "$OUT/$label-actual-cmdline.nul"
  [[ ${args[0]:-} == /app/localsend_app ]]
  if [[ $hidden == ON ]]; then [[ ${#args[@]} == 2 && ${args[1]} == --hidden ]]; else [[ ${#args[@]} == 1 ]]; fi
  run sudo cat "/proc/$pid/stat" > "$OUT/$label-actual-argv-stat.txt"
  after=$(run awk '{sub(/^.*\) /,"");print $20}' "$OUT/$label-actual-argv-stat.txt")
  [[ $after == "$before" ]]
  printf '%s\n' "${args[@]}" > "$OUT/$label-actual-argv.txt"
}
condition_pass() { printf '%s condition=%s PASS=%s\n' "$(date -u --iso-8601=ns)" "$current_condition" "$1" >> "$OUT/verdicts.txt"; }
# Isolate only the host autostart directory with a rename that preserves original
# directory inode, every original entry, and exact original file bytes.
[[ ! -L $HOST_DIR && ! -e $BACKUP ]]
if [[ -e $HOST_DIR ]]; then
  [[ -d $HOST_DIR ]]; original_inode=$(run stat -c '%d:%i' "$HOST_DIR")
  inventory "$HOST_DIR" original
  restore_pending=1
  run mv -T -- "$HOST_DIR" "$BACKUP"
else original_inode=absent; fi
restore_pending=1
run mkdir "$HOST_DIR"; generated_inode=$(run stat -c '%d:%i' "$HOST_DIR")
session_environment initial
installed_identity baseline
current_condition=1-baseline
launch_settings baseline
observe_state baseline-initial OFF
click_switch baseline-enable 'Autostart after login' OFF ON sandbox
close_app baseline-first
launch_settings baseline-reopened
observe_state baseline-reopened OBSERVE
close_app baseline-login-close
relogin baseline-login
login_absence baseline-login
# Positive harness control: the unchanged exported desktop launcher must work.
run cat "$HOME/.local/share/flatpak/exports/share/applications/$APP.desktop" > "$OUT/baseline-exported-launcher.desktop"
owned_launch baseline-exported gtk-launch "$APP"
await_visible baseline-exported
open_settings baseline-exported
close_app baseline-exported
condition_pass 'baseline enable writes exact legacy Exec; reopen state observed; real-login absent; exported launcher qualifies harness'
current_condition=2-candidate-visible
# Package change requires the previous qualified app to have actually exited.
no_instance candidate-package-change
left=$((PHASE_DEADLINE-SECONDS)); ((left>0))
timeout --foreground --signal=TERM --kill-after=2 "$left" flatpak install --user --noninteractive -y ./candidate.flatpak > "$OUT/candidate-install.log" 2>&1
installed_identity candidate
launch_settings candidate
observe_state candidate-initial OFF
click_switch candidate-visible-enable 'Autostart after login' OFF ON host-visible
for repeat in 1 2; do
  close_app "candidate-visible-$repeat"
  launch_settings "candidate-visible-reopen-$repeat"
  observe_state "candidate-visible-reopen-$repeat" ON OFF
  entry_read "candidate-visible-reopen-$repeat" OFF
done
close_app candidate-visible-login-close
relogin candidate-visible-login
await_visible candidate-visible-login
actual_argv candidate-visible-login OFF
open_settings candidate-visible-login
observe_state candidate-visible-login ON OFF
entry_read candidate-visible-login OFF
condition_pass 'visible enable exact host argv survives two reopen cycles and actual login'
current_condition=3-candidate-hidden
click_switch candidate-hidden-enable 'Start hidden' OFF ON host-hidden
close_app candidate-hidden-close
launch_settings candidate-hidden-reopen
observe_state candidate-hidden-reopen ON ON
entry_read candidate-hidden-reopen ON
close_app candidate-hidden-login-close
relogin candidate-hidden-login
phase_sleep 5
hidden_pid=$(qualified_app_pid candidate-hidden-login "$PHASE_DEADLINE")
actual_argv candidate-hidden-login ON
hidden_query_result=0
run xdotool search --onlyvisible --name '^LocalSend$' > "$OUT/candidate-hidden-login-visible.txt" 2> "$OUT/candidate-hidden-login-visible.stderr" || hidden_query_result=$?
[[ $hidden_query_result == 1 ]]
[[ ! -s $OUT/candidate-hidden-login-visible.stderr && ! -s $OUT/candidate-hidden-login-visible.txt ]]
entry_read candidate-hidden-login ON
owned_launch candidate-hidden-foreground flatpak run --user --command=/app/localsend_app "$APP"
# This activation must complete before counting the resident instance rows.
wait "$launcher_pid"
launcher_pid= launcher_ticks=
await_visible candidate-hidden-foreground
cmp "$OUT/candidate-hidden-login-process-identity.txt" "$OUT/candidate-hidden-foreground-process-identity.txt"
actual_argv candidate-hidden-foreground ON
open_settings candidate-hidden-foreground
observe_state candidate-hidden-foreground ON ON
condition_pass 'hidden update/reopen/login; foreground retains same actual app leaf/instance/start'
current_condition=4-candidate-disable
click_switch candidate-disable 'Autostart after login' ON OFF host-absent
close_app candidate-disable-close
launch_settings candidate-disable-reopen
observe_state candidate-disable-reopen OFF
entry_absent
close_app candidate-disable-login-close
relogin candidate-disable-login
login_absence candidate-disable-login
entry_absent
condition_pass 'actual disable removes host entry, reopen OFF, actual login absent'
current_condition=5-candidate-revoked
PRIVATE_ENTRY=$HOME/.var/app/$APP/config/autostart/localsend_app.desktop
[[ ! -L ${PRIVATE_ENTRY%/*} && ! -L $PRIVATE_ENTRY ]]
if [[ ! -e $PRIVATE_ENTRY ]]; then
  run mkdir -p "${PRIVATE_ENTRY%/*}"
  printf '[Desktop Entry]\nType=Application\nName=LocalSend\nComment=LocalSend startup script\nExec=/app/localsend_app\nStartupNotify=false\nTerminal=false\n' > "$PRIVATE_ENTRY"
  private_fixture_hash=$(run sha256sum "$PRIVATE_ENTRY")
fi
run cat "$PRIVATE_ENTRY" > "$OUT/revoked-private-stale-before.desktop"
private_before=$(run sha256sum "$PRIVATE_ENTRY")
host_before=$(run stat -c '%d:%i' "$HOST_DIR")
inventory "$HOST_DIR" revoked-host-before
launch_settings candidate-revoked --nofilesystem=xdg-config/autostart
visible_identity candidate-revoked-observation
run import -window "$wid" "$OUT/candidate-revoked-unavailable.png"
run tesseract "$OUT/candidate-revoked-unavailable.png" "$OUT/candidate-revoked-unavailable" tsv > "$OUT/candidate-revoked-unavailable-ocr.log" 2>&1
# Qualify exactly one current autostart label and the unavailable text on its
# same visual row; an unknown switch/color is never interpreted as OFF.
y=$(settings_row_y 'Autostart after login' candidate-revoked-row)
run awk -F '\t' -v y="$y" 'NR>1 && $1==5 && $11>=50 && $7>740 && $8<=y+20 && $8+$10>=y-20 {key=$2"/"$3"/"$4"/"$5; text[key]=text[key]" "$12} END{for(k in text){sub(/^ /,"",text[k]);if(text[k]=="Not available")n++}exit !(n==1)}' "$OUT/candidate-revoked-unavailable.tsv"
revoked_pid=$(qualified_app_pid candidate-revoked-scope "$PHASE_DEADLINE")
run sudo cat "/proc/$revoked_pid/root/.flatpak-info" > "$OUT/candidate-revoked-scope.txt"
run awk '
  /^\[/ {context=($0=="[Context]")}
  context && /^filesystems=/ {
    if(++lines>1)bad=1
    value=substr($0,13);n=split(value,scopes,";")
    for(i=1;i<=n;i++)if(scopes[i]=="xdg-config/autostart" || scopes[i]~/^xdg-config\/autostart:/)positive=1
  }
  END{exit (positive || bad)}
' "$OUT/candidate-revoked-scope.txt"
[[ $(run sha256sum "$PRIVATE_ENTRY") == "$private_before" && $(run stat -c '%d:%i' "$HOST_DIR") == "$host_before" ]]
inventory "$HOST_DIR" revoked-host-after
run cmp "$OUT/revoked-host-before-inventory.nul" "$OUT/revoked-host-after-inventory.nul"
run cmp "$OUT/revoked-host-before-sha256.nul" "$OUT/revoked-host-after-sha256.nul"
entry_absent
snapshot candidate-revoked-final
close_app candidate-revoked-close
condition_pass 'launch-only scope revoked; stale private entry remains; actual UI unavailable; host bytes/inodes unchanged'
printf 'five conditions completed; no portal/cache/internal-state oracle used\n' > "$OUT/conclusion.txt"
