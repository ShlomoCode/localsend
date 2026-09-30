# macOS startup regression

The `macOS startup regression` workflow builds and runs the real macOS Runner with a Flutter integration-test entrypoint. The test calls production `main`, then checks that `HomePage` appears instead of the initialization error screen.

The same test runs on `codex/test-macos-startup-main` and `codex/test-macos-startup-fixed`. The former contains the unfixed startup path and should fail with `MissingPluginException` for `isLaunchedAsLoginItem`; the latter contains the fix and should pass.

To make the race reproducible, `macos_startup_gate.py` modifies only the disposable build checkout. It holds the native launch-completion work until Dart reaches the login-item request or displays an error. A separate control channel releases the hold. The production `main-delegate-channel`, native plugins, and responses remain real. The launch Apple event is read in the original macOS callback before deferring the remaining work.

The test writes preferences for an existing installation through the real preferences plugin. This avoids the first-launch reduce-motion query and targets the reported login-item query.

The workflow uses the pinned Flutter SDK, an Apple Silicon macOS 15 runner with Xcode 26.3, and an unsigned Debug build. Flutter disables sandboxing in this CI configuration. It does not verify App Store packaging, a signed DMG, or an actual login-item launch.

Apply the timing overlay only in a disposable checkout:

```sh
python3 support/test/macos_startup_gate.py app/macos/Runner
cd app
fvm flutter test integration_test/macos_startup_test.dart -d macos --reporter expanded
```

Local execution also needs compatible Xcode signing settings. The workflow configures an unsigned build in its disposable checkout and uploads the full startup log on success or failure.
