# Issue 3441 receiver diagnostics

The readiness workflow installs the official LocalSend 1.18.2 DMG unchanged and records its first GUI launch. It starts no BrowserStack device or tunnel and sends no files. A successful readiness run establishes only that this cloud receiver and evidence backend are usable.

## Environment and budget

- Runner: `macos-15`, documented ARM64 image. The setup requires `uname -m = arm64` and macOS major version 15, and retains the actual image version and hardware model.
- Reported receiver: M1 with macOS 12.7.6. The cloud OS differs, and the actual hosted hardware model must be read from the retained `hardware.txt`; ARM64 does not establish an M1 match.
- Readiness: one job, 20-minute hard limit, no BrowserStack sessions, no secrets or tunnel.
- Proposed later transfer: one job, 45-minute limit and one coordinator-reserved Samsung Android 13 session. The transfer scaffold has no dispatchable workflow yet.
- Cleanup stops only `/Applications/LocalSend.app/Contents/MacOS/*` and removes the owned temporary directory. The VM is ephemeral. Evidence remains in the Actions artifact.

## Installation and profile

`setup.sh` mounts the official DMG read-only, copies the complete app using `ditto`, checks its released version and strict signature, then opens it normally. The profile is the hosted user's fresh native preferences outside the signed bundle. Setup refuses an existing native preferences domain and refuses `Contents/MacOS/settings.json`. There is no `--profile` option in the release startup code; portable mode writes beside the executable and is unsuitable here.

The receiver keeps normal encryption and manual approval. Before the transfer gate, confirm the rendered Receive page and default Downloads destination against the screenshots, native preferences and exact release source. Missing accessibility, pixels, or continuous capture is an infrastructure failure before reproduction. The helper never grants privacy permissions or rewrites signing contents.

`ax.swift` locates buttons by exact accessible title, description, or value and rejects ambiguous matches. `receiver.mjs` records the accessibility tree and full screen, continuous native capture, monotonic action times, and strict signature checks. An AX tree alone does not prove the app rendered correctly: inspect the retained pixels and decoded video frames before admitting transfer.

## Later real transfer interface

`receiver.mjs` exports `ready()`, `startRelay()`, `startCase(id)`, `finishCase()`, `stopRelay()`, `snapshot(label)`, and `press(exactLabel)`. The Android controller receives this module through `runAndroidSender({output, fixtureDirectory, receiver})`.

The separate native Android helper listens on `127.0.0.1:53318` and relays opaque TCP through BrowserStack Local HTTP to port 8080. The macOS relay connects to the real receiver at `127.0.0.1:53317`. The original Android app retains its TLS handshake with the original macOS app. Manual IP targeting, tunneled transport, cloud latency and loss of original LAN multicast discovery are explicit fidelity limits. No helper or protocol control counts as product reproduction.

Start each case before the native sender presses Send. The receiver captures the actual approval screen and presses the single exact `Accept` button. `finishCase()` retains the full destination filename/byte/hash inventory, including the original batch and retry duplicates such as `(2)`, and compares each new saved file with its source. It never removes initial files before retry. Sender completion alone is insufficient; require the receiver evidence and inspect any zero-byte files.

`fixtures.mjs` generates 207 distinct filenames and a separate one-file control, decodes every generated JPEG/MP4, and emits an ordered `manifest.json` with `files` and `cases`. Retry uses the same first 73 source names and exact source bytes, totaling 85,600,000 bytes. That decimal count approximates the screenshot's rounded 85.6 MB. Generated test imagery and legal JPEG COM / MP4 free-box padding differ from the original camera files and do not establish their original contents or sizes.

## Transport provenance

The copied transport source was read from the issue 3556 clone at `d0078326d966b48a3bc22910e9f00285b4d490ad`. Git blob IDs before copying:

| File | Blob |
| --- | --- |
| relay.mjs | `6ad2bcf03060044a33028eb9cf05c521cb099e2b` |
| AndroidManifest.xml | `2d608520f98902a5c27603f2e8aae14b3bc540cc` |
| MainActivity.java | `df96a06ab2b07411f56d861201e38d53295fb0a6` |
| RelayService.java | `f3826f0301ec53ab9626dd98aa162e1136273c99` |

The older README's common commit `c458fa4` does not contain these files at their present paths, so it is not cited as the copy identity. Previous physical transport controls are supplementary evidence only; the integrated route must pass its own fresh controls before app-to-app attribution.
