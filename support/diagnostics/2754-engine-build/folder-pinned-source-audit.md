# Pinned Folder chooser source audit

Raw archive, extracted sources, hashes, app caller/lock copies and comparisons are retained at `/tmp/2754-folder-source-audit`. Relative evidence paths below refer to that retained audit directory. Retrieval URLs remain in its private provenance file.

The pinned Linux Folder workflow requests a native chooser titled **Choose Directory**, with **Open** and **Cancel** buttons. Requiring **Select** or a **Select Folder** title rejects this source-supported default. This is source evidence; it does not establish that the runtime chooser opened, cancellation succeeded, or the product bug is fixed.

## Immutable dependency provenance

- App revision: `c1ce322fb3acf08e44f329b8b7208b8b0d91e244`.
- The revision's root lockfile pins `file_selector_linux` version `0.9.4`.
- Retrieved package archive: `file_selector_linux-0.9.4.tar.gz` in the retained audit directory.
- Entire archive SHA-256: `2567f398e06ac72dcf2e98a0c95df2a9edd03c2c2e0cacd4780f20cdf56263a0`, exactly matching the pinned lockfile.
- Extracted source: `source/linux/file_selector_plugin.cc` and `source/lib/file_selector_linux.dart`.
- Both extracted files are byte-identical to the corresponding local package-cache files. `cache-comparison.txt` records the successful comparisons; `SHA256SUMS` preserves archive and source-file hashes.
- `pinned-pubspec.lock`, `pinned-pick_directory_path.dart`, and `pinned-file_picker.dart` retain the app source used for this assessment.

## Source chain

The pinned app's Folder action calls `pickDirectoryPath()` without arguments. On Linux, that helper calls `file_selector.getDirectoryPath()` without a `confirmButtonText` override. The `file_selector_linux` Dart implementation forwards the nullable confirmation label through `getDirectoryPathWithOptions` as `acceptButtonLabel`.

In the verified package's C++ source, `create_dialog_of_type` handles `CHOOSE_DIRECTORY` at lines 114–116 by selecting `GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER`, title `Choose Directory`, and default accept label `_Open`. `create_dialog` at lines 53–61 uses that default when the supplied label is null and sets the cancel label to `_Cancel`. GTK mnemonic underscores produce the visible Open and Cancel labels in the in-process native dialog.

The enum describing folder selection does not specify a visible Select button. The visible button label comes from the explicit `_Open` argument. The app's Linux path uses file_selector; its file_picker directory path is for Android/iOS and does not determine this chooser.

## Limits

The next runtime Folder frames must establish the actual title, labels, process ownership, cancellation, and return to the app. A portal could substitute another interface; the current diagnostic's same-app-PID gate intentionally excludes an unproven portal process. No confidence threshold or generic label acceptance was relaxed during this audit.

Only source retrieval, archive extraction, hashing, comparisons, and source inspection were performed. No app, build, test, VM, or workflow was launched. Retrieval URLs are retained separately in the private provenance file and are excluded from this report.
