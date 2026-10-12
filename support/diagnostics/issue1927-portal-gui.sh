#!/usr/bin/env bash
# Sourced in the normal Mint session; relogin/session_environment come from VM harness.
set -Eeuo pipefail
mkdir -p evidence/candidate
OUT=$(realpath evidence/candidate)
source /home/mint/ui.sh
{ flatpak info --user org.localsend.localsend_app; flatpak info --user --show-metadata org.localsend.localsend_app; } > "$OUT/identity.txt"
APP=org.localsend.localsend_app
HOST_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
ENTRY="$HOST_CONFIG/autostart/$APP.desktop"
request_pending=0
start_portal_monitor() {
  local label=$1 owner
  test "$request_pending" = 0
  if [ -n "${monitor_pid:-}" ]; then stop_portal_monitor; fi
  owner=$(timeout -s KILL 8 gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.GetNameOwner org.freedesktop.portal.Desktop)
  owner=$(printf '%s\n' "$owner" | sed -n "s/^(':\([0-9.]*\)',)$/:\1/p")
  [[ "$owner" =~ ^:[0-9]+\.[0-9]+$ ]]
  PORTAL_LOG="$OUT/$label-portal-raw.txt"
  known_call_count=0
  printf '%s portal_owner=%s\n' "$(date -u --iso-8601=ns)" "$owner" > "$OUT/$label-portal-owner.txt"
  dbus-monitor --session "interface='org.freedesktop.portal.Background',member='RequestBackground'" "type='signal',sender='$owner',interface='org.freedesktop.portal.Request'" "type='method_call',interface='org.freedesktop.portal.Request',member='Close'" "type='method_return',sender='$owner'" "type='error',sender='$owner'" > "$PORTAL_LOG" 2>&1 &
  monitor_pid=$!
  sleep 1
  kill -0 "$monitor_pid"
  cat "/proc/$monitor_pid/stat" > "$OUT/$label-monitor-stat.txt"
  monitor_ticks=$(awk '{sub(/^.*\) /,"");print $20}' "$OUT/$label-monitor-stat.txt")
  [[ "$monitor_ticks" =~ ^[0-9]+$ ]]
}
stop_portal_monitor() {
  local n ticks
  if [ ! -e "/proc/$monitor_pid/stat" ]; then wait "$monitor_pid" || true; monitor_pid=''; return; fi
  ticks=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$monitor_pid/stat")
  test "$ticks" = "$monitor_ticks" || { printf 'monitor pid reused; no signal sent\n' >> "$OUT/cleanup-receipt.txt"; monitor_pid=''; return; }
  kill "$monitor_pid" 2>/dev/null || true
  for n in $(seq 1 20); do
    kill -0 "$monitor_pid" 2>/dev/null || break
    sleep .1
  done
  kill -KILL "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" || true
  monitor_pid=''
}
start_portal_monitor initial
wait_launch_bookkeeping() {
  local label=$1 identity_label="$1-launch-ready" transition_deadline=$2 attempt=0 rows='' previous_rows='' result uid
  uid=$(identity_command uid id -u) || return 1
  wid=''
  while [ "$SECONDS" -lt "$transition_deadline" ]; do
    attempt=$((attempt+1))
    identity_command "instances-$attempt" flatpak ps --columns=instance,application,pid > "$OUT/$identity_label-$attempt-instances.txt" || return 1
    identity_command "topology-$attempt" ps -u "$uid" -o pid=,ppid=,uid=,comm= > "$OUT/$identity_label-$attempt-topology.txt" || return 1
    identity_command "rows-$attempt" awk '$2=="org.localsend.localsend_app" {print $1,$3}' "$OUT/$identity_label-$attempt-instances.txt" > "$OUT/$identity_label-$attempt-rows.txt" || return 1
    rows=$(identity_command "sort-$attempt" sort "$OUT/$identity_label-$attempt-rows.txt") || return 1
    result=0
    identity_command "anchors-$attempt" awk '
      NR==FNR {present[$1]=1; next}
      $2=="org.localsend.localsend_app" {rows++; if($1 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || !($3 in present)) missing=1}
      END {exit !(rows && !missing)}
    ' "$OUT/$identity_label-$attempt-topology.txt" "$OUT/$identity_label-$attempt-instances.txt" || result=$?
    if [ "$result" != 0 ]; then
      test "$result" = 1 || return 1
      previous_rows=''
      printf 'attempt=%s unresolved-instance-anchors; retaining snapshot, no row excluded\n' "$attempt" >> "$OUT/$identity_label-convergence.txt"
      sleep .25
      continue
    fi
    result=0
    run_ui_observer xdotool search --onlyvisible --name '^LocalSend$' > "$OUT/$identity_label-$attempt-windows.txt" 2> "$OUT/$identity_label-$attempt-window-error.txt" || result=$?
    printf 'attempt=%s bounded-visible-query-status=%s\n' "$attempt" "$result" >> "$OUT/$identity_label-convergence.txt"
    test ! -s "$OUT/$identity_label-$attempt-window-error.txt" || return 1
    if [ "$result" = 0 ] && [ "$rows" = "$previous_rows" ]; then
      wid=$(identity_command "window-first-$attempt" head -n 1 "$OUT/$identity_label-$attempt-windows.txt") || return 1
      test -n "$wid" || return 1
      break
    fi
    test "$result" = 0 || test "$result" = 1 || return 1
    previous_rows=$rows
    sleep .25
  done
  test -n "$wid" && test "$SECONDS" -lt "$transition_deadline"
}
launch_settings() {
  local label=$1 existing_visible_phase=${2:-} foreground_phase=${3:-} pid launcher_pid launcher_result=0
  local launch_deadline=$((SECONDS+30)) remaining
  test -z "$existing_visible_phase" || test -z "$foreground_phase"
  if [ -z "$existing_visible_phase" ]; then
    if [ -n "$foreground_phase" ]; then
      # Reap this owned activation launcher before observing Flatpak bookkeeping.
      remaining=$((launch_deadline-SECONDS))
      test "$remaining" -gt 0
      timeout -s KILL "$remaining" flatpak run --user org.localsend.localsend_app > "$OUT/$label-app.log" 2>&1 &
      launcher_pid=$!
      wait "$launcher_pid" || launcher_result=$?
      printf 'owned_launcher=%s reaped_status=%s\n' "$launcher_pid" "$launcher_result" > "$OUT/$label-launcher-receipt.txt"
      test "$launcher_result" = 0
    else
      flatpak run --user org.localsend.localsend_app > "$OUT/$label-app.log" 2>&1 &
    fi
  fi
  wait_launch_bookkeeping "$label" "$launch_deadline"
  snapshot "$label-before-input"
  wait_rendered_application "$label"
  pid=$(qualified_app_pid "$label")
  wid=$(qualified_visible_window "$label" "$pid")
  if [ -n "$existing_visible_phase" ]; then
    cmp "$OUT/$existing_visible_phase-process-identity.txt" "$OUT/$label-process-identity.txt"
    test "$wid" = "$(cat "$OUT/$existing_visible_phase-window.txt")"
  fi
  if [ -n "$foreground_phase" ]; then
    cmp "$OUT/$foreground_phase-process-identity.txt" "$OUT/$label-process-identity.txt"
  fi
  stabilize_window initialized
  xdotool mousemove --window "$wid" 105 211 click 1
  sleep 2
  import -window "$wid" "$OUT/$label-settings.png"
}
snapshot() {
  local label=$1 identity_label=$1 transition_deadline=$((SECONDS+12)) name window windows
  identity_command sessions loginctl list-sessions > "$OUT/$label-sessions.txt" || true
  identity_command instances flatpak ps --columns=instance,application,pid > "$OUT/$label-processes.txt" || true
  identity_command processes ps -eo pid,ppid,uid,comm,args >> "$OUT/$label-processes.txt" || true
  identity_command desktop import -window root "$OUT/$label-desktop.png" || true
  windows=$(identity_command visible-windows xdotool search --onlyvisible --name '^LocalSend$') || windows=''
  printf '%s\n' "$windows" > "$OUT/$label-visible-windows.txt"
  for window in $windows; do
    identity_command "window-$window" xprop -id "$window" WM_CLASS _NET_WM_PID >> "$OUT/$label-window-properties.txt" || true
  done
  for name in localsend_app org.localsend.localsend_app; do
    identity_command "host-stat-$name" stat "$HOST_CONFIG/autostart/$name.desktop" >> "$OUT/$label-host-entry.txt" || true
    identity_command "host-read-$name" cat "$HOST_CONFIG/autostart/$name.desktop" >> "$OUT/$label-host-entry.txt" || true
  done
  identity_command preferences find "$HOME/.var/app/org.localsend.localsend_app" -maxdepth 5 -name '*preferences*' -type f -exec grep -oE '"flutter.ls_(flatpak_auto_start(_hidden)?|launch_at_startup)"[[:space:]]*:[[:space:]]*(true|false)' {} \; > "$OUT/$label-preferences.txt" || true
  if [ -n "${wid:-}" ]; then identity_command settings import -window "$wid" "$OUT/$label-settings.png" || true; fi
}
# No retry/reset is permitted while external request completion is unknown.
fail_case() {
  printf '%s invalid_or_incomplete=%s request_pending=%s; no more mutations\n' "$(date -u --iso-8601=ns)" "$1" "$request_pending" >> "$OUT/verdicts.txt"
  snapshot failure-terminal || true
  stop_ui_recording || true
  exit 40
}
permission_read() {
  local label=$1 expected=$2 value result=0
  timeout -s KILL 8 flatpak permission-show "$APP" > "$OUT/$label-permission-table.txt" 2>&1 || printf 'exit=%s\n' "$?" >> "$OUT/$label-permission-table.txt"
  timeout -s KILL 8 gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore --object-path /org/freedesktop/impl/portal/PermissionStore --method org.freedesktop.impl.portal.PermissionStore.GetPermission background background "$APP" > "$OUT/$label-permission-exact.txt" 2>&1 || result=$?
  if [ "$result" != 0 ]; then
    test "$result" = 1 && grep -q 'GDBus.Error:org.freedesktop.portal.Error.NotFound:' "$OUT/$label-permission-exact.txt" && test -z "$expected" || fail_case "$label-permission-read-error"
    printf '%s table=background id=background app=%s value=UNSET\n' "$(date -u --iso-8601=ns)" "$APP" >> "$OUT/permissions.txt"
    return
  fi
  value=$(sed -n "s/^(\['\(yes\|no\|ask\)'\],)$/\1/p" "$OUT/$label-permission-exact.txt")
  [[ "$value" =~ ^(yes|no|ask)$ ]] || fail_case "$label-permission-unknown"
  printf '%s table=background id=background app=%s value=%s\n' "$(date -u --iso-8601=ns)" "$APP" "$value" >> "$OUT/permissions.txt"
  test -z "$expected" || test "$value" = "$expected" || fail_case "$label-permission-readback"
}
permission_set() {
  local label=$1 value=$2 result=0
  test "$request_pending" = 0 || fail_case "$label-live-request"
  permission_read "$label-before" ''
  portal_index
  test "$(wc -l < "$OUT/portal-calls.txt")" = "$known_call_count" || fail_case "$label-late-request-before-permission-mutation"
  timeout -s KILL 8 flatpak permission-set background background "$APP" "$value" > "$OUT/$label-permission-operation.txt" 2>&1 || result=$?
  printf '%s exit=%s exact_app=%s value=%s\n' "$(date -u --iso-8601=ns)" "$result" "$APP" "$value" >> "$OUT/$label-permission-operation.txt"
  if [ "$result" != 0 ]; then
    # SetPermission can update the service's in-memory entry before a save error.
    # Observe that possibility, then stop; never interpret failure as unchanged.
    permission_read "$label-failed-operation" ''
    fail_case "$label-permission-operation"
  fi
  permission_read "$label-after" "$value"
}
migration_gate() {
  local label=$1
  if [ ! -e "$HOME/.var/app/$APP" ]; then
    test -d "$HOME/.var/app" && test -r "$HOME/.var/app" && test -x "$HOME/.var/app" || fail_case "$label-profile-unobservable"
    printf 'profile directory absent; legacy migration key absent\n' > "$OUT/$label-migration-keys.txt"
    return
  fi
  # Retain only autostart keys; never erase preferences to manufacture OFF.
  timeout -s KILL 8 find "$HOME/.var/app/$APP" -maxdepth 5 -name '*preferences*' -type f -exec grep -oE '"flutter.ls_(flatpak_auto_start(_hidden)?|launch_at_startup)"[[:space:]]*:[[:space:]]*(true|false)' {} \; > "$OUT/$label-migration-keys.txt"
  if grep -Eq '"flutter.ls_launch_at_startup"[[:space:]]*:[[:space:]]*true' "$OUT/$label-migration-keys.txt"; then fail_case "$label-legacy-migration"; fi
}
entry_read() {
  local label=$1
  printf '%s host_config=%s entry=%s\n' "$(date -u --iso-8601=ns)" "$HOST_CONFIG" "$ENTRY" > "$OUT/$label-entry.txt"
  if [ ! -e "$ENTRY" ]; then
    test ! -L "$ENTRY" || fail_case "$label-dangling-entry-symlink"
    test -d "$HOST_CONFIG/autostart" && test -r "$HOST_CONFIG/autostart" && test -x "$HOST_CONFIG/autostart" || fail_case "$label-unobservable-host-directory"
    printf 'ABSENT\n' > "$OUT/$label-entry-state.txt"
    return
  fi
  test -f "$ENTRY" && test ! -L "$ENTRY" && test -r "$ENTRY" || fail_case "$label-ambiguous-entry"
  timeout -s KILL 8 stat -Lc 'device=%d inode=%i size=%s mtime=%y' "$ENTRY" >> "$OUT/$label-entry.txt"
  timeout -s KILL 8 cat "$ENTRY" > "$OUT/$label-entry.desktop"
  cat "$OUT/$label-entry.desktop" >> "$OUT/$label-entry.txt"
  # Strictly qualify the retained portal's exact command vectors, not substrings.
  awk '
    /^\[/ {group=$0; if(group=="[Desktop Entry]") groups++; next}
    group=="[Desktop Entry]" && /^[^#=]+=/ {
      key=$0; sub(/=.*/,"",key); value=$0; sub(/^[^=]*=/,"",value)
      if(key=="Exec" || key=="Hidden" || key=="X-GNOME-Autostart-enabled" || key=="Type") {
        if(++seen[key]>1) bad=1
        values[key]=value
      }
    }
    END {
      if(groups!=1 || bad || values["Type"]!="Application") exit 2
      command="flatpak run --command=/app/localsend_app org.localsend.localsend_app"
      if(values["Exec"]!=command && values["Exec"]!=command" --hidden") exit 2
      if(seen["Hidden"] && values["Hidden"]!="true" && values["Hidden"]!="false") exit 2
      if(seen["X-GNOME-Autostart-enabled"] && values["X-GNOME-Autostart-enabled"]!="true" && values["X-GNOME-Autostart-enabled"]!="false") exit 2
      print values["Hidden"]=="true" || values["X-GNOME-Autostart-enabled"]=="false" ? "DISABLED" : "ENABLED"
      print values["Exec"]==command" --hidden" ? "HIDDEN" : "VISIBLE"
    }
  ' "$OUT/$label-entry.desktop" > "$OUT/$label-entry-state.txt" || fail_case "$label-entry-parser"
}
visible_identity() {
  local label=$1 original=$2 leaf
  leaf=$(qualified_app_pid "$label") || fail_case "$label-app-identity"
  wid=$(qualified_visible_window "$label" "$leaf") || fail_case "$label-window-identity"
  printf '%s\n' "$wid" > "$OUT/$label-window.txt"
  if [ -n "$original" ]; then
    cmp "$OUT/$original-process-identity.txt" "$OUT/$label-process-identity.txt" || fail_case "$label-replacement-process"
    cmp "$OUT/$original-window.txt" "$OUT/$label-window.txt" || fail_case "$label-replacement-window"
  fi
}
# Full append-only messages retain options and dictionaries. Index calls by
# sender+serial, method returns by destination+reply_serial, responses by handle.
portal_index() {
  : > "$OUT/portal-calls.txt"
  awk '
    function field(s,k, a,n,i) {n=split(s,a," ");for(i=1;i<=n;i++)if(index(a[i],k"=")==1){sub("^"k"=","",a[i]);sub(/;$/,"",a[i]);return a[i]}return ""}
    function flush( sender,serial,dest,reply,handle,path,code,key,n,a,i,last) {
      if(header ~ /^method call / && header ~ /member=RequestBackground/) {
        sender=field(header,"sender");serial=field(header,"serial");key=sender"/"serial
        calls[key]=1;print "CALL",sender,serial > callsfile
      }
      if(header ~ /^method return /) {
        dest=field(header,"destination");reply=field(header,"reply_serial");key=dest"/"reply
        if(key in calls) {
          n=split(body,a,"\n");handle=""
          for(i=1;i<=n;i++)if(a[i] ~ /object path "\/org\/freedesktop\/portal\/desktop\/request\//){
            handle=a[i];sub(/^.*object path "/,"",handle);sub(/".*$/,"",handle)
          }
          if(handle!=""){handles[handle]=key;print "HANDLE",dest,reply,handle}
          else print "INCOMPLETE_RETURN",dest,reply
        }
      }
      if(header ~ /^error /){dest=field(header,"destination");reply=field(header,"reply_serial");if((dest"/"reply) in calls)print "ERROR",dest,reply}
      if(header ~ /^signal / && header ~ /interface=org.freedesktop.portal.Request; member=Response/) {
        path=field(header,"path");code="";n=split(body,a,"\n")
        last="";for(i=1;i<=n;i++)if(a[i] !~ /^[ \t]*$/)last=a[i]
        if(last !~ /^[ \t]*\]$/)return
        for(i=1;i<=n;i++)if(a[i] ~ /^[ \t]*uint32 / && code==""){code=a[i];sub(/^[ \t]*uint32 /,"",code)}
        if(path in handles)print "RESPONSE",handles[path],path,code
        else print "UNATTRIBUTED_RESPONSE",path,code
      }
    }
    /^(signal|method call|method return|error) time=/ {flush();header=$0;body="";next}
    {body=body $0 "\n"} END{flush()}
  ' callsfile="$OUT/portal-calls.txt" "$PORTAL_LOG" > "$OUT/portal-index.txt"
}
portal_mark() {
  portal_index
  mark_calls=$(wc -l < "$OUT/portal-calls.txt")
  test "$mark_calls" = "$known_call_count" || fail_case "$1-unexpected-between-actions-mutation"
  date -u --iso-8601=ns > "$OUT/$1-boundary-utc.txt"
  cp "$OUT/portal-index.txt" "$OUT/$1-index-before.txt"
}
passive_boundary() {
  local label=$1
  portal_index
  test "$(wc -l < "$OUT/portal-calls.txt")" = "$mark_calls" || fail_case "$label-unexpected-passive-mutation"
  cp "$OUT/portal-index.txt" "$OUT/$label-index-after.txt"
}
terminal_payload() {
  local label=$1 sender=$2 serial=$3 handle
  handle=$(awk -v sender="$sender" -v serial="$serial" '$1=="HANDLE" && $2==sender && $3==serial {print $4}' "$OUT/portal-index.txt")
  [[ "$handle" = /org/freedesktop/portal/desktop/request/* ]] || fail_case "$label-no-handle"
  awk -v sender="$sender" -v serial="$serial" -v handle="$handle" '
    function field(s,k, a,n,i){n=split(s,a," ");for(i=1;i<=n;i++)if(index(a[i],k"=")==1){sub("^"k"=","",a[i]);sub(/;$/,"",a[i]);return a[i]}return ""}
    /^(signal|method call|method return|error) time=/ {
      selected=($0 ~ /^method call / && $0 ~ /member=RequestBackground/ && field($0,"sender")==sender && field($0,"serial")==serial) ||
        ($0 ~ /^signal / && $0 ~ /member=Response/ && field($0,"path")==handle)
      if(selected) messages++
    }
    selected {print} END{if(messages!=2)exit 2}
  ' "$PORTAL_LOG" > "$OUT/$label-call-response.txt" || fail_case "$label-incomplete-full-payload"
  printf '%s handle=%s sender=%s serial=%s\n' "$(date -u --iso-8601=ns)" "$handle" "$sender" "$serial" >> "$OUT/$label-request-attribution.txt"
}
attribute_request() {
  local label=$1 sender=$2 instance anchor leaf ticks sender_pid before_ticks after_ticks
  read -r instance anchor leaf ticks < "$OUT/$label-before-input-process-identity.txt"
  timeout -s KILL 8 gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.GetConnectionUnixProcessID "$sender" > "$OUT/$label-sender-credential.txt"
  sender_pid=$(sed -n 's/^(uint32 \([0-9]*\),)$/\1/p' "$OUT/$label-sender-credential.txt")
  [[ "$sender_pid" =~ ^[0-9]+$ ]] || fail_case "$label-sender-credential"
  timeout -s KILL 8 sudo -n cat "/proc/$sender_pid/stat" > "$OUT/$label-sender-stat-before.txt"
  before_ticks=$(awk '{sub(/^.*\) /,"");print $20}' "$OUT/$label-sender-stat-before.txt")
  timeout -s KILL 8 ps -u "$(id -u)" -o pid=,ppid=,uid=,comm= > "$OUT/$label-sender-topology.txt"
  # Flatpak 1.14.6 separately spawns its proxy with the same immutable app-info
  # bytes (flatpak-run-common.c:add_bwrap_wrapper/start_dbus_proxy). The proxy
  # is not a descendant of the app anchor and owns a different namespace.
  timeout -s KILL 8 sudo -n readlink "/proc/$sender_pid/exe" > "$OUT/$label-sender-executable.txt"
  test "$(basename "$(cat "$OUT/$label-sender-executable.txt")")" = xdg-dbus-proxy || fail_case "$label-sender-not-proxy"
  awk -v pid="$sender_pid" -v uid="$(id -u)" '$1==pid && $3==uid{found++}END{exit found!=1}' "$OUT/$label-sender-topology.txt" || fail_case "$label-sender-uid"
  timeout -s KILL 8 sudo -n cat "/proc/$sender_pid/root/.flatpak-info" > "$OUT/$label-sender-flatpak-info.txt"
  timeout -s KILL 8 sudo -n cat "/proc/$leaf/root/.flatpak-info" > "$OUT/$label-leaf-flatpak-info.txt"
  cmp "$OUT/$label-sender-flatpak-info.txt" "$OUT/$label-leaf-flatpak-info.txt" || fail_case "$label-sender-other-instance"
  timeout -s KILL 8 sudo -n readlink "/proc/$sender_pid/ns/pid" "/proc/$sender_pid/ns/mnt" > "$OUT/$label-sender-namespaces.txt"
  timeout -s KILL 8 sudo -n cat "/proc/$sender_pid/stat" > "$OUT/$label-sender-stat-after.txt"
  after_ticks=$(awk '{sub(/^.*\) /,"");print $20}' "$OUT/$label-sender-stat-after.txt")
  [[ "$before_ticks" =~ ^[0-9]+$ ]] && test "$before_ticks" = "$after_ticks" || fail_case "$label-sender-reused"
  visible_identity "$label-attributed" "$label-before-input"
  printf '%s sender=%s sender_host_pid=%s sender_start=%s instance=%s anchor=%s leaf=%s leaf_start=%s\n' "$(date -u --iso-8601=ns)" "$sender" "$sender_pid" "$before_ticks" "$instance" "$anchor" "$leaf" "$ticks" > "$OUT/$label-request-attribution.txt"
}
request_click() {
  local label=$1 phrase=$2 before=$3 original=$4 y sender serial response count
  local transition_deadline
  test "$request_pending" = 0 || fail_case "$label-prior-request-uncertain"
  visible_identity "$label-before-input" "$original"
  entry_read "$label-pre"
  snapshot "$label-pre"
  y=$(require_switch_state "$phrase" "$label-before-click" "$before") || fail_case "$label-input-ui"
  portal_mark "$label"
  start_ui_recording "$label"
  request_pending=1
  printf '%s qualified_window=%s single_click=(825,%s) phrase=%s\n' "$(date -u --iso-8601=ns)" "$wid" "$y" "$phrase" > "$OUT/$label-input.txt"
  timeout -s KILL 8 xdotool mousemove --window "$wid" 825 "$y" click 1
  transition_deadline=$((SECONDS+65))
  CLICK_DEADLINE=$transition_deadline
  while [ "$SECONDS" -lt "$transition_deadline" ]; do
    portal_index
    count=$(wc -l < "$OUT/portal-calls.txt")
    test "$count" -le "$((mark_calls+1))" || fail_case "$label-extra-request"
    if [ "$count" = "$((mark_calls+1))" ]; then
      read -r _ sender serial < <(tail -n 1 "$OUT/portal-calls.txt")
      if [ ! -f "$OUT/$label-request-attribution.txt" ]; then attribute_request "$label" "$sender"; fi
      response=$(awk -v key="$sender/$serial" '$1=="RESPONSE" && $2==key {print $4}' "$OUT/portal-index.txt")
      if [ -n "$response" ]; then
        [[ "$response" =~ ^[012]$ ]] || fail_case "$label-ambiguous-response"
        test "$SECONDS" -lt "$transition_deadline" || break
        terminal_payload "$label" "$sender" "$serial"
        test "$SECONDS" -lt "$transition_deadline" || break
        # This prototype creates one dedicated portal client per action and
        # closes it in finally. Response ends the backend request; require the
        # exact sender's connection to disappear before admitting another action.
        local owned remaining owner_result
        owned=true
        while [ "$SECONDS" -lt "$transition_deadline" ]; do
          remaining=$((transition_deadline-SECONDS)); test "$remaining" -le 8 || remaining=8
          owner_result=0
          timeout -s KILL "$remaining" gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner "$sender" > "$OUT/$label-client-owner.txt" 2>&1 || owner_result=$?
          test "$owner_result" = 0 || fail_case "$label-client-owner-read-error"
          owned=$(sed -n 's/^(\(true\|false\),)$/\1/p' "$OUT/$label-client-owner.txt")
          [[ "$owned" =~ ^(true|false)$ ]] || fail_case "$label-client-owner-unknown"
          portal_index
          test "$(wc -l < "$OUT/portal-calls.txt")" = "$((mark_calls+1))" || fail_case "$label-late-extra-request"
          if [ "$owned" = false ]; then break; fi
          sleep .25
        done
        test "$owned" = false && test "$SECONDS" -lt "$transition_deadline" || break
        request_pending=0
        known_call_count=$((mark_calls+1))
        printf '%s terminal_Response=%s sender=%s serial=%s\n' "$(date -u --iso-8601=ns)" "$response" "$sender" "$serial" > "$OUT/$label-terminal.txt"
        cp "$PORTAL_LOG" "$OUT/$label-portal-through-terminal.txt"
        cp "$OUT/portal-index.txt" "$OUT/$label-index-terminal.txt"
        sleep 2
        entry_read "$label-post"
        snapshot "$label-post"
        permission_read "$label-post" ''
        portal_index
        test "$(wc -l < "$OUT/portal-calls.txt")" = "$known_call_count" || fail_case "$label-post-extra-request"
        stop_ui_recording
        RESPONSE_CODE=$response
        return
      fi
    fi
    sleep .25
  done
  cp "$PORTAL_LOG" "$OUT/$label-incomplete-portal.txt"
  entry_read "$label-incomplete"
  fail_case "$label-no-terminal-response-no-retry"
}
accepted_transition() {
  local label=$1 phrase=$2 before=$3 after=$4 kind=$5
  request_click "$label" "$phrase" "$before" ''
  test "$RESPONSE_CODE" = 0 || fail_case "$label-not-accepted"
  # Inspect the response dictionary itself, not a boolean elsewhere in the log.
  local expected_autostart=$after
  if [ "$phrase" = 'Start hidden' ]; then expected_autostart=ON; fi
  awk -v expected="$expected_autostart" '
    /^signal / {response=1}
    response && /string "(background|autostart)"/ {key=$0;sub(/^.*string "/,"",key);sub(/".*$/,"",key);next}
    response && /boolean / && key!="" {value=$0;sub(/^.*boolean /,"",value);if(++seen[key]>1)bad=1;values[key]=value;key=""}
    END{exit !(seen["background"]==1 && seen["autostart"]==1 && !bad &&
      values["background"]=="true" && values["autostart"]==(expected=="ON"?"true":"false"))}
  ' "$OUT/$label-call-response.txt" || fail_case "$label-not-accepted-dictionary"
  wait_observed_transition "$phrase" "$label-ui" "$after" "$kind" "$CLICK_DEADLINE" || fail_case "$label-accepted-ui-entry"
  entry_read "$label-observed"
  portal_index
  test "$(wc -l < "$OUT/portal-calls.txt")" = "$known_call_count" || fail_case "$label-late-request-after-ui"
}
fresh_on() {
  local label=$1 row state hidden_state
  migration_gate "$label"
  permission_set "$label-restore" yes
  visible_identity "$label-reset-visible" ''
  row=$(observed_switch_row 'Autostart after login' "$label-reset-state") || fail_case "$label-reset-ui"
  read -r _ state <<< "$row"
  if [ "$state" = ON ]; then
    row=$(observed_switch_row 'Start hidden' "$label-reset-hidden") || fail_case "$label-reset-hidden-ui"
    read -r _ hidden_state <<< "$row"
    if [ "$hidden_state" = ON ]; then accepted_transition "$label-reset-visible" 'Start hidden' ON OFF host-flatpak-visible; fi
    accepted_transition "$label-reset-off" 'Autostart after login' ON OFF host-absent
  fi
  require_switch_state 'Autostart after login' "$label-known-off" OFF > /dev/null || fail_case "$label-off-unobserved"
  entry_read "$label-known-off"
  test "$(head -n 1 "$OUT/$label-known-off-entry-state.txt")" = ABSENT || fail_case "$label-off-host-not-absent"
  accepted_transition "$label-fresh-on" 'Autostart after login' OFF ON host-flatpak-visible
  test "$(cat "$OUT/$label-fresh-on-observed-entry-state.txt")" = $'ENABLED\nVISIBLE' || fail_case "$label-fresh-on-entry"
  snapshot "$label-on"
  grep -Eq '"flutter.ls_flatpak_auto_start"[[:space:]]*:[[:space:]]*true' "$OUT/$label-on-preferences.txt" || fail_case "$label-cache-on"
  grep -Eq '"flutter.ls_flatpak_auto_start_hidden"[[:space:]]*:[[:space:]]*false' "$OUT/$label-on-preferences.txt" || fail_case "$label-hidden-cache-off"
  require_switch_state 'Start hidden' "$label-hidden-off" OFF > /dev/null || fail_case "$label-hidden-not-off"
  visible_identity "$label-original" ''
}
close_reopen() {
  local label=$1 row state
  test "$request_pending" = 0 || fail_case "$label-live-request"
  migration_gate "$label-before-close"
  visible_identity "$label-close-visible" ''
  portal_mark "$label-close"
  timeout -s KILL 8 xdotool windowactivate "$wid" key alt+F4
  wait_app_exit "$label-true-close" || fail_case "$label-close-incomplete"
  passive_boundary "$label-close"
  wid=''
  portal_mark "$label-reopen"
  launch_settings "$label-reopened"
  migration_gate "$label-reopened"
  passive_boundary "$label-reopen"
  entry_read "$label-reopened"
  permission_read "$label-reopened" ''
  snapshot "$label-reopened"
  observed_switch_row 'Autostart after login' "$label-reopened-autostart" > "$OUT/$label-reopened-ui.txt" || fail_case "$label-reopen-ui"
  read -r _ state < "$OUT/$label-reopened-ui.txt"
  if [ "$state" = ON ]; then
    observed_switch_row 'Start hidden' "$label-reopened-hidden" >> "$OUT/$label-reopened-ui.txt" || fail_case "$label-reopen-hidden-ui"
  else
    printf 'hidden row unavailable when Autostart OFF; cache retained separately\n' >> "$OUT/$label-reopened-ui.txt"
  fi
}
mount_inspection() {
  local label=$1 leaf config
  visible_identity "$label-owner" ''
  read -r _ _ leaf _ < "$OUT/$label-owner-process-identity.txt"
  printf '%s host_HOME=%s effective_host_config=%s stock_permission_only=true\n' "$(date -u --iso-8601=ns)" "$HOME" "$HOST_CONFIG" > "$OUT/$label-host-paths.txt"
  timeout -s KILL 8 sudo -n cat "/proc/$leaf/environ" | tr '\0' '\n' | grep -E '^(HOME|XDG_CONFIG_HOME|FLATPAK_ID)=' > "$OUT/$label-sandbox-environment.txt"
  config=$(sed -n 's/^XDG_CONFIG_HOME=//p' "$OUT/$label-sandbox-environment.txt")
  [[ "$config" = /* ]] || fail_case "$label-missing-sandbox-xdg"
  timeout -s KILL 8 sudo -n cat "/proc/$leaf/mountinfo" > "$OUT/$label-mountinfo.txt"
  timeout -s KILL 8 findmnt -T "$HOST_CONFIG" > "$OUT/$label-host-mount.txt" 2>&1 || printf 'findmnt_exit=%s\n' "$?" >> "$OUT/$label-host-mount.txt"
  timeout -s KILL 8 sudo -n cat "/proc/$leaf/root/.flatpak-info" > "$OUT/$label-flatpak-info.txt"
  for path in "$HOST_CONFIG/autostart" "$HOST_CONFIG/autostart/$APP.desktop"; do
    timeout -s KILL 8 stat -Lc 'path=%n device=%d inode=%i mode=%a' "$path" >> "$OUT/$label-host-paths.txt" 2>&1 || printf 'stat_exit=%s\n' "$?" >> "$OUT/$label-host-paths.txt"
  done
  for path in "$config/autostart" "$config/autostart/$APP.desktop" "$HOME/.config/autostart/$APP.desktop"; do
    timeout -s KILL 8 sudo -n stat -Lc 'path=%n device=%d inode=%i mode=%a' "/proc/$leaf/root$path" >> "$OUT/$label-sandbox-paths.txt" 2>&1 || printf 'stat_exit=%s\n' "$?" >> "$OUT/$label-sandbox-paths.txt"
  done
  printf 'READ_ONLY_STOCK_INSPECTION; errors/absence do not imply OFF or host mount capability; no :ro/:create matrix performed\n' > "$OUT/$label-scope.txt"
}
# Read-only supported GI AT-SPI traversal; missing APIs/ambiguous rows stop A.
# Real X input is used, never an internal set_enabled mutation.
# https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/
cat > "$OUT/startup-accessibility.js" <<'GJS'
const A=imports.gi.Atspi;
A.init();
let nodes=[],candidates=[];
function visit(n,parent,depth) {
    if(depth>40 || nodes.length>4000) throw Error("accessibility traversal bound");
    const id=nodes.length,states=n.get_state_set();
    nodes.push({id,parent,name:n.get_name(),role:n.get_role_name(),pid:n.get_process_id(),
        showing:states.contains(A.StateType.SHOWING),enabled:states.contains(A.StateType.ENABLED),
        checked:states.contains(A.StateType.CHECKED),obj:n});
    for(let i=0;i<n.get_child_count();i++) visit(n.get_child_at_index(i),id,depth+1);
}
visit(A.get_desktop(0),-1,0);
function under(n,id){let p=n.id;for(let i=0;i<50 && p>=0;i++){if(p===id)return true;p=nodes[p].parent;}return false;}
for(const label of nodes.filter(n=>n.name==="LocalSend" && n.showing)) {
    let p=label.parent;
    for(let i=0;i<5 && p>=0;i++,p=nodes[p].parent) {
        const matches=nodes.filter(n=>under(n,p) && n.showing && n.enabled &&
            [A.Role.CHECK_BOX,A.Role.TOGGLE_BUTTON,A.Role.SWITCH].includes(n.obj.get_role()));
        const labels=nodes.filter(n=>under(n,p) && n.name==="LocalSend" && n.showing);
        if(matches.length===1 && labels.length===1) {
            const n=matches[0],r=n.obj.get_component_iface().get_extents(A.CoordType.SCREEN);
            const action=n.obj.get_action_iface();
            if(!action || action.get_n_actions()<1) throw Error("missing accessible action API");
            let actions=[];for(let j=0;j<action.get_n_actions();j++)actions.push(action.get_action_name(j));
            candidates.push({id:n.id,pid:n.pid,row:p,checked:n.checked,x:r.x,y:r.y,w:r.width,h:r.height,actions});
            break;
        }
    }
}
print(JSON.stringify({tree:nodes.map(({obj,...rest})=>rest),candidates}));
if(candidates.length!==1) throw Error("ambiguous/unavailable LocalSend Startup switch");
GJS
revocation_cleanup() {
  local result=$?
  trap - EXIT
  printf '%s harness_exit=%s request_pending=%s; cleanup never mutates uncertain portal request\n' "$(date -u --iso-8601=ns)" "$result" "$request_pending" >> "$OUT/cleanup-receipt.txt"
  stop_ui_recording || true
  if [ -n "$monitor_pid" ]; then stop_portal_monitor; fi
  if [ -n "$startup_launcher" ]; then
    if [ -f "/proc/$startup_launcher/stat" ] && [ "$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$startup_launcher/stat")" = "$startup_launcher_ticks" ]; then
      kill "$startup_launcher" 2>/dev/null || true
      sleep .2
      kill -KILL "$startup_launcher" 2>/dev/null || true
    fi
    wait "$startup_launcher" || true
  fi
  exit "$result"
}
startup_launcher=''
startup_launcher_ticks=''
trap revocation_cleanup EXIT
startup_switch() {
  local label=$1 expected=$2 startup_pid startup_window x y
  timeout -s KILL 12 gjs "$OUT/startup-accessibility.js" > "$OUT/$label-accessibility.json" 2> "$OUT/$label-accessibility-error.txt" || fail_case "$label-accessibility"
  jq -e --argjson expected "$expected" '.candidates|length==1 and .[0].checked==$expected and .[0].w>0 and .[0].h>0 and .[0].x>=0 and .[0].y>=0' "$OUT/$label-accessibility.json" > /dev/null || fail_case "$label-switch-state"
  startup_pid=$(jq -r '.candidates[0].pid' "$OUT/$label-accessibility.json")
  startup_window=$(timeout -s KILL 8 xdotool search --onlyvisible --name '^Startup Applications$') || fail_case "$label-startup-window"
  [[ "$startup_window" =~ ^[0-9]+$ ]] || fail_case "$label-multiple-startup-windows"
  timeout -s KILL 8 /home/mint/xres-owner "$startup_window" > "$OUT/$label-startup-xres.txt" 2> "$OUT/$label-startup-xres-error.txt"
  test "$(cat "$OUT/$label-startup-xres.txt")" = "$startup_pid" || fail_case "$label-startup-xres-owner"
  timeout -s KILL 8 cat "/proc/$startup_pid/cmdline" | tr '\0' ' ' > "$OUT/$label-startup-command.txt"
  grep -q cinnamon-settings "$OUT/$label-startup-command.txt" || fail_case "$label-startup-command"
  timeout -s KILL 8 cat "/proc/$startup_pid/stat" > "$OUT/$label-startup-stat.txt"
  timeout -s KILL 8 import -window "$startup_window" "$OUT/$label-startup.png"
  x=$(jq -r '.candidates[0]|(.x+.w/2)|floor' "$OUT/$label-accessibility.json")
  y=$(jq -r '.candidates[0]|(.y+.h/2)|floor' "$OUT/$label-accessibility.json")
  printf '%s %s %s %s\n' "$startup_window" "$startup_pid" "$x" "$y"
}
portal_mark initial-passive
migration_gate initial-prelaunch
launch_settings initial
migration_gate initial
mount_inspection E-stock-before
passive_boundary initial-passive
fresh_on A
mount_inspection E-stock-after-portal-create
permission_read A-before-cinnamon yes
entry_read A-before-cinnamon
portal_mark A-cinnamon
cinnamon-settings startup > "$OUT/A-startup-launch.log" 2>&1 &
startup_launcher=$!
startup_launcher_ticks=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$startup_launcher/stat")
sleep 3
read -r startup_window startup_pid sx sy < <(startup_switch A-before true) || fail_case A-before-startup
start_ui_recording A-cinnamon-off
printf '%s window=%s pid=%s actual_startup_switch_screen=(%s,%s)\n' "$(date -u --iso-8601=ns)" "$startup_window" "$startup_pid" "$sx" "$sy" > "$OUT/A-cinnamon-input.txt"
timeout -s KILL 8 xdotool windowactivate --sync "$startup_window" mousemove "$sx" "$sy" click 1
sleep 2
read -r startup_window_after startup_pid_after _ _ < <(startup_switch A-after false) || fail_case A-after-startup
test "$startup_window" = "$startup_window_after" && test "$startup_pid" = "$startup_pid_after" || fail_case A-startup-replacement
test "$(awk '{sub(/^.*\) /,"");print $20}' "$OUT/A-before-startup-stat.txt")" = "$(awk '{sub(/^.*\) /,"");print $20}' "$OUT/A-after-startup-stat.txt")" || fail_case A-startup-pid-reused
entry_read A-after-cinnamon
test "$(head -n 1 "$OUT/A-after-cinnamon-entry-state.txt")" = DISABLED || fail_case A-cinnamon-did-not-disable-entry
grep -q '^X-GNOME-Autostart-enabled=false$' "$OUT/A-after-cinnamon-entry.desktop" || fail_case A-cinnamon-key-missing
permission_read A-after-cinnamon ''
passive_boundary A-cinnamon
timeout -s KILL 8 xdotool windowactivate "$startup_window" key alt+F4
visible_identity A-live A-original
snapshot A-live
observed_switch_row 'Autostart after login' A-live-ui > "$OUT/A-live-ui.txt" || fail_case A-live-ui
stop_ui_recording
close_reopen A
mount_inspection E-stock-reopened
printf 'A external-OFF live/reopen UI/cache/entry differences are diagnostic outcomes\n' >> "$OUT/verdicts.txt"
# Only A needs actual login; do not replay the previous full passing lifecycle.
visible_identity A-before-login-close ''
portal_mark A-login-close
timeout -s KILL 8 xdotool windowactivate "$wid" key alt+F4
wait_app_exit A-login-close || fail_case A-login-close
passive_boundary A-login-close
wid=''
printf '%s old session monitor retained until LightDM ends session; new monitor begins after relogin\n' "$(date -u --iso-8601=ns)" > "$OUT/A-session-monitor-boundary.txt"
relogin
start_portal_monitor A-login
sleep 3
snapshot A-next-login
timeout -s KILL 8 flatpak ps --columns=instance,application,pid > "$OUT/A-next-login-instances.txt"
awk '$2=="org.localsend.localsend_app"{found=1}END{exit found}' "$OUT/A-next-login-instances.txt" || fail_case A-disabled-entry-launched
permission_read A-next-login ''
portal_mark A-manual-reopen
launch_settings A-after-login
migration_gate A-after-login
passive_boundary A-manual-reopen
fresh_on BC
entry_read B-T0
permission_read B-T0 yes
snapshot B-T0
visible_identity B-T0 BC-original
portal_mark B-revocation
permission_set B-revoke no
entry_read B-T1
permission_read B-T1 no
snapshot B-T1
passive_boundary B-revocation
timeout -s KILL 8 flatpak ps --columns=instance,application,pid > "$OUT/B-T1-instance-check.txt"
if awk '$2=="org.localsend.localsend_app"{found=1}END{exit !found}' "$OUT/B-T1-instance-check.txt"; then
  visible_identity B-T1 BC-original
  observed_switch_row 'Autostart after login' B-T1-ui > "$OUT/B-T1-ui.txt" || fail_case B-T1-ui
  request_click C-hidden 'Start hidden' OFF BC-original
  printf 'C terminal_response=%s; mismatch/cancellation retained without success inference\n' "$RESPONSE_CODE" >> "$OUT/verdicts.txt"
  timeout -s KILL 8 flatpak ps --columns=instance,application,pid > "$OUT/C-post-instance-check.txt"
  if awk '$2=="org.localsend.localsend_app"{found=1}END{exit !found}' "$OUT/C-post-instance-check.txt"; then
    visible_identity C-post BC-original
    observed_switch_row 'Autostart after login' C-post-autostart > "$OUT/C-post-ui.txt" || fail_case C-post-ui
    read -r _ state < "$OUT/C-post-ui.txt"
    if [ "$state" = ON ]; then observed_switch_row 'Start hidden' C-post-hidden >> "$OUT/C-post-ui.txt" || fail_case C-post-hidden-ui; fi
    close_reopen C
  else
    printf 'C original stopped after terminal response; passive reopen unavailable\n' >> "$OUT/verdicts.txt"
    wid=''; portal_mark C-recovery; launch_settings C-recovery; passive_boundary C-recovery
  fi
else
  printf 'B original stopped at T1; C UNPERFORMED (no replacement click)\n' >> "$OUT/verdicts.txt"
  wid=''; portal_mark BC-recovery; launch_settings BC-recovery; passive_boundary BC-recovery
fi
fresh_on D
entry_read D-T0
snapshot D-T0
permission_read D-T0 yes
portal_mark D-revocation
permission_set D-revoke no
entry_read D-T1
permission_read D-T1 no
snapshot D-T1
passive_boundary D-revocation
timeout -s KILL 8 flatpak ps --columns=instance,application,pid > "$OUT/D-T1-instance-check.txt"
if awk '$2=="org.localsend.localsend_app"{found=1}END{exit !found}' "$OUT/D-T1-instance-check.txt"; then
  visible_identity D-T1 D-original
  observed_switch_row 'Autostart after login' D-T1-ui > "$OUT/D-T1-ui.txt" || fail_case D-T1-ui
  request_click D-disable 'Autostart after login' ON D-original
  printf 'D terminal_response=%s; cancellation is not confirmed OFF; full pre/post entry retained\n' "$RESPONSE_CODE" >> "$OUT/verdicts.txt"
  timeout -s KILL 8 flatpak ps --columns=instance,application,pid > "$OUT/D-post-instance-check.txt"
  if awk '$2=="org.localsend.localsend_app"{found=1}END{exit !found}' "$OUT/D-post-instance-check.txt"; then
    visible_identity D-post D-original
    observed_switch_row 'Autostart after login' D-post-autostart > "$OUT/D-post-ui.txt" || fail_case D-post-ui
    close_reopen D
  else
    printf 'D original stopped after terminal response; passive reopen unavailable\n' >> "$OUT/verdicts.txt"
    wid=''; portal_mark D-recovery; launch_settings D-recovery; passive_boundary D-recovery
  fi
else
  printf 'D original stopped at T1; disable UNPERFORMED (no replacement click)\n' >> "$OUT/verdicts.txt"
  wid=''; portal_mark D-recovery; launch_settings D-recovery; passive_boundary D-recovery
fi
# Restore only this app through observed UI operations, not preferences or files.
permission_set cleanup yes
row=$(observed_switch_row 'Autostart after login' cleanup-ui) || fail_case cleanup-ui
read -r _ state <<< "$row"
if [ "$state" = ON ]; then accepted_transition cleanup-off 'Autostart after login' ON OFF host-absent; fi
entry_read cleanup-off
test "$(head -n 1 "$OUT/cleanup-off-entry-state.txt")" = ABSENT || fail_case cleanup-entry-not-absent
require_switch_state 'Autostart after login' cleanup-off-ui OFF > /dev/null || fail_case cleanup-off-ui
visible_identity cleanup-close ''
portal_mark cleanup-close
timeout -s KILL 8 xdotool windowactivate "$wid" key alt+F4
wait_app_exit cleanup-close || fail_case cleanup-close
passive_boundary cleanup-close
test "$request_pending" = 0
stop_portal_monitor
printf 'A–D bounded revocation diagnostic completed; E stock read-only mapping only. Shipping, repetition and reboot remain unvalidated.\n' > "$OUT/result.txt"
