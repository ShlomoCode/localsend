# Capture issue 2955 on an official release

This diagnostic workflow prepares five finite transfers between the official LocalSend v1.17.0 Linux x86-64 sender and Android x64 receiver. It does not build or modify LocalSend. Source preparation has not established runtime compatibility or reproduced the report.

The receiver uses stock Android 16 API 36 x86_64. This differs from the reported Samsung S22, OneUI 8, and ARM64. The reporter did not identify their exact LocalSend version, sender, installer, Quick Save state, orientation, or font scale. v1.17.0 was the latest published release before the report date. The chosen sender and emulator cannot establish Samsung-specific behavior.

The workflow uses one job with a 60-minute limit and a 35-minute application step. The runner stops earlier if release assets, ABI, native accessibility, UI controls, forwarding, completion, or saved-file verification fails. Missing or ambiguous native controls stop the diagnostic; the harness does not guess coordinates. Android taps use bounds from the currently visible semantic tree. Linux actions use native AT-SPI controls. Settings are changed only through visible application UI. Native file selection uses the GTK file chooser and its keyboard location command.

## Native readiness and chooser focus

ADB must report **device** for the exact receiver serial through `get-state` within 120 seconds. The boot property must then explicitly report `sys.boot_completed=1` within 240 seconds. Every probe retains stdout, stderr, exit code, and timestamp. Only known not-ready values and four exact transient messages retry: device not found for the selected serial, device offline, no devices/emulators found, and closed. Each message may have the native `error:` or `adb:` prefix. Unknown failures and command timeouts stop the diagnostic; `failure.json` retains native command details.

Openbox starts inside the existing D-Bus session before the Linux application. To focus the picker, the harness observes the native **Open File** chooser ancestor through AT-SPI, retains the sender's actual process PID, and requires one visible X11 window matching both that PID and the observed title. Openbox activates that window through `xdotool windowactivate --sync`; `getactivewindow` must return the same window ID before Ctrl+L. The input log records PID, title, window IDs, and activation result. This avoids requiring the **Open** button to accept focus before a file has been selected.

After Ctrl+L, editable-field lookup is restricted to the native chooser's accessible ancestry and requires one field. The requested file path must match the field's native text within five seconds. The harness records both the text action's acceptance and the queried contents. Ambiguous fields, rejected actions, and mismatched text stop the diagnostic.

## Source compatibility checks

The following v1.17.0 source paths support the chosen route:

- `app/lib/pages/tabs/settings_tab.dart` exposes **Stop** for the running server. The harness observes **Start** after stopping it before installing forwarding.
- `app/lib/provider/network/send_provider.dart` makes outgoing HTTP requests independently of the server.
- `app/lib/provider/device_info_provider.dart` retains the certificate identity after stopping and reports alias `-`, port `-1`, and HTTPS `true`. This sender identity deviation is recorded rather than replaced.
- `common/lib/model/dto/info_register_dto.dart` accepts the sender port without range validation. The receive controller consumes the sender identity and saves the incoming stream; it does not call a sender server for this transfer.
- `app/lib/widget/dialogs/address_input_dialog.dart` uses the sender's unchanged default settings port 53317 for manual-IP discovery. After **Stop**, `adb forward tcp:53317 tcp:53317` routes `127.0.0.1` to the emulator. No protocol client substitutes for the sender.
- `app/lib/pages/language_page.dart` and `settings_tab.dart` expose real **Language**, **English**, **العربية**, and **Quick Save** controls. `quick_save_notice.dart` exposes **Close** for the notice.
- v1.17.0 `app/pubspec.lock` pins `file_selector_linux` 0.9.3+1. That exact package's `linux/file_selector_plugin.cc` constructs the native open chooser with title **Open File** and confirm label `_Open` at lines 105–106. The retained source is `recovered/2955/file-selector-linux-0.9.3+1.cc`; this check does not depend on the adjacent cached 0.9.3 version.

The runtime must independently observe AT-SPI on the official Linux release and Android UIAutomator semantics on the official APK. Source support is not proof that either accessibility bridge works. The workflow fails closed if they do not.

The tagged Android manifest targets API 34 and does not declare `MANAGE_EXTERNAL_STORAGE`; receiving calls the supported storage-permission request. The harness can accept an observed stock `com.android.permissioncontroller` **Allow** button. The API 36 Google image's runtime permission-controller package remains unverified. An unexpected package or Settings permission flow stops the diagnostic with its UI evidence; the harness does not grant permissions through shell commands.

## Cases and evidence

The harness selects a fresh uniquely named copy of the downloaded APK for each case: English with explicit acceptance; English with Quick Save; Arabic with Quick Save twice; and English again. It starts continuous receiver screen recording before the sender opens manual-recipient selection. Recording remains active through completion and the ordinary five-second final dialog. It also records the Linux screen. Screenshots and UI trees cannot establish rendered text alignment; inspect the retained raw video and images.

Each case requires an actual sender completion label and a saved receiver APK with identical SHA-256 and byte count. The explicit-approval case additionally requires the receiver's stable **Finished** label. For Quick Save, UIAutomator's wait-for-idle can miss the ordinary five-second countdown dialog, so that transient semantic observation is not a delivery gate. Recording continues for at least six seconds after sender completion, and the parent must inspect the original rendered frames for dialog presence and alignment. The ledger reports delivery separately from that review and generates no visual success conclusion.

Artifacts include release JSON, asset download URL/headers/hash, APK package/version/ABI validation, installed package metadata, runner and device properties, display/density/font scale, foreground/process identities, forwarding/routes, timestamped inputs, raw screen recordings, screenshots, semantic trees, logcat, and the failing stage. A failed control transfer stops later cases. Nothing is dispatched by preparing these files; dispatch remains a separate root decision.

Recording cleanup attempts stop, wait, pull, probe, and full decode independently. A naturally exited recorder does not prevent the raw-video pull. The ledger retains cleanup failures alongside the original failing stage. When delivery succeeds, failed retention, decode, or insufficient recording coverage still stops the diagnostic. Android's native recording limit is 180 seconds per case; the recording must cover completion and the ordinary dialog before any visual conclusion is possible.
