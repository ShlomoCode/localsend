#!/usr/bin/env bash
set -Eeuo pipefail

out=/evidence/native-probe
host_cache="$HOME/.cache/fontconfig"
app_cache="$HOME/.var/app/org.localsend.localsend_app/cache/fontconfig"
mkdir -p "$out"

case_fc_list() {
  local label="$1" status=0
  rm -rf "$app_cache"
  timeout 12s flatpak run --user --command=fc-list org.localsend.localsend_app : family \
    > "$out/$label.txt" 2>&1 || status=$?
  printf '%s\t%s\t%s\n' "$label" "$status" "$(wc -l < "$out/$label.txt")" >> "$out/summary.tsv"
}

printf 'case\texit_code\toutput_lines\n' > "$out/summary.tsv"
rm -rf "$host_cache"
mkdir -p "$host_cache"
tar -xzf /evidence/cache-snapshots/brave-1.99.20.tar.gz -C "$host_cache"
case_fc_list brave_cache
rm -rf "$host_cache"
mkdir -p "$host_cache"
case_fc_list empty_cache

# Re-run the released app with the captured host cache and record a bounded
# sample of fontconfig getters from its live main thread.
rm -rf "$host_cache" "$app_cache"
mkdir -p "$host_cache"
tar -xzf /evidence/cache-snapshots/brave-1.99.20.tar.gz -C "$host_cache"
export DISPLAY=:98
Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp > "$out/xvfb.log" 2>&1 &
xvfb_pid=$!
openbox > "$out/openbox.log" 2>&1 &
openbox_pid=$!
app_group=""
cleanup() {
  if [[ -n "$app_group" ]]; then
    kill -TERM -- "-$app_group" 2>/dev/null || true
    kill -KILL -- "-$app_group" 2>/dev/null || true
  fi
  kill "$openbox_pid" "$xvfb_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 3
setsid flatpak run --user org.localsend.localsend_app > "$out/flatpak.stdout.txt" 2> "$out/flatpak.stderr.txt" &
app_group=$!
app_pid=""
for ((i=0; i<20; i++)); do
  for candidate in $(pgrep -x 'localsend(_app)?' 2>/dev/null || true); do
    executable=$(sudo readlink "/proc/$candidate/exe" 2>/dev/null || true)
    if [[ "$executable" == */localsend_app || "$executable" == */localsend ]]; then
      app_pid=$candidate
      break
    fi
  done
  [[ -n "$app_pid" ]] && break
  sleep 1
done
test -n "$app_pid"
printf '%s\n' "$app_pid" > "$out/localsend.pid"
sleep 4
sudo awk '{print $14, $15}' "/proc/$app_pid/task/$app_pid/stat" > "$out/main-thread-cpu-before.txt"
cat > "$out/trace.gdb" <<GDB
set debuginfod enabled off
set pagination off
set confirm off
set print thread-events off
set logging file $out/getters.txt
set logging enabled on
attach $app_pid
set \$str_count = 0
set \$char_count = 0
break FcPatternGetString
commands
  silent
  set \$str_count = \$str_count + 1
  printf "STRING call=%d object=%s index=%d caller=%p\\n", \$str_count, (char *)\$rsi, \$edx, *(void **)\$rsp
  if \$str_count == 1
    bt 8
  end
  if \$str_count >= 60
    quit
  end
  continue
end
break *(FcPatternGetString+0x74)
commands
  silent
  printf "STRING return object=%s index=%d result=%d caller=%p\\n", (char *)\$rbx, \$r14d, \$eax, *(void **)(\$rbp+8)
  continue
end
break FcPatternGetCharSet
commands
  silent
  set \$char_count = \$char_count + 1
  printf "CHARSET call=%d object=%s index=%d caller=%p\\n", \$char_count, (char *)\$rsi, \$edx, *(void **)\$rsp
  if \$char_count == 1
    bt 8
  end
  if \$char_count >= 60
    quit
  end
  continue
end
break *(FcPatternGetCharSet+0x74)
commands
  silent
  printf "CHARSET return object=%s index=%d result=%d caller=%p\\n", (char *)\$rbx, \$r14d, \$eax, *(void **)(\$rbp+8)
  continue
end
continue
GDB
sudo timeout 25s gdb -q -batch -x "$out/trace.gdb" > "$out/gdb.stdout.txt" 2>&1 || true
sudo cat "/proc/$app_pid/maps" > "$out/maps.txt" 2>&1 || true
sudo awk '{print $14, $15}' "/proc/$app_pid/task/$app_pid/stat" > "$out/main-thread-cpu-after.txt" 2>/dev/null || true
