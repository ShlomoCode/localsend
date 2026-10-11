# Draft input observations in run 38133441018

The 5000-file case contains a real partial rendered draft after `xdotool type` exited. The five-file control contains the full draft in its first retained frame; its later OCR match is caused by the visible caret being read as `|`. These are different observations. Neither establishes a deterministic per-character defect or an OOM.

All times below use the guest monotonic clock. A capture interval is the beginning and end of the `scrot` command. The precise instant when pixels were read lies within that interval. Timings are bounds on retained observations, not isolated paint latency.

| Case | Type process interval | Type duration | Draft frame | Capture interval after type start | Capture interval after type exit | Visible field |
| --- | --- | --- | --- | --- | --- | --- |
| 5 | 102.390193–102.677769 | 0.287576 s | 0 | 0.580826–0.632262 s | 0.293250–0.344687 s | Probe2414.txt, caret visible |
| 5 | same | same | 1 | 3.658608–3.718516 s | 3.371033–3.430940 s | Probe2414.txt, caret visible |
| 5 | same | same | 2 | 6.783032–6.837892 s | 6.495456–6.550317 s | Probe2414.txt, caret visible |
| 5 | same | same | 3 | 9.934110–9.986174 s | 9.646534–9.698598 s | Probe2414.txt, caret absent |
| 5000 | 184.563359–184.836731 | 0.273371 s | 0 | 0.624560–0.685761 s | 0.351188–0.412390 s | P, caret visible |
| 5000 | same | same | 1 | 4.569177–4.630444 s | 4.295806–4.357073 s | Probe2414.txt, caret absent |

The retained input logs contain one Ctrl+A and one `xdotool type --clearmodifiers --delay 40 Probe2414.txt` per case, followed by screenshot commands. They contain command entry times, not individual key-event emission or application receipt times. The input process timings come from the driver response stored in each interaction result. There is no further text input between the two 5000-file draft frames.

## What the frames prove

For five files, complete text was visible by 0.632262 seconds after type start, or 0.344687 seconds after type exit. Frames 0–2 have `Probe2414.txt|` in their field-band OCR. Frame 3 has `Probe2414.txt` and is accepted by the exact-token predicate. The 9.986174-second matching screenshot and 12.824335-second overall assertion therefore measure detection delay, not completion of typing.

For 5000 files, frame 0 visibly contains only `P`. Its field OCR has zero-confidence garbage, but manual inspection of the original pixels establishes the partial text independently of OCR. Some captured incomplete state exists at least 0.351188 seconds after the type process exited. Frame 1 visibly contains the full draft, bounding complete visibility by 4.630444 seconds after type start, or 4.357073 seconds after process exit.

With normal progression from partial to full text, conservative completion bounds are greater than 0.624560 and at most 4.630444 seconds after type start. The lower bound uses the first capture's start, since the exact pixel-read instant is unknown. There are no intermediate frames. Full text may have appeared shortly after frame 0; serial image transfer/OCR delayed the next sample. Conversely, real input handling or rendering delay remains possible. Assigning the entire 4.630444 seconds to either application latency or OCR would exceed the evidence.

The result demonstrates that process exit is not a synchronous guarantee of full text on the screen. It does not distinguish X11 delivery/queueing, application event processing, controller changes, rendering or guest scheduling. It also does not establish a latency for each character: twelve displayed characters are not twelve observed processing events.

## Historical callback and validation

Read-only inspection of v1.17.0 `app/lib/widget/dialogs/file_name_input_dialog.dart` shows `autofocus: true`, a local `TextEditingController`, and `onChanged: (value) => _validate(value.trim())`. Each change checks emptiness and `isValidFilename`. The valid path with no existing error does not call dialog `setState`; invalid/empty input or clearing a previous error does. There is no selected-file traversal in this callback.

The historical lock pins `legalize` 1.2.2 with package hash `bc3068aa4f14588575c8b5ba2a9e608c242dad325e7f7c56fedd68adba33526a`. The available local package cache has that version and matching recorded package hash. Its Linux `isValidFilename` branch checks only the supplied string: length, slash, null character and `.`/`..`. It has no access to the 5000-file selection. This is source inspection, not instrumentation of the released binary.

The historical Receive Options page calls `selectedReceivingFilesProvider.rename` only after the dialog returns a non-null result. That provider copies its file map during rename, but ordinary typing does not call rename, and Cancel returns null. Thus there is no demonstrated 5000-entry traversal per keypress in these LocalSend callbacks. Flutter form/controller processing, the underlying eager Options widget tree, graphics and scheduling remain unmeasured possibilities.

## Narrow next experiment

Keep the same guest, desktop, files, release, draft and Cancel verification. Compare the existing typed sequence with a normal X clipboard paste of the same draft using Ctrl+V, three repetitions per mode for five files and 5000 files. Observe frame bursts during input without running OCR or SCP between captures; copy and classify the batch after the burst. Both modes need identical sampling to expose observer overhead.

Retain command entry/exit times, frame capture start/end, RSS/PSS/available memory and every receiver task's `/proc` stat and comm. A task identifier alone is not proof that a thread is the Flutter main thread. Command logs are not individual received key events; capture the actual X event sequence with a compatible observer if available, and state its scope. Clipboard paste changes the input path and number of editing events, so a difference can discriminate input amplification but cannot alone identify the responsible layer or justify a production fix.

## Evidence paths

`checkpoint/files-{5,5000}-options-interactions.json` contains input and assertion timings. Each `files-COUNT-editor-draft-N.png`, corresponding `-timing.json`, and `-dialog-absolute-words.json` establishes the retained frame and OCR. Guest command logs are in `checkpoint/vm/checkpoint-guest/files-COUNT-input.jsonl`. Exact numeric deltas are retained in `input-analysis.json` beside this file.
