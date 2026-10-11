# Run the post-geometry accessibility follow-up

These fixtures exercise the real LocalSend Text dialog through public AT-SPI 2.52 APIs. Run them only in the staged Mint cloud guest, after the original timing controls and strict geometry capture finish. They leave those controls and the geometry validator unchanged. The driver owns integration and must preserve their original results separately.

The harness tests editing, accessible button actions, dialog removal/reopening, and app exit/restart. It starts real installed Orca with the Speech Dispatcher backend and retains original speech logs. Speech and audio remain `unknown` until the raw evidence is reviewed. A successful API sequence or an Orca utterance request does not establish audible delivery.

## Integration contract

Install the same prerequisites for each comparison variant before the follow-up: `build-essential`, `pkg-config`, `libatspi2.0-dev`, `libglib2.0-dev`, `jq`, `xdotool`, `orca`, `python3-speechd`, `speech-dispatcher`, and `speech-dispatcher-espeak-ng`. `pactl` from `pulseaudio-utils`, an active compatible user-session audio server, and `ffmpeg` allow optional real output recording. Retain package versions and any installation differences. Do not introduce another libatk/libatspi version for this phase.

Use the existing Cinnamon session environment. After geometry restores the window position, open a fresh **Text** dialog and verify its rendered **Type message** title. Then invoke:

```bash
PROBE_CLOUD_INTERACTIONS=1 timeout --kill-after=60s 1200s \
  bash /home/mint/support/diagnostics/2754-accessibility/capture-interactions.sh \
  APP_PID WINDOW_ID /home/mint/evidence/interactions-post-geometry \
  /home/mint/support/diagnostics/2754-bridge-app
```

Replace `APP_PID` and `WINDOW_ID` with the verified original process and window IDs. The normal launcher must already exist and have passed the bridge and source-built engine loader gates. This harness is for the source-built control/B/package comparisons; it requires engine loader gates on restart.

The harness gracefully terminates the supplied, identity-checked PID, verifies its absence from the live AT-SPI desktop tree, and starts the normal launcher again. It writes `restarted-app-pid.txt`, `restarted-app-starttime.txt`, `restarted-app-cmdline.bin`, `restarted-app-exe.txt`, and `pid-transitions.txt`. The driver must read that new PID and identity for any later cleanup or inspection. Startup 1 loader evidence is copied before restart. Startup 2 requires gate files newer than the restart boundary and containing the new PID; its evidence is copied separately. The pinned app starts on Receive. The harness activates its verified window, requires exactly one rendered **Send** OCR word, clicks its observed center, and captures Selection before requiring a fresh closed tree with the **Text** opener. The restarted app remains running when the harness returns. The driver or owned VM cleanup remains responsible for it.

Every mode invocation produces raw JSONL, stderr, start time, exit status, and deadline status. The per-client process deadline is 90 seconds. A transition uses at most ten fresh probes, each bounded separately; the outer 1200-second deadline bounds the complete phase. Preserve the entire output directory on every outcome. `result.json` records process completion separately from speech/audio review.

## API and UI gates

The client clears each queried node's cache and traverses at most 160 nodes and fourteen ancestor levels. It records query entry, identity, arguments, elapsed time, result, and full `GError` for APIs exposing one. `GetStateSet` exposes no error output; missing or defunct states remain visible and exclude a target. A live child must report the expected parent and index. Truncation, repeated identities, missing advertised children, ambiguous targets, and API errors fail the mode.

The implemented sequence requires:

