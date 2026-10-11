# Recorder cleanup status failure

The guest shell aborts while expanding `status` in its line 28, before it reaches the recorder stop and wait commands. All three retained scenario logs show the Python Folder-label failure followed by `bash: line 28: status: unbound variable`. This is a diagnostic infrastructure failure, separate from the Folder OCR failure.

## Immutable script and Bash semantics

`7820cfdc-mint-vm.sh` and `7820cfdc-ui.py` retain the exact scripts from the run revision. The Mint scenario is supplied to `ssh ... bash -s` through a here-document. Its guest line 1 enables `set -euo pipefail`; line 6 and line 15 disable only `errexit` with `set +e`. `nounset` remains enabled.

Guest line 18 invokes the Python driver. Line 19 is `status=$?`, which would define `status` whether Python succeeds or fails. Line 28 expands `status` in the status-file printf. Lines 29–32 stop and wait for the recorder and write its exit status. A normal nonzero Python return cannot by itself explain an undefined variable after line 19. Initializing a default status would hide the missing assignment rather than establish the intended Python exit code.

## Source-backed command-stream consumption

The Python helper calls `subprocess.run(..., capture_output=True)` without isolating stdin. That helper's crop command invokes FFmpeg without `-nostdin`. It therefore inherits the stdin carrying the guest shell's remaining commands. By contrast, the original long-running recorder explicitly has `-nostdin`, and the app/settings children use `DEVNULL`.

The guest records FFmpeg `6.1.1-3ubuntu5`. The retained official 6.1.1 source initializes `stdin_interaction = 1` in `ffmpeg_opt.c` line 85. In `ffmpeg.c`, `read_key` at lines 290–307 checks descriptor 0 with `select` and reads one byte when ready, without requiring a terminal. The transcode loop at lines 1184–1189 calls keyboard handling when stdin interaction is enabled. Thus the new crop operation can consume bytes from the streamed shell script even though its media input is a PNG file.

This explains how the status assignment can be corrupted before Bash resumes. In particular, consuming its leading `s` would turn `status=$?` into a different, valid assignment while preserving line numbering; the later line 28 would then report precisely the observed undefined `status`. No input-byte trace was retained, so this exact byte sequence is an explanation consistent with the source and logs, not a separately observed trace.

The responsible correction is to isolate the diagnostic driver's stdin from the streamed shell script, and disable FFmpeg interaction for noninteractive crops. Keep an explicit, actual Python exit-code assignment. Validate recorder stop, wait, status files, and evidence retention in the next cloud failure path. This audit did not edit the scripts or perform a local reproduction.

## Preserved evidence and limits

The three scenario logs, exact run scripts, and official FFmpeg source files are retained here. Source retrieval URLs are recorded separately in the private provenance file. The official release source confirms the relevant stdin behavior; this audit does not claim a byte-for-byte Ubuntu source-package comparison or an executed causal reproduction. No app, build, test, VM, or workflow was launched.
