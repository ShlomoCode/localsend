# Independent Folder diagnostic correction review

No source blocker was found in the reviewed correction. This is a read-only source and retained-evidence assessment, not a runtime validation or a product-fix verdict.

## Reviewed source identity

- `/tmp/localsend-bug-2754/support/diagnostics/2754-ui.py`
  - SHA-256: `853cd79568957cb62bb3100de7660ca3e9a798616ea407e19f42d4552aac6f98`
- `/tmp/localsend-bug-2754/support/diagnostics/2754-mint-vm.sh`
  - SHA-256: `95b8c8b320dc279682494ab6a8a8c6b12defc1dd340b4c1b2c392dcc36d7782b`

These hashes identify the source reviewed. Later file changes require a separate review of the changed parts.

## Findings

The new opener handling runs only for Folder. It requires the focused LocalSend window to belong to the original app PID and requires one exact Selection heading. It uses that heading from the same saved PNG to anchor both its modal guard and its Folder fallback. PNG dimensions, crop bounds, FFmpeg exit status, and Tesseract exit status are checked. The scaled Folder label must be unique, exact, and have confidence at least 90. Click coordinates divide the OCR coordinates by three before adding the crop origin. The synthetic zero-size row passed to the existing click mechanics preserves that computed point.

The three retained positive picker TSVs each contain one Folder word at confidence `95.629387`, with scaled box `450,135,123,33`. Their crop and coordinate transform match the source. The three retained MessageInputDialog negative guard TSVs each contain exact Type and message; the source rejects them. The positive guard TSVs contain neither word. The guard checks the same saved image rather than a second screenshot. Exact Folder text alone would accept the dimmed background in those modal negatives, so retaining this guard is necessary.

The native Folder title and action have been corrected to Choose Directory and Open, as supported by the immutable file_selector_linux version 0.9.4 archive verified in `/tmp/2754-folder-source-audit/AUDIT.md`. That audit preserves the archive hash matching the pinned lockfile and byte comparisons with the inspected package-cache source.

FFmpeg crop invocations now include `-nostdin`, and the Mint shell redirects the UI driver's stdin from `/dev/null`. This isolates the subprocesses from the shell's streamed command input. The explicit `status=$?` assignment remains. The earlier failure mechanism and its evidence limits are recorded in `/tmp/2754-shell-status-audit/AUDIT.md`.

The existing Text recognition branch and timed Text cases are unchanged by the Folder correction. No native AT-SPI observer has been inserted before the timing cases.

## Retained evidence inspected

The original positive frames and same-frame modal negatives are in the retained run directory:

| Variant | Original Folder positive PNG | Original modal-negative PNG |
|---|---|---|
| control-system | `/tmp/2754-packaged-38173103833-compact/comparison/control-system/guest/keyboard-on-folder-control-before.png` | `/tmp/2754-packaged-38173103833-compact/comparison/control-system/guest/keyboard-on-65.png` |
| B-system | `/tmp/2754-packaged-38173103833-compact/comparison/B-system/guest/keyboard-on-folder-control-before.png` | `/tmp/2754-packaged-38173103833-compact/comparison/B-system/guest/keyboard-on-65.png` |
| AB-package | `/tmp/2754-packaged-38173103833-compact/comparison/AB-package/guest/keyboard-on-folder-control-before.png` | `/tmp/2754-packaged-38173103833-compact/comparison/AB-package/guest/keyboard-on-65.png` |

The derived PNG/TSV evidence and methodology are retained in `/tmp/2754-folder-retained-frame-audit`. Directly read evidence includes:

- `control-system-picker.tsv`, `B-system-picker.tsv`, and `AB-package-picker.tsv`.
- `control-system-modal-gate.tsv`, `B-system-modal-gate.tsv`, and `AB-package-modal-gate.tsv`.
- `control-system-positive-gate.tsv`, `B-system-positive-gate.tsv`, and `AB-package-positive-gate.tsv`.

Each TSV has a corresponding PNG with the same stem. The modal picker negative images/TSVs that demonstrate readable dimmed Folder labels have the stems `control-system-negative-modal-correct`, `B-system-negative-modal-correct`, and `AB-package-negative-modal-correct`. The audit also preserves adjacent and chooser negatives, which are useful bounds on the fallback's scope.

## Limits and required runtime evidence

- The modal guard covers the specific retained MessageInputDialog geometry. It is not a general detector for arbitrary dialogs or layouts.
- Host-derived OCR verifies the retained frames only. Guest OCR with its installed version must still pass the exact gates.
- No Folder chooser was opened in the retained failed run. A subsequent cloud run must show actual Folder opening, native Choose Directory/Open/Cancel, cancellation, chooser disappearance, focus return to the app, and Selection.
- The source-supported native default does not validate a portal interface. The same-app-PID guard excludes an unproven portal process.
- The corrected stdin handling requires cloud failure-path evidence that the actual Python status is retained and the recorder is stopped, waited for, and reports its exit status. Prior input-byte consumption was not traced; the specific consumed bytes remain inferred.
- This review makes no conclusion about correction of the original Text timing bug or about speech/audio delivery.

No clone files were edited or reverted. Only source, Git state, retained reports, and TSVs were read, and this review record was written. No app, build, test, VM, workflow, or local reproduction was executed. Retrieval URLs are not included in this report.