1. Exactly one visible, showing, non-defunct, focused field with both Text and EditableText interfaces in the verified app.
2. Successful `set_text_contents`, insertion, deletion, caret, and selection operations, followed by exact independent readback. Flutter replies after dispatching these actions; semantics buffers can update later. Each mutation has a five-second polling deadline for text/count, caret, or selection convergence. The client logs every read and bounds each public call by the remaining deadline, aborting on `GError`. The ASCII nonce avoids ambiguity between byte lengths and character offsets. Editing restores the original field contents; `speech-text` deliberately leaves the nonce for Orca to present.
3. Exactly one visible **Cancel** button with exactly one advertised `Tap`, `click`, `press`, or `activate` action. `Tap` is the pinned Flutter engine's public action name. The selected index comes from the live action enumeration. After invocation, a fresh tree must contain no dialog title or visible editable field and exactly one actionable **Text** opener.
4. A live **Text** action that reopens a dialog with one focused editable field. Reopening repeats editing and cancellation. Object paths may be reused; validity comes from fresh tree relationships and observed UI transitions.
5. Actual app process exit and removal of its PID from desktop discovery. Restart must produce a new process, fresh loader verification, a valid closed tree, and another open/edit/cancel cycle.

The harness retains a full screenshot, visible window ID/PID, window name, and optional raw OCR after each modal transition and after restart. Its window PID must match the tested process. API/tree postconditions establish accessible state; review the screenshots/OCR for the rendered **Type message** or **Selection** labels. OCR is raw evidence and does not replace the strict tree checks.

`interaction-client PID MODE LABEL` exposes `snapshot`, `edit`, `speech-text`, `cancel`, `open`, `closed`, `absent`, and `events` modes for additional driver coordination. `snapshot` requires an open focused dialog. `closed` requires the modal to be absent and the **Text** opener present. `absent` requires the old PID to be absent from desktop enumeration. `events` listens for at most 1200 seconds; the harness stops it and checks it remains alive through app removal. It scopes focus/text/window events to the selected app and records global child changes because application removal originates from the registry. Events preserve source identities and accessible child payload identities for correlation by app bus name and object path; global events from another app are not evidence about LocalSend. The outer timeout allows sixty seconds for the independently bounded child cleanup.

## Speech evidence

The harness uses Orca's supported `--enable=speech`, `--speech-system=speechdispatcherfactory`, `--debug`, and `--debug-file` options. It retains the installed version/help output and rejects an existing Orca process instead of replacing it. It starts a real user Speech Dispatcher daemon only when one is absent. It neither uses `spd-say` nor invokes Orca speech functions from the fixture. Cleanup signals the owned child PIDs only while their recorded process start times still match, waits at most five seconds before escalation and five seconds afterward, and reaps exited children. A daemon started by the harness is recorded separately.

After the API sets the nonce, the harness uses real Tab, Shift+Tab, and Ctrl+A input in the app window. Review the original Orca debug log alongside the UI-input times and raw AT-SPI events. Require the nonce to occur in a real speech presentation associated with the verified app's focused field, and require a functioning backend without connection/send errors. The extracted `orca-utterance-requests.txt` is an index into original evidence. Orca logs `SPEECH DISPATCHER: Speaking ...` before sending to the backend; that entry alone remains `unknown`.

QEMU needs no physical audio device for a real user-session PulseAudio null sink. When a compatible audio server is already available, the harness creates a sink, records its monitor with ffmpeg, and selects it as the default during Orca presentation. It retains sink/source/stream metadata, the original default sink, the unmodified WAV, and recorder logs. Cleanup restores the original sink and unloads the temporary module; either failure is recorded in `cleanup-status.txt` and fails the harness. No fixture synthesizes the nonce or writes speech samples. Existing output streams may retain their original routing, so inspect stream metadata and the recording; a nonempty WAV, silence, or successful recorder exit does not establish correct speech. Without a compatible audio server, retain real Orca logs and mark audio `unknown`.

A speech pass requires review of app-correlated real Orca output and backend evidence, or a recording containing the expected real Orca presentation. Report audible delivery only when the recording supports it. Report editing, actions, dialog lifecycle, app lifecycle, original geometry, and speech as separate results.

The source was prepared against the official AT-SPI 2.52.0 public headers and Orca 46.1 command/backend source. Local compilation, syntax checks, tests, and app execution were intentionally not performed; the cloud guest must compile and execute the retained source and report its raw results.
