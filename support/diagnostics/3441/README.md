# Issue 3441 receiver diagnostics

The readiness workflow installs the official LocalSend 1.18.2 DMG unchanged and records its first GUI launch. It starts no BrowserStack device or tunnel and sends no files. A successful readiness run establishes only that this cloud receiver and evidence backend are usable.

## Environment and budget

- Runner: `macos-15`, documented ARM64 image. The setup requires `uname -m = arm64` and macOS major version 15, and retains the actual image version and hardware model.
- Reported receiver: M1 with macOS 12.7.6. The cloud OS differs, and the actual hosted hardware model must be read from the retained `hardware.txt`; ARM64 does not establish an M1 match.
- Readiness: one job, 20-minute hard limit, no BrowserStack sessions, no secrets or tunnel.
- Integrated transfer: one `macos-15` job, 45-minute hard limit and one coordinator-reserved Samsung S23 Android 13 session. Its first step records the hard deadline before checkout or preparation; the controller refuses allocation with less than 20 minutes left and reserves the final 10 minutes for cleanup and artifacts.
- Cleanup stops only `/Applications/LocalSend.app/Contents/MacOS/*` and removes the owned temporary directory. The VM is ephemeral. Evidence remains in the Actions artifact.

## Installation and profile

`setup.sh` mounts the official DMG read-only, copies the complete app using `ditto`, checks its released version and strict signature, then opens it normally. The profile is the hosted user's fresh native preferences outside the signed bundle. Setup refuses an existing native preferences domain and refuses `Contents/MacOS/settings.json`. There is no `--profile` option in the release startup code; portable mode writes beside the executable and is unsuitable here.

The receiver keeps normal encryption and manual approval. Before the transfer gate, confirm the rendered Receive page and default Downloads destination against the screenshots, native preferences and exact release source. Missing accessibility, pixels, or continuous capture is an infrastructure failure before reproduction. The helper may press the enabled native `Allow` button only in the exact observed prompt, `Allow “LocalSend” to find devices on local networks?`, containing both `Don't Allow` and `Allow` buttons. It normalizes quotes and whitespace, rejects ambiguous controls, and retains the prompt PID/context, system tree and before/after screenshots. It does not bypass privacy controls or rewrite signing contents.

`ax.swift` locates buttons by exact accessible title, description, or value and rejects ambiguous matches. `receiver.mjs` records the accessibility tree and full screen, continuous native capture, monotonic action times, and strict signature checks. An AX tree alone does not prove the app rendered correctly: inspect the retained pixels and decoded video frames before admitting transfer.

The first readiness run, `38205824955`, retained a rendered Receive page covered by Apple's local-network permission dialog. The application-only accessibility tree exposed its native frame and menus, so the earlier main-page assertion failed before any transfer. The revised helper inventories all running applications and the system-focused element's ancestors, then presses only the contextual exact `Allow` button. This corrects first-launch preparation, not LocalSend behavior.

Run `38206670584` successfully pressed that exact permission button in UserNotificationCenter (PID 2774, action result 0) and retained the prompt-free Receive page. The subsequent public accessibility probe reported writable, before `0`, after `1`, and setter return `-25208`. The negative setter return remains a failed setter operation even though the later observation was enabled and Flutter controls appeared. The next failure was the harness's plain navigation names: the raw AX buttons are exactly `Receive\nTab 1 of 3`, `Send\nTab 2 of 3`, and `Settings\nTab 3 of 3`. The harness now uses these observed qualified names without fuzzy matching. The run performed no transfer.

When the prompt closes but Flutter labels remain absent, the helper queries the application's `AXEnhancedUserInterface` attribute with `AXUIElementIsAttributeSettable`. It attempts a normal external AX attribute write only when the application advertises the attribute as writable, and retains the query/write result codes and before/after values. Unsupported or ineffective writes leave the semantic readiness assertion failing; there is no private notification posting or runtime injection.

