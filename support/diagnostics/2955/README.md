# Capture issue 2955 on an official release

This manual workflow prepares five finite transfers between the official LocalSend v1.17.0 Linux x86-64 sender and Android x64 receiver. It does not build or modify LocalSend. Source preparation has not established runtime compatibility or reproduced the report.

The receiver uses stock Android 16 API 36 x86_64. This differs from the reported Samsung S22, OneUI 8, and ARM64. The reporter did not identify their exact LocalSend version, sender, installer, Quick Save state, orientation, or font scale. v1.17.0 was the latest published release before the report date. The chosen sender and emulator cannot establish Samsung-specific behavior.

The workflow uses one job with a 60-minute limit. The runner stops earlier if release assets, ABI, native accessibility, UI controls, forwarding, completion, or saved-file verification fails. Missing or ambiguous native controls produce an infrastructure failure; the harness does not guess coordinates. Android taps use bounds from the currently visible semantic tree. Linux actions use AT-SPI or its exposed component bounds. Settings are changed only through visible application UI. Native file selection uses the GTK file chooser and its keyboard location command.

## Source compatibility checks

The following v1.17.0 source paths support the chosen route:

- `app/lib/pages/tabs/settings_tab.dart` exposes **Stop** for the running server. The harness observes **Start** after stopping it before installing forwarding.
- `app/lib/provider/network/send_provider.dart` makes outgoing HTTP requests independently of the server.
- `app/lib/provider/device_info_provider.dart` retains the certificate identity after stopping and reports alias `-`, port `-1`, and HTTPS `true`. This sender identity deviation is recorded rather than replaced.
- `common/lib/model/dto/info_register_dto.dart` accepts the sender port without range validation. The receive controller consumes the sender identity and saves the incoming stream; it does not call a sender server for this transfer.
- `app/lib/widget/dialogs/address_input_dialog.dart` uses the sender's unchanged default settings port 53317 for manual-IP discovery. After **Stop**, `adb forward tcp:53317 tcp:53317` routes `127.0.0.1` to the emulator. No protocol client substitutes for the sender.
- `app/lib/pages/language_page.dart` and `settings_tab.dart` expose real **Language**, **English**, **العربية**, and **Quick Save** controls. `quick_save_notice.dart` exposes **Close** for the notice.

The runtime must independently observe AT-SPI on the official Linux release and Android UIAutomator semantics on the official APK. Source support is not proof that either accessibility bridge works. The workflow fails closed if they do not.

## Cases and evidence

The harness selects a fresh uniquely named copy of the downloaded APK for each case: English with explicit acceptance; English with Quick Save; Arabic with Quick Save twice; and English again. It starts continuous receiver screen recording before the sender opens manual-recipient selection. Recording remains active through completion and the ordinary five-second final dialog. It also records the Linux screen. Screenshots and UI trees cannot establish rendered text alignment; inspect the retained raw video and images.

Each case requires an actual sender completion label and a saved receiver APK with identical SHA-256 and byte count. The explicit-approval case additionally requires the receiver's stable **Finished** label. For Quick Save, UIAutomator's wait-for-idle can miss the ordinary five-second countdown dialog, so that transient semantic observation is not a delivery gate. Recording continues for at least six seconds after sender completion, and the parent must inspect the original rendered frames for dialog presence and alignment. The ledger reports delivery separately from that review and generates no visual success conclusion.

Artifacts include release JSON, asset download URL/headers/hash, APK package/version/ABI validation, installed package metadata, runner and device properties, display/density/font scale, foreground/process identities, forwarding/routes, timestamped inputs, raw screen recordings, screenshots, semantic trees, logcat, and the failing stage. A failed control transfer stops later cases. Nothing is dispatched by preparing these files; dispatch remains a separate root decision.

Recording cleanup attempts stop, wait, pull, probe, and full decode independently. A naturally exited recorder does not prevent the raw-video pull. The ledger retains cleanup failures alongside the original failing stage. When delivery succeeds, failed retention, decode, or insufficient recording coverage still stops the diagnostic. Android's native recording limit is 180 seconds per case; the recording must cover completion and the ordinary dialog before any visual conclusion is possible.
