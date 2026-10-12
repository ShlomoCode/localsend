#!/usr/bin/env bash
# Actual visible UI controls: wait for app initialization and identify rows by text.
stop_ui_recording() {
  local result=0
  if [ -z "${recording_pid:-}" ]; then return 0; fi
  # A command-substitution subshell must never stop its parent's recording.
  if [ "${recording_owner:-}" != "$BASHPID" ]; then return 0; fi
  kill -INT "$recording_pid" 2>/dev/null || true
  wait "$recording_pid" || result=$?
  recording_pid=''
  printf 'ffmpeg_exit=%s\n' "$result" >> "$OUT/recording-results.txt"
  # ffmpeg returns 255 after the requested SIGINT; the MP4 is finalized.
  [ "$result" = 0 ] || [ "$result" = 255 ]
}
trap stop_ui_recording EXIT
start_ui_recording() {
  local label=$1
  ffmpeg -nostdin -y -f x11grab -video_size 1280x800 -framerate 15 -i "$DISPLAY" -t 360 -c:v libx264 -pix_fmt yuv420p "$OUT/$label.mp4" > "$OUT/$label-recording.log" 2>&1 &
  recording_pid=$!
  recording_owner=$BASHPID
  sleep 1
  kill -0 "$recording_pid"
}
stabilize_window() {
  if [ "${1:-}" != initialized ]; then sleep 8; fi
  xdotool windowactivate --sync "$wid"
  xdotool windowmove "$wid" 0 0
  xdotool windowsize "$wid" 1000 700
  sleep 2
  xdotool getwindowgeometry --shell "$wid" > "$OUT/window-geometry.txt"
}
wait_rendered_application() {
  # Replace the existing eight-second startup sleep with read-only observation.
  # Rendered navigation proves a mature app shell, not ownership or Settings.
  local identity_label=$1 transition_deadline=$((SECONDS+8)) attempt=0 label
  while [ "$SECONDS" -lt "$transition_deadline" ]; do
    attempt=$((attempt+1))
    label="$identity_label-mature-attempt-$attempt"
    identity_command "render-$attempt" import -window "$wid" "$OUT/$label.png" || return 1
    identity_command "properties-$attempt" xprop -id "$wid" WM_CLASS _NET_WM_PID > "$OUT/$label-properties.txt" || return 1
    # Bootstrap may already have an owner; this observation grants no input.
    identity_command "bootstrap-owner-$attempt" /home/mint/xres-owner "$wid" > "$OUT/$label-owner.txt" || return 1
    # Retained mature 900/1000px renders place these labels in this crop.
    # Exclude icons and body headings; full-frame OCR duplicates/misreads them.
    identity_command "navigation-crop-$attempt" convert "$OUT/$label.png" -crop 170x170+70+90 +repage "$OUT/$label-navigation.png" || return 1
    identity_command "ocr-$attempt" tesseract "$OUT/$label-navigation.png" "$OUT/$label" --psm 6 tsv > "$OUT/$label-ocr.log" 2>&1 || return 1
    if identity_command "rendered-navigation-$attempt" awk -F '\t' '
      NR>1 && $1==5 && $11>=50 {
        key=$2 "/" $3 "/" $4 "/" $5; text[key]=text[key] " " $12
      }
      END {
        for(key in text){sub(/^ /,"",text[key]); line=tolower(text[key]); if(line=="receive") receive++; if(line=="send") send++; if(line=="settings") settings++}
        exit !(receive==1 && send==1 && settings==1)
      }
    ' "$OUT/$label.tsv" && [ "$SECONDS" -lt "$transition_deadline" ]; then
      printf 'rendered_application=%s window=%s; ownership and Settings still unqualified\n' "$label" "$wid" > "$OUT/$identity_label-rendered-readiness.txt"
      return 0
    fi
    [ "$SECONDS" -lt "$transition_deadline" ] || break
    sleep 0.2
  done
  printf 'rendered application timeout; no input authorized\n' > "$OUT/$identity_label-rendered-readiness.txt"
  return 1
}
run_ui_observer() {
  local budget=8 remaining
  if [ -n "${transition_deadline:-}" ]; then
    remaining=$((transition_deadline-SECONDS))
    [ "$remaining" -gt 0 ] || return 124
    if [ "$remaining" -lt "$budget" ]; then budget=$remaining; fi
  fi
  timeout -s KILL "$budget" "$@"
}
settings_row_y() {
  local phrase=$1 label=$2 y
  run_ui_observer import -window "$wid" "$OUT/$label-locate.png" || return 1
  test "$(run_ui_observer identify -format '%wx%h' "$OUT/$label-locate.png")" = 1000x700 || return 1
  run_ui_observer tesseract "$OUT/$label-locate.png" "$OUT/$label-locate" tsv > "$OUT/$label-ocr.log" 2>&1 || return 1
  row_y_from_tsv "$phrase" "$label"
}
row_y_from_tsv() {
  local phrase=$1 label=$2 y
  case "$phrase" in
    'Minimize to') phrase='Minimize to the System Tray/Menu Bar when closing';;
    'Start hidden') phrase='Autostart: Start hidden';;
  esac
  y=$(run_ui_observer awk -F '\t' -v phrase="$phrase" '
    NR > 1 && $1 == 5 && $11 >= 50 && $7 >= 340 && $7+$9 < 745 {
      key=$2 "/" $3 "/" $4 "/" $5
      text[key]=text[key] " " $12
      if (!(key in top) || $8 < top[key]) top[key]=$8
      if (!(key in bottom) || $8+$10 > bottom[key]) bottom[key]=$8+$10
    }
    END {for (key in text) {sub(/^ /,"",text[key]); if (text[key]==phrase) print int((top[key]+bottom[key])/2)}}
  ' "$OUT/$label-locate.tsv") || return 1
  [[ "$y" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$y"
}
observed_switch_state() {
  local y=$1 label=$2 image="$OUT/$2-locate.png" state left right
  # The retained source renders establish the switch at x=798..849 for
  # this checked 1000x700 layout. Preserve its entire row association/crop.
  run_ui_observer convert "$image" -crop "64x40+790+$((y-20))" "$OUT/$label-switch-$y.png" || return 1
  left=$(run_ui_observer convert "$image" -crop "4x4+812+$((y-2))" -scale 1x1! -format '%[fx:r] %[fx:g] %[fx:b]' info:) || return 1
  right=$(run_ui_observer convert "$image" -crop "4x4+834+$((y-2))" -scale 1x1! -format '%[fx:r] %[fx:g] %[fx:b]' info:) || return 1
  printf '%s row_y=%s left_rgb=%s right_rgb=%s\n' "$label" "$y" "$left" "$right" >> "$OUT/switch-colors.txt"
  state=$(run_ui_observer awk -v left="$left" -v right="$right" 'BEGIN {
    split(left,l," "); split(right,r," ");
    white=(r[1]>.9 && r[2]>.9 && r[3]>.9);
    teal=(l[1]<.08 && l[2]>.33 && l[2]<.50 && l[3]>.29 && l[3]<.46);
    min=l[1]; max=l[1]; for(i=2;i<=3;i++){if(l[i]<min)min=l[i];if(l[i]>max)max=l[i]}
    gray=(l[1]>.35 && l[1]<.52 && l[2]>.39 && l[2]<.56 && l[3]>.38 && l[3]<.55 && max-min<.08);
    print white && teal ? 1 : (white && gray ? 0 : 2);
  }') || return 1
  case "$state" in 1) printf 'ON\n';; 0) printf 'OFF\n';; *) return 1;; esac
}
observed_switch_row() {
  local phrase=$1 label=$2 y observed
  y=$(settings_row_y "$phrase" "$label") || return 1
  # Calibrate fixed source layout/theme/scaling against independent known
  # controls in this same fresh frame. Empty background cannot mean OFF.
  local calibration_y calibration_state
  calibration_y=$(row_y_from_tsv 'Minimize to' "$label") || return 1
  calibration_state=$(observed_switch_state "$calibration_y" "$label") || return 1
  test "$calibration_state" = OFF || return 1
  calibration_y=$(row_y_from_tsv Animations "$label") || return 1
  calibration_state=$(observed_switch_state "$calibration_y" "$label") || return 1
  test "$calibration_state" = ON || return 1
  observed=$(observed_switch_state "$y" "$label") || return 1
  printf '%s label=%s row_y=%s observed=%s\n' "$(date -u --iso-8601=ns)" "$phrase" "$y" "$observed" >> "$OUT/observed-switch-states.txt"
  printf '%s %s\n' "$y" "$observed"
}
require_switch_state() {
  local phrase=$1 label=$2 expected=$3 result y observed
  result=$(observed_switch_row "$phrase" "$label") || return 1
  read -r y observed <<< "$result"
  test "$observed" = "$expected" || return 1
  printf '%s\n' "$y"
}
observe_entry_command() {
  local stage=$1 result=0
  shift
  printf '%s label=%s stage=%s remaining=%s command=' "$(date -u --iso-8601=ns)" "${entry_observation_label:-terminal}" "$stage" "$((transition_deadline-SECONDS))" >> "$OUT/entry-observer.txt"
  printf '%q ' "$@" >> "$OUT/entry-observer.txt"
  printf '\n' >> "$OUT/entry-observer.txt"
  run_ui_observer "$@" 2>> "$OUT/entry-observer.txt" || result=$?
  printf 'stage=%s exit=%s\n' "$stage" "$result" >> "$OUT/entry-observer.txt"
  return "$result"
}
capture_entry_timeout() {
  # The transition has already failed. This separate eight-second forensic
  # budget cannot authorize success or issue input, and does not reset its gate.
  local transition_deadline=$((SECONDS+8)) pid name
  local entry_observation_label="$1-terminal"
  printf 'terminal capture: separate diagnostic-only budget=8s\n' >> "$OUT/entry-observer.txt"
  observe_entry_command processes pgrep -ax localsend >> "$OUT/entry-observer.txt" || true
  pid=$(observe_entry_command pid pgrep -n -x localsend) || return 0
  observe_entry_command executable sudo -n readlink "/proc/$pid/exe" >> "$OUT/entry-observer.txt" || true
  observe_entry_command root sudo -n readlink "/proc/$pid/root" >> "$OUT/entry-observer.txt" || true
  observe_entry_command package-metadata sudo -n cat "/proc/$pid/root/app/data/flutter_assets/version.json" >> "$OUT/entry-observer.txt" || true
  observe_entry_command sandbox-directory sudo -n stat "/proc/$pid/root$HOME/.config/autostart" >> "$OUT/entry-observer.txt" || true
  for name in localsend_app org.localsend.localsend_app; do
    observe_entry_command "sandbox-stat-$name" sudo -n stat "/proc/$pid/root$HOME/.config/autostart/$name.desktop" >> "$OUT/entry-observer.txt" || true
    observe_entry_command "sandbox-read-$name" sudo -n cat "/proc/$pid/root$HOME/.config/autostart/$name.desktop" >> "$OUT/entry-observer.txt" || true
    observe_entry_command "host-stat-$name" stat "$HOME/.config/autostart/$name.desktop" >> "$OUT/entry-observer.txt" || true
    observe_entry_command "host-read-$name" cat "$HOME/.config/autostart/$name.desktop" >> "$OUT/entry-observer.txt" || true
  done
}
desktop_entry_ready() {
  # Native helper uses version.json package_name=localsend_app; Background
  # portal owns an entry named after the distinct Flatpak application ID.
  local kind=$1 entry="$HOME/.config/autostart/localsend_app.desktop" pid
  case "$kind" in host-flatpak-*|host-absent) entry="$HOME/.config/autostart/org.localsend.localsend_app.desktop";; esac
  case "$kind" in
    sandbox-enabled)
      pid=$(observe_entry_command pid pgrep -n -x localsend) || return 1
      observe_entry_command sandbox-readable sudo -n test -r "/proc/$pid/root$entry" && observe_entry_command sandbox-exec sudo -n grep -q '^Exec=' "/proc/$pid/root$entry";;
    host-native-enabled) observe_entry_command host-readable test -r "$entry" && observe_entry_command host-exec grep -q '^Exec=' "$entry";;
    host-flatpak-visible)
      observe_entry_command host-readable test -r "$entry" && observe_entry_command host-exec grep -q '^Exec=.*flatpak.*org.localsend.localsend_app' "$entry" || return 1
      # A timeout/error must never qualify as absence of --hidden.
      local grep_result=0
      observe_entry_command host-hidden grep -q -- '--hidden' "$entry" || grep_result=$?
      [ "$grep_result" = 1 ];;
    host-flatpak-hidden) observe_entry_command host-readable test -r "$entry" && observe_entry_command host-exec grep -q '^Exec=.*flatpak.*org.localsend.localsend_app' "$entry" && observe_entry_command host-hidden grep -q -- '--hidden' "$entry";;
    host-absent) observe_entry_command host-absent test ! -e "$entry";;
    *) return 1;;
  esac
}
wait_observed_transition() {
  local phrase=$1 label=$2 expected=$3 entry_kind=$4 result y observed attempt=0
  local transition_deadline=$((SECONDS+65)) entry_observation_label
  # Only called after one freshly qualified click. Animation/route/modal
  # frames may be unknown; observing them never authorizes another action.
  while [ "$SECONDS" -lt "$transition_deadline" ]; do
    attempt=$((attempt+1))
    entry_observation_label="$label-attempt-$attempt"
    if result=$(observed_switch_row "$phrase" "$label-attempt-$attempt"); then
      read -r y observed <<< "$result"
      if [ "$observed" = "$expected" ] && desktop_entry_ready "$entry_kind" && [ "$SECONDS" -lt "$transition_deadline" ]; then return 0; fi
    else
      printf '%s unknown UI/geometry/label: %s attempt=%s\n' "$(date -u --iso-8601=ns)" "$label" "$attempt" >> "$OUT/transition-observations.txt"
    fi
    [ "$SECONDS" -lt "$transition_deadline" ] || break
    sleep 1
  done
  printf 'transition timeout: %s expected_ui=%s entry=%s\n' "$label" "$expected" "$entry_kind" >> "$OUT/inconclusive-transitions.txt"
  capture_entry_timeout "$label"
  return 1
}
wait_app_exit() {
  local label=$1 attempt
  for attempt in $(seq 1 20); do
    flatpak ps --columns=instance,application,pid > "$OUT/$label-instance-check.txt" || return 1
    if ! grep -q org.localsend.localsend_app "$OUT/$label-instance-check.txt"; then return 0; fi
    sleep 1
  done
  printf 'app-exit timeout: %s\n' "$label" >> "$OUT/inconclusive-transitions.txt"
  return 1
}
identity_command() {
  local stage=$1 result=0
  shift
  printf '%s stage=%s remaining=%s command=' "$(date -u --iso-8601=ns)" "$stage" "$((transition_deadline-SECONDS))" >> "$OUT/$identity_label-identity-observer.txt"
  printf '%q ' "$@" >> "$OUT/$identity_label-identity-observer.txt"
  printf '\n' >> "$OUT/$identity_label-identity-observer.txt"
  run_ui_observer "$@" 2>> "$OUT/$identity_label-identity-observer.txt" || result=$?
  printf 'stage=%s exit=%s\n' "$stage" "$result" >> "$OUT/$identity_label-identity-observer.txt"
  return "$result"
}
candidate_identity_unchanged() {
  # Caller locals bind this bounded check to one row/PID observation.
  local after_inode after_pid_namespace after_mount_namespace
  identity_command "start-$instance-$anchor-$pid" sudo -n cat "/proc/$pid/stat" > "$OUT/$evidence_prefix-stat.txt" || return 1
  ticks=$(identity_command "start-field-$instance-$anchor-$pid" awk '{sub(/^.*\) /,""); print $20}' "$OUT/$evidence_prefix-stat.txt") || return 1
  [[ "$ticks" =~ ^[0-9]+$ ]] && [ "$ticks" = "$before_ticks" ] || return 1
  after_inode=$(identity_command "exe-inode-after-$instance-$anchor-$pid" sudo -n stat -Lc '%d:%i' "/proc/$pid/exe") || return 1
  after_pid_namespace=$(identity_command "pid-namespace-after-$instance-$anchor-$pid" sudo -n readlink "/proc/$pid/ns/pid") || return 1
  after_mount_namespace=$(identity_command "mount-namespace-after-$instance-$anchor-$pid" sudo -n readlink "/proc/$pid/ns/mnt") || return 1
  printf 'start=%s executable_inode=%s pid_namespace=%s mount_namespace=%s\n' "$ticks" "$after_inode" "$after_pid_namespace" "$after_mount_namespace" > "$OUT/$evidence_prefix-identity-after.txt"
  [ "$after_inode" = "$actual" ] && [ "$after_pid_namespace" = "$pid_namespace" ] && [ "$after_mount_namespace" = "$mount_namespace" ]
}
qualified_app_pid() {
  # Flatpak ps reports the supervisor, not the executable leaf. Resolve the
  # unique actual app leaf across ALL app-ID rows, including nested sandboxes.
  local identity_label=$1 transition_deadline=$((SECONDS+12)) uid rows instance anchor descendants pid actual expected status info ticks before_ticks gtk_path found=''
  local qualified_count=0 qualified_tokens='' token row_count=0 row_qualified result evidence_prefix pid_namespace mount_namespace
  [[ "${EXPECTED_APP_COMMIT:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  uid=$(id -u) || return 1
  identity_command instances flatpak ps --columns=instance,application,pid > "$OUT/$identity_label-instances.txt" || return 1
  identity_command topology ps -u "$uid" -o pid=,ppid=,uid=,comm= > "$OUT/$identity_label-topology.txt" || return 1
  rows=$(identity_command instance-filter awk '$2=="org.localsend.localsend_app" {print $1,$3}' "$OUT/$identity_label-instances.txt") || return 1
  [ -n "$rows" ] || return 1
  while read -r instance anchor; do
    [[ "$instance" =~ ^[0-9]+$ && "$anchor" =~ ^[0-9]+$ ]] || return 1
    row_count=$((row_count+1))
    row_qualified=0
    printf 'instance=%s anchor=%s examining-all-descendants\n' "$instance" "$anchor" >> "$OUT/$identity_label-instance-selection.txt"
    descendants=$(identity_command "descendants-$instance" awk -v anchor="$anchor" '
      {parent[$1]=$2} END {for(pid in parent){p=pid; for(n=0;n<1024 && p in parent;n++){if(p==anchor){print pid;break}p=parent[p]}}}
    ' "$OUT/$identity_label-topology.txt") || return 1
    if [ -z "$descendants" ]; then
      printf 'instance=%s anchor=%s inconclusive=no-observed-descendants\n' "$instance" "$anchor" >> "$OUT/$identity_label-instance-selection.txt"
      return 1
    fi
    for pid in $descendants; do
      evidence_prefix="$identity_label-instance-$instance-anchor-$anchor-$pid"
      # Observer failures are UNKNOWN and stop; they cannot hide another app leaf.
      identity_command "start-before-$instance-$anchor-$pid" sudo -n cat "/proc/$pid/stat" > "$OUT/$evidence_prefix-stat-before.txt" || return 1
      before_ticks=$(identity_command "start-before-field-$instance-$anchor-$pid" awk '{sub(/^.*\) /,""); print $20}' "$OUT/$evidence_prefix-stat-before.txt") || return 1
      [[ "$before_ticks" =~ ^[0-9]+$ ]] || return 1
      status="$OUT/$evidence_prefix-status.txt"
      identity_command "status-$instance-$anchor-$pid" sudo -n cat "/proc/$pid/status" > "$status" || return 1
      identity_command "cgroup-$instance-$anchor-$pid" sudo -n cat "/proc/$pid/cgroup" > "$OUT/$evidence_prefix-cgroup.txt" || return 1
      identity_command "exe-$instance-$anchor-$pid" sudo -n readlink "/proc/$pid/exe" > "$OUT/$evidence_prefix-exe.txt" || return 1
      actual=$(identity_command "exe-inode-$instance-$anchor-$pid" sudo -n stat -Lc '%d:%i' "/proc/$pid/exe") || return 1
      pid_namespace=$(identity_command "pid-namespace-$instance-$anchor-$pid" sudo -n readlink "/proc/$pid/ns/pid") || return 1
      mount_namespace=$(identity_command "mount-namespace-$instance-$anchor-$pid" sudo -n readlink "/proc/$pid/ns/mnt") || return 1
      printf 'pid=%s pid_namespace=%s mount_namespace=%s\n' "$pid" "$pid_namespace" "$mount_namespace" > "$OUT/$evidence_prefix-namespaces.txt"
      result=0
      expected=$(identity_command "app-inode-$instance-$anchor-$pid" sudo -n stat -Lc '%d:%i' "/proc/$pid/root/app/localsend_app") || result=$?
      if [ "$result" != 0 ]; then
        # Host supervisor roots have no /app. Prove absence; any other error stops.
        [ "$result" = 1 ] || return 1
        identity_command "sandbox-root-present-$instance-$anchor-$pid" sudo -n test -d "/proc/$pid/root" || return 1
        identity_command "app-path-absent-$instance-$anchor-$pid" sudo -n test ! -e "/proc/$pid/root/app/localsend_app" || return 1
        candidate_identity_unchanged || return 1
        printf 'instance=%s anchor=%s pid=%s rejected=sandbox-app-path-absent actual_inode=%s\n' "$instance" "$anchor" "$pid" "$actual" >> "$OUT/$identity_label-instance-selection.txt"
        continue
      fi
      printf 'pid=%s executable_inode=%s expected_inode=%s\n' "$pid" "$actual" "$expected" >> "$OUT/$identity_label-identity-observer.txt"
      if [ "$actual" != "$expected" ]; then
        candidate_identity_unchanged || return 1
        printf 'instance=%s anchor=%s pid=%s rejected=executable-inode-mismatch actual=%s expected=%s\n' "$instance" "$anchor" "$pid" "$actual" "$expected" >> "$OUT/$identity_label-instance-selection.txt"
        continue
      fi
      identity_command "maps-$instance-$anchor-$pid" sudo -n cat "/proc/$pid/maps" > "$OUT/$evidence_prefix-maps.txt" || return 1
      gtk_path=$(identity_command "gtk-path-$instance-$anchor-$pid" awk '$NF~/\/libgtk-3\.so\./ {paths[$NF]=1} END {for(path in paths) print path}' "$OUT/$evidence_prefix-maps.txt") || return 1
      [[ "$gtk_path" = /* && "$gtk_path" != *$'\n'* ]] || return 1
      identity_command "gtk-hash-$instance-$anchor-$pid" sudo -n sha256sum "/proc/$pid/root$gtk_path" > "$OUT/$evidence_prefix-gtk-sha256.txt" || return 1
      identity_command "gtk-build-id-$instance-$anchor-$pid" sudo -n readelf -n "/proc/$pid/root$gtk_path" > "$OUT/$evidence_prefix-gtk-build-id.txt" || return 1
      info="$OUT/$evidence_prefix-flatpak-info.txt"
      identity_command "sandbox-$instance-$anchor-$pid" sudo -n cat "/proc/$pid/root/.flatpak-info" > "$info" || return 1
      identity_command "uid-$instance-$anchor-$pid" awk -v uid="$uid" '/^Uid:/ {matched=($2==uid && $3==uid && $4==uid && $5==uid)} END {exit !matched}' "$status" || return 1
      result=0
      identity_command "sandbox-match-$instance-$anchor-$pid" awk -v instance="$instance" -v commit="$EXPECTED_APP_COMMIT" '
        /^\[/ {section=$0} section=="[Application]" && $0=="name=org.localsend.localsend_app" {app=1}
        section=="[Instance]" && $0=="instance-id=" instance {matched=1}
        section=="[Instance]" && $0=="app-commit=" commit {immutable=1} END {exit !(app && matched && immutable)}
      ' "$info" || result=$?
      if [ "$result" != 0 ]; then
        [ "$result" = 1 ] || return 1
        candidate_identity_unchanged || return 1
        printf 'instance=%s anchor=%s pid=%s rejected=own-sandbox-instance-or-commit-mismatch expected_commit=%s\n' "$instance" "$anchor" "$pid" "$EXPECTED_APP_COMMIT" >> "$OUT/$identity_label-instance-selection.txt"
        continue
      fi
      candidate_identity_unchanged || return 1
      row_qualified=1
      token="$pid:$ticks"
      case " $qualified_tokens " in
        *" $token "*) printf 'instance=%s pid=%s qualified=same-leaf-already-counted start=%s\n' "$instance" "$pid" "$ticks" >> "$OUT/$identity_label-instance-selection.txt";;
        *)
          qualified_tokens="$qualified_tokens $token"
          qualified_count=$((qualified_count+1))
          printf 'instance=%s anchor=%s pid=%s qualified=immutable-app-leaf start=%s commit=%s\n' "$instance" "$anchor" "$pid" "$ticks" "$EXPECTED_APP_COMMIT" >> "$OUT/$identity_label-instance-selection.txt"
          if [ "$qualified_count" = 1 ]; then
            found=$pid
            printf '%s\n' "$actual" > "$OUT/$identity_label-executable-identity.txt"
            printf '%s %s %s %s\n' "$instance" "$anchor" "$pid" "$ticks" > "$OUT/$identity_label-process-identity.txt"
          fi;;
      esac
    done
    printf 'instance=%s qualified_leaf=%s\n' "$instance" "$row_qualified" >> "$OUT/$identity_label-instance-selection.txt"
  done <<< "$rows"
  printf 'examined_rows=%s unique_qualified_leaves=%s\n' "$row_count" "$qualified_count" >> "$OUT/$identity_label-instance-selection.txt"
  [ "$qualified_count" = 1 ] && [ -n "$found" ] && [ "$SECONDS" -lt "$transition_deadline" ] || return 1
  printf '%s\n' "$found"
}
xres_host_namespace() {
  local display_name=${DISPLAY%%.*} server_pid init_namespace collector_namespace server_namespace
  identity_command xserver-topology ps -eo pid=,comm=,args= > "$OUT/$identity_label-xserver-topology.txt" || return 1
  server_pid=$(identity_command xserver-selection awk -v display="$display_name" '
    $2=="Xorg" {for(i=3;i<=NF;i++) if($i==display) {print $1; break}}
  ' "$OUT/$identity_label-xserver-topology.txt") || return 1
  [[ "$server_pid" =~ ^[0-9]+$ ]] || return 1
  init_namespace=$(identity_command init-pid-namespace sudo -n readlink /proc/1/ns/pid) || return 1
  collector_namespace=$(identity_command collector-pid-namespace readlink /proc/self/ns/pid) || return 1
  server_namespace=$(identity_command server-pid-namespace sudo -n readlink "/proc/$server_pid/ns/pid") || return 1
  printf 'display=%s xserver=%s init=%s collector=%s server=%s\n' "$DISPLAY" "$server_pid" "$init_namespace" "$collector_namespace" "$server_namespace" >> "$OUT/$identity_label-identity-observer.txt"
  [ -n "$init_namespace" ] && [ "$init_namespace" = "$collector_namespace" ] && [ "$init_namespace" = "$server_namespace" ]
}
xres_query_matches() {
  local window=$1 expected=$2 owner
  owner=$(identity_command "xres-window-$window" /home/mint/xres-owner "$window") || return $?
  [[ "$owner" =~ ^[0-9]+$ && "$expected" =~ ^[0-9]+$ ]] || return 4
  printf 'window=%s host_expected=%s xres_owner=%s\n' "$window" "$expected" "$owner" >> "$OUT/$identity_label-identity-observer.txt"
  [ "$owner" = "$expected" ] || return 6
}
xres_negative_controls() {
  local pid=$1 result=0
  [[ "${XRES_CONTROL_WINDOW:-}" =~ ^[0-9]+$ && "${XRES_CONTROL_DESTROYED:-}" =~ ^[0-9]+$ && "${XRES_CONTROL_PID:-}" =~ ^[0-9]+$ ]] || return 1
  [ "$XRES_CONTROL_PID" != "$pid" ] || return 1
  xres_query_matches "$XRES_CONTROL_WINDOW" "$XRES_CONTROL_PID" || return 1
  xres_query_matches "$XRES_CONTROL_WINDOW" "$pid" || result=$?
  printf 'unrelated-window-result=%s expected=6\n' "$result" >> "$OUT/$identity_label-identity-observer.txt"
  [ "$result" = 6 ] || return 1
  result=0
  identity_command destroyed-window /home/mint/xres-owner "$XRES_CONTROL_DESTROYED" > "$OUT/$identity_label-destroyed-owner.txt" || result=$?
  printf 'destroyed-window-result=%s expected=3\n' "$result" >> "$OUT/$identity_label-identity-observer.txt"
  [ "$result" = 3 ]
}
start_xres_control() {
  local identity_label="xres-control-${1}" transition_deadline=$((SECONDS+8)) fixture_report
  # Initial session or a newly restarted LightDM only. The old fixture exits
  # when its X connection closes; a remembered numeric PID is never signaled.
  /home/mint/xres-owner --fixture > "$OUT/$identity_label.txt" 2> "$OUT/$identity_label-error.txt" &
  XRES_CONTROL_PID=$!
  while [ "$SECONDS" -lt "$transition_deadline" ] && [ ! -s "$OUT/$identity_label.txt" ]; do sleep .1; done
  fixture_report=$(identity_command fixture-report cat "$OUT/$identity_label.txt") || return 1
  [[ "$fixture_report" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] || return 1
  local reported_pid
  read -r XRES_CONTROL_WINDOW reported_pid XRES_CONTROL_DESTROYED <<< "$fixture_report"
  [ "$reported_pid" = "$XRES_CONTROL_PID" ] || return 1
  export XRES_CONTROL_PID XRES_CONTROL_WINDOW XRES_CONTROL_DESTROYED
  xres_host_namespace || return 1
  xres_query_matches "$XRES_CONTROL_WINDOW" "$XRES_CONTROL_PID" || return 1
  [ "$SECONDS" -lt "$transition_deadline" ]
}
qualified_visible_window() {
  local identity_label=$1 pid=$2 transition_deadline=$((SECONDS+8)) windows expected_ticks actual_ticks actual_inode expected_inode uid
  windows=$(identity_command windows xdotool search --onlyvisible --name '^LocalSend$') || return 1
  [[ "$windows" =~ ^[0-9]+$ ]] || return 1
  identity_command window-properties xprop -id "$windows" WM_CLASS _NET_WM_PID > "$OUT/$identity_label-window-properties.txt" || return 1
  identity_command window-class grep -Fq '"org.localsend.localsend_app"' "$OUT/$identity_label-window-properties.txt" || return 1
  xres_host_namespace || return 1
  xres_negative_controls "$pid" || return 1
  xres_query_matches "$windows" "$pid" || return 1
  # XRes reports host PID in this verified server namespace, never sandbox PID2.
  # Bind the later owner query back to the earlier unique leaf qualification.
  expected_ticks=$(identity_command qualified-start awk -v pid="$pid" '$3==pid {print $4}' "$OUT/$identity_label-process-identity.txt") || return 1
  identity_command owner-stat sudo -n cat "/proc/$pid/stat" > "$OUT/$identity_label-owner-stat.txt" || return 1
  actual_ticks=$(identity_command owner-start awk '{sub(/^.*\) /,""); print $20}' "$OUT/$identity_label-owner-stat.txt") || return 1
  [[ "$expected_ticks" =~ ^[0-9]+$ && "$actual_ticks" =~ ^[0-9]+$ ]] || return 1
  [ "$actual_ticks" = "$expected_ticks" ] || return 1
  expected_inode=$(identity_command qualified-inode cat "$OUT/$identity_label-executable-identity.txt") || return 1
  actual_inode=$(identity_command owner-inode sudo -n stat -Lc '%d:%i' "/proc/$pid/exe") || return 1
  [ "$actual_inode" = "$expected_inode" ] || return 1
  uid=$(id -u) || return 1
  identity_command owner-status sudo -n cat "/proc/$pid/status" > "$OUT/$identity_label-owner-status.txt" || return 1
  identity_command owner-uid awk -v uid="$uid" '/^Uid:/ {matched=($2==uid && $3==uid && $4==uid && $5==uid)} END {exit !matched}' "$OUT/$identity_label-owner-status.txt" || return 1
  [ "$SECONDS" -lt "$transition_deadline" ] || return 1
  printf '%s\n' "$windows"
}