The release source at `af0416be50770a97760f7070684bc667b759a15c` pins Flutter 3.41.9 in `.fvmrc`. The [Flutter 3.41.9 macOS engine source](https://github.com/flutter/flutter/blob/3.41.9/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterEngine.mm) defines `AXEnhancedUserInterface` and uses the OS accessibility-status change to enable semantics. The [generated engine documentation](https://api.flutter.dev/macos-embedder/_flutter_engine_8mm_source.html) corroborates this mechanism. This source citation does not independently prove the downloaded app's compiler version or that macOS permits an external write; the retained runtime result establishes only the tested attribute behavior.

## Later real transfer interface

`receiver.mjs` exports `ready()`, `startRelay()`, `startCase(id)`, `finishCase()`, `stopRelay()`, `snapshot(label)`, and `press(exactLabel)`. The Android controller receives this module through `runAndroidSender({output, fixtureDirectory, receiver})`.

The separate native Android helper listens on `127.0.0.1:53318` and relays opaque TCP through BrowserStack Local HTTP to port 8080. The macOS relay connects to the real receiver at `127.0.0.1:53317`. The original Android app retains its TLS handshake with the original macOS app. Manual IP targeting, tunneled transport, cloud latency and loss of original LAN multicast discovery are explicit fidelity limits. No helper or protocol control counts as product reproduction.

Start each case before the native sender presses Send. The receiver captures the actual approval screen and presses the single exact `Accept` button. `finishCase()` retains the full destination filename/byte/hash inventory, including the original batch and retry duplicates such as `(2)`, and compares each new saved file with its source. It never removes initial files before retry. Sender completion alone is insufficient; require the receiver evidence and inspect any zero-byte files.

`fixtures.mjs` generates 207 distinct filenames and a separate one-file control, decodes every generated JPEG/MP4, and emits an ordered `manifest.json` with `files` and `cases`. Retry uses the same first 73 source names and exact source bytes, totaling 85,600,000 bytes. That decimal count approximates the screenshot's rounded 85.6 MB. Generated test imagery and legal JPEG COM / MP4 free-box padding differ from the original camera files and do not establish their original contents or sizes.

The transfer workflow is fork-only. Its push trigger matches only `codex/diagnose-3441-transfer` and requires `[issue3441-transfer-admitted]` in the head commit message. Dispatch defaults to no admission. Freeze and source review precede the coordinator's admitted push. The readiness workflow's earlier branch does not match this branch.

The final ten minutes are shared: native scenarios stop at minute 35, controller teardown and provider evidence end by minute 37, independent Android/tunnel cleanup has two minutes, combined signature/capture/app cleanup one minute, and GitHub artifact upload five minutes. `run-transfer.mjs` enforces the absolute minute-37 boundary independently of the controller, retains its exit/time record, and bounds TERM-to-KILL to one second. Interrupted media retention is an infrastructure limit and does not establish an app failure.

The receiver DMG is pinned to 52,700,247 bytes and SHA-256 `126860d56f6f49b11845f601aac51de27a49b16d2b48102415da91e0e37e5155`, recovered from the reviewed readiness run `38207190519`. The unchanged Android ARM64 APK is pinned to 46,558,706 bytes and SHA-256 `82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3`; upload is refused until both match. Evidence binds each private provider app reference through SHA-256 without retaining the reference.

BrowserStack's documented macOS Local download is Intel, so the ARM64 runner uses Apple's supported Rosetta installation. The ZIP is pinned to SHA-256 `bb293eeeeec062f97b380a0de077a2e5aea48b288b4bb654f8274ee6483b2d4d` and its x86_64 binary to `9091089b71864a5f840ba26eb15e141be184676cf2c9f0d821c53cb4cd42d8fb`. Cloud evidence records the binary architecture/version and Android SDK35 tool architecture/version. A changed vendor download fails closed; no guessed ARM URL is used. [BrowserStack release documentation](https://www.browserstack.com/docs/local-testing/releases-and-downloads/release-notes/binary-v8-9) and the [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) describe these tools.

The opaque relay's 90-second progress/idle timer and 15-minute peer lifetime remain transport limits. A reset or timeout at this layer is an infrastructure event unless actual native app terminal screens and receiver inventories independently establish the reported behavior. Synthetic media, cloud macOS15, S23 model, Rosetta tunnel tooling and the reverse route remain disclosed differences from the original report.

## Transport provenance

The copied transport source was read from the issue 3556 clone at `d0078326d966b48a3bc22910e9f00285b4d490ad`. Git blob IDs before copying:

| File | Blob |
| --- | --- |
| relay.mjs | `6ad2bcf03060044a33028eb9cf05c521cb099e2b` |
| AndroidManifest.xml | `2d608520f98902a5c27603f2e8aae14b3bc540cc` |
| MainActivity.java | `df96a06ab2b07411f56d861201e38d53295fb0a6` |
| RelayService.java | `f3826f0301ec53ab9626dd98aa162e1136273c99` |

The older README's common commit `c458fa4` does not contain these files at their present paths, so it is not cited as the copy identity. Previous physical transport controls are supplementary evidence only; the integrated route must pass its own fresh controls before app-to-app attribution.
