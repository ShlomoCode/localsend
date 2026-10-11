#!/usr/bin/env bash
# Reuse only the emulator already spawned by this job; do not launch a second one.
set -euo pipefail
mkdir -p evidence-cloud
mapfile -t ISSUE_BOOT_PIDS < <(sed -n 's/.*PID: \([0-9][0-9]*\), log:.*/\1/p' evidence-cloud/emulator-launch.log | sort -u)
if [ "${#ISSUE_BOOT_PIDS[@]}" != 1 ]; then
  echo 'Launch log has no unique owned emulator PID' >> evidence-cloud/boot-readiness.txt
  exit 1
fi
ISSUE_BOOT_PID="${ISSUE_BOOT_PIDS[0]}"
ISSUE_BOOT_DEADLINE=$((SECONDS + 180))
ISSUE_BOOT_ATTEMPT=0
ISSUE_BOOT_STABLE=0
while (( SECONDS < ISSUE_BOOT_DEADLINE )); do
  if ! kill -0 "$ISSUE_BOOT_PID"; then
    echo "Owned emulator PID $ISSUE_BOOT_PID died" >> evidence-cloud/boot-readiness.txt
    exit 1
  fi
  ISSUE_BOOT_REMAINING=$((ISSUE_BOOT_DEADLINE - SECONDS))
  (( ISSUE_BOOT_REMAINING > 0 )) || break
  ISSUE_BOOT_BOUND=$((ISSUE_BOOT_REMAINING < 10 ? ISSUE_BOOT_REMAINING : 10))
  if (( ISSUE_BOOT_ATTEMPT % 10 == 0 )); then
    if timeout "$ISSUE_BOOT_BOUND" adb reconnect offline > "evidence-cloud/boot-reconnect-$ISSUE_BOOT_ATTEMPT.txt" 2>&1; then
      ISSUE_BOOT_RECONNECT_STATUS=0
    else
      ISSUE_BOOT_RECONNECT_STATUS=$?
    fi
    echo "attempt=$ISSUE_BOOT_ATTEMPT reconnectStatus=$ISSUE_BOOT_RECONNECT_STATUS" >> evidence-cloud/boot-readiness.txt
  fi
  ISSUE_BOOT_REMAINING=$((ISSUE_BOOT_DEADLINE - SECONDS))
  (( ISSUE_BOOT_REMAINING > 0 )) || break
  ISSUE_BOOT_BOUND=$((ISSUE_BOOT_REMAINING < 10 ? ISSUE_BOOT_REMAINING : 10))
  if ISSUE_BOOT_STATE=$(timeout "$ISSUE_BOOT_BOUND" adb -s emulator-5554 get-state 2> "evidence-cloud/boot-state-$ISSUE_BOOT_ATTEMPT-stderr.txt"); then
    ISSUE_BOOT_STATE_STATUS=0
  else
    ISSUE_BOOT_STATE_STATUS=$?
  fi
  printf 'attempt=%s stateStatus=%s state=%q\n' "$ISSUE_BOOT_ATTEMPT" "$ISSUE_BOOT_STATE_STATUS" "$ISSUE_BOOT_STATE" >> evidence-cloud/boot-readiness.txt
  ISSUE_BOOT_REMAINING=$((ISSUE_BOOT_DEADLINE - SECONDS))
  (( ISSUE_BOOT_REMAINING > 0 )) || break
  ISSUE_BOOT_BOUND=$((ISSUE_BOOT_REMAINING < 10 ? ISSUE_BOOT_REMAINING : 10))
  if ISSUE_BOOT_VALUE=$(timeout "$ISSUE_BOOT_BOUND" adb -s emulator-5554 shell getprop sys.boot_completed 2> "evidence-cloud/boot-property-$ISSUE_BOOT_ATTEMPT-stderr.txt"); then
    ISSUE_BOOT_PROPERTY_STATUS=0
  else
    ISSUE_BOOT_PROPERTY_STATUS=$?
  fi
  ISSUE_BOOT_VALUE=${ISSUE_BOOT_VALUE//$'\r'/}
  printf 'attempt=%s stateStatus=%s state=%q propertyStatus=%s boot=%q\n' "$ISSUE_BOOT_ATTEMPT" "$ISSUE_BOOT_STATE_STATUS" "$ISSUE_BOOT_STATE" "$ISSUE_BOOT_PROPERTY_STATUS" "$ISSUE_BOOT_VALUE" >> evidence-cloud/boot-readiness.txt
  (( SECONDS < ISSUE_BOOT_DEADLINE )) || break
  if [ "$ISSUE_BOOT_STATE_STATUS" = 0 ] && [ "$ISSUE_BOOT_PROPERTY_STATUS" = 0 ] && [ "$ISSUE_BOOT_STATE" = device ] && [ "$ISSUE_BOOT_VALUE" = 1 ]; then
    ISSUE_BOOT_STABLE=$((ISSUE_BOOT_STABLE + 1))
    if [ "$ISSUE_BOOT_STABLE" = 2 ]; then
      kill -0 "$ISSUE_BOOT_PID"
      echo "readyPid=$ISSUE_BOOT_PID" >> evidence-cloud/boot-readiness.txt
      exit 0
    fi
  else
    ISSUE_BOOT_STABLE=0
  fi
  ISSUE_BOOT_ATTEMPT=$((ISSUE_BOOT_ATTEMPT + 1))
  ISSUE_BOOT_REMAINING=$((ISSUE_BOOT_DEADLINE - SECONDS))
  (( ISSUE_BOOT_REMAINING > 0 )) || break
  sleep "$((ISSUE_BOOT_REMAINING < 2 ? ISSUE_BOOT_REMAINING : 2))"
done
echo 'Owned emulator did not reach stable online/boot readiness before the deadline' >> evidence-cloud/boot-readiness.txt
exit 1
