# macOS startup regression

The startup regression runs production `main` in the macOS `harness` flavor. This flavor uses the real Runner target and native plugin registry, with a timing gate in its native launch code. The gate holds launch completion until Dart requests `isLaunchedAsLoginItem`. The integration test then releases the gate and checks that `HomePage` appears instead of the initialization error screen.

From the repository root on macOS, with Xcode, FVM, and the pinned Flutter and Rust toolchains available, run:

```sh
fvm dart run support/test/macos_harness.dart
```

The command resolves the app and Cargokit build tool dependencies, runs the integration test with `--flavor harness`, and writes `artifacts/macos-startup.log`. The GitHub workflow runs the same command and uploads that log on success or failure. The harness has its own bundle ID and preferences, uses an unsigned build targeting macOS 12, and tests real startup scheduling. It does not exercise an actual OS login-item session, signing, or packaging.

The test writes an existing-installation version and an available port through the real preferences plugin. It starts production `main` while native launch completion is held, waits for the real login-item request or startup completion, and releases the hold even if that wait fails. The expected regression on the unfixed startup path is `MissingPluginException` for `isLaunchedAsLoginItem` on `main-delegate-channel`; the fixed path reaches `HomePage` after observing the request.
