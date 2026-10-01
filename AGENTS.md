# AGENTS.md

LocalSend disallows AI generated contributions unless they are bug fixes, very small, or demonstrate expertise in the field.

## Working in this repository

- Make targeted changes for the requested behavior. Complete implementation and relevant checks; broaden testing only for failures or unresolved concerns. Each added test should catch a meaningful regression.
- Use `fvm flutter` / `fvm dart`: the toolchain is pinned in `.fvmrc`. For a version bump, follow “Bump Flutter” in `CONTRIBUTING.md` to update all four version locations.
- Keep Dart formatting at 150 columns. Exclude generated `app/lib/gen/` from format checks. Revert incidental 80-column rewrites of `app/test/mocks.mocks.dart` without discarding intentional changes.
- Build and test `packages/core` with `--features full`. Its default features are empty; bare builds fail on optional dependencies, a pre-existing limitation.

## Build and code generation

The Rust crates share the root Cargo workspace, lockfile, and target directory. Put profile settings in the root `Cargo.toml`. Cargokit uses a separate target directory for Flutter builds.

The Dart packages share the root pub workspace and lockfile; `fvm flutter pub get` from any member resolves them together. `rust_builder` and its vendored `cargokit/build_tool` resolve separately.

Run app commands from `app/`:

```bash
fvm flutter pub get
fvm dart run build_runner build
fvm dart run slang
fvm dart format --set-exit-if-changed lib test
fvm flutter analyze
fvm flutter test
```

Slang uses its own command because `slang_build_runner` is disabled. When isolate-package models change, run `build_runner` separately in `packages/localsend_isolates/`. For Rust bindings, run `flutter_rust_bridge_codegen generate` there; its config sets Dart formatting to 150 columns.

For core changes, run `cargo test --features full` and `cargo clippy --features full` from `packages/core/`. For the plugin crate, signaling server, or CLI, run `cargo check` in the affected crate.

## Architecture constraints

The app depends only on `localsend_isolates`, which connects `typed_isolates` and the Rust plugin to `packages/core`. Keep networking in the child isolates and Rust core.

### Dart and isolates

- Use Refena: plain state uses `NotifierProvider`; isolate interactions use `ReduxProvider` actions.
- `dart_mappable` names are customized: `fromJson` / `toJson` convert Maps; `deserialize` / `serialize` convert strings.
- Send app-to-child commands through `packages/localsend_isolates/lib/src/isolate/parent/actions.dart` and `actions_sync.dart`. Keep `lib/src/task/` helpers free of isolate logic; read its `README.md` when changing them.
- Sync server settings with `IsolateSyncServerStateAction` before starting the server, because children read that state at startup.

### HTTP and transfers

For server changes, start in `packages/core/src/http/server/` and the FRB adapter `packages/localsend_isolates/rust/src/api/server.rs`. Dart's `server_provider.dart` routes events to `ReceiveController` / `SendController`; these handle events rather than HTTP routes.

- Serve protocol v2; v1 endpoints are not served. Extend `ServerEventV2` for server-to-app interactions.
- Keep one active upload session and preserve cancellation drop guards. Auto-accept belongs in the app's answer to `decision_tx`.
- Dart chooses save targets; Rust writes them. Android SAF uses a file descriptor from the `org.localsend.localsend_app/localsend` method channel. Gallery saves use a cache file first.
- Keep `PeerIp` scope IDs so link-local IPv6 addresses remain dialable.
- Prefer `event.certFingerprint ?? event.info.fingerprint`: the certificate identifies encrypted peers; the payload fallback is for encryption-off mode. Client certificates are mandatory except while serving browser pages. Reject registration when the claimed fingerprint differs from the certificate.
- Restart the server when either receive or web-send PIN changes; both are fixed at startup.
- Browser download assets are embedded from `packages/core/assets/web/`.

### Multicast discovery

When changing `packages/core/src/multicast/`, preserve announce-only UDP discovery: responses use HTTP unicast registration. Each IPv4 interface address has its own socket; IPv6 uses an `IPV6_V6ONLY` socket per interface and retains the source scope ID. Keep loopback enabled for instances on the same host and filter own messages by fingerprint. Discovery uses protocol v2.2, without v1 parsing.

## Translations, packaging, and releases

- Edit Slang sources in `app/assets/i18n/`; output goes to `app/lib/gen/`. Translation keys prefixed with `@` are translator metadata. `app/test/unit/i18n_test.dart` guards the locale set.
- Preserve `# [FOSS_REMOVE]` and `// [FOSS_REMOVE_START]` / `// [FOSS_REMOVE_END]` markers in donation and purchase code, `lib/config/init.dart`, and pubspec files; the F-Droid stripping script depends on them.
- Keep versions aligned in `app/pubspec.yaml`, `support/scripts/compile_windows_exe-inno.iss` (`MyAppVersion`), and `cli/Cargo.toml`. Read `README.md` (“Building”) and `CONTRIBUTING.md` (“Release”) for platform builds and releases.
