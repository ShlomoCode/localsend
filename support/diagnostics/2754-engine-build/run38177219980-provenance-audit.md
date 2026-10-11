# Run 38177219980 package and mapped-identity audit

The retained artifacts support successful normal A package construction, execution of all ten package-build tests, a bridge-only apt package delta in AB, and selected control/B engine and AOT identities in all three initial guest processes. These findings concern provenance and loader evidence only. They do not establish product behavior or acceptance, explain the workflow failure, or validate a later restarted process.

## Evidence roots and harness identity

- Compact evidence: `/tmp/2754-packaged-38177219980-compact`.
- Full evidence used for direct package/binary hashes and test logs: `/tmp/2754-packaged-38177219980-full`.
- Accepted immutable app evidence: `/tmp/2754-accepted-app-evidence/issue2754-c1ce-engine-control-linux-x64` and `/tmp/2754-accepted-app-evidence/issue2754-c1ce-engine-B-linux-x64`.
- `package/build/diagnostic-head.txt` records harness source `76946d6a2d79e1574c46cb7717220edd10ad7222`.

Paths below are relative to the compact evidence root unless explicitly stated otherwise.

## Actual A package build and tests

`package/build/result.txt` records `exit_status=0`. The actual `package/build/package-build.log` identifies `dpkg-buildpackage`, source package `at-spi2-core`, source version `2.52.0-1build1+localsend2754.1`, noble, and amd64 at lines 40–45. It records binary-only packaging at line 1962.

The log at lines 563–590 records `override_dh_auto_test`, then `xvfb-run -s -noreset -a dbus-run-session -- dh_auto_test`, and Meson test execution. All ten named tests passed: dbind-test, droute-test, memory, testdocument, testrole, testrelation, teststateset, testvalue, socket-local-experiment, and atk-test. Summary: 10 OK, 0 expected failures, 0 failures, 0 unexpected passes, 0 skipped, 0 timeouts. This is actual execution evidence, not merely a test command in source. The full artifact retains `package/build/work/at-spi2-core-2.52.0/obj-x86_64-linux-gnu/meson-logs/testlog.txt`, JSON, and JUnit output. Its inherited environment records the `noudeb` build profile; this is not a claim that Debian autopkgtests or a separately installed-package test suite ran.

`socket-local-experiment` is the A patch's added regression executable, not an official baseline test. The full artifact's `package/build/A-local-dispatch.patch:315` adds its Meson definition and at line 333 adds `tests/at-spi2-atk/socket-local-experiment.c`. The applied source's `tests/at-spi2-atk/meson.build:85` defines that executable and at line 90 registers it through `dbus-run-session`. The final quilt series appends `localsend-2754-local-dispatch.patch` to the official series; that patch is byte-identical to the captured A patch. The count of ten therefore includes the added regression executable alongside the existing tests. Direct comparisons found no change to official versus final `debian/rules` or the `debian/tests/` directory. “Unchanged Debian rules/tests” refers to those packaging files and the test invocation, not an unchanged source test set. The source test set was extended by A.

The candidate manifest, `package/build/debs.sha256`, and `package/build/target-library.sha256` agree on:

| Artifact | SHA-256 |
| --- | --- |
| `libatk-bridge2.0-0t64_2.52.0-1build1+localsend2754.1_amd64.deb` | `5b4c8d9412bde7042f17c9ddf0eae68683d9b417ac2c9d486909ddd8b340f0c4` |
| `libatk-bridge-2.0.so.0.0.0` | `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297` |

Direct read-only `shasum -a 256` of the full artifact's `package/build/candidate/` DEB and `package/build/target-root/usr/lib/x86_64-linux-gnu/` library reproduced both values. `package/build/metadata/target-library.notes` records build ID `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2`. The manifest identifies variant A, official source version `2.52.0-1build1`, and patch SHA-256 `d4348bcd7197e837b03004f7e80ca6dc69b4bee8cd81ea35dba94dd37424f01d`.

## AB installation and package delta

`comparison/AB-package/guest/bridge-package/manifest.json` agrees with the build candidate manifest. `transport-verified.txt` reports both the DEB and manifest OK. `apt-plan.txt` and actual `apt-install.txt` report one upgraded package, zero new packages, and zero removals. The actual installation unpacks and configures the named local DEB.

`packages-before.tsv`, `packages-after.tsv`, and `package-diff.txt` record exactly one version change: `libatk-bridge2.0-0t64` from `2.52.0-1build1` to `2.52.0-1build1+localsend2754.1`. A direct `diff -u` of `other-packages-before.tsv` and `other-packages-after.tsv` returned 0 with no output. `dpkg-verification.txt` is empty. The actual apt log includes the libc-bin trigger and noninteractive debconf frontend fallbacks; those lines do not indicate another package version change.

The AB process bridge hash is `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297`, matching the directly hashed built library. B-system and control-system process bridge hashes remain `366fcd2f2cd9a77767855a7c25b00ffce57e6b55109a2bf800872f0337a28415`, matching all three guests' recorded pre-install system bridge hash. Evidence: each cohort's `guest/bridge-process-library.sha256`, `guest/system-bridge-library.sha256`, and `guest/bridge-process-map-check.txt`.

## Immutable app/engine/AOT comparison

All three `comparison/COHORT/guest/source-artifact/provenance/manifest.json` files were compared directly with the appropriate accepted control or B manifest. Each byte comparison returned 0: control-system against accepted control, B-system and AB-package against accepted B.

The manifests identify accepted app build run `38164164206`, engine build run `38153341418`, LocalSend commit `c1ce322fb3acf08e44f329b8b7208b8b0d91e244`, framework commit `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694`, and engine commit `42d3d75a56efe1a2e9902f52dc8006099c45d937`. Their original app compilation records have Flutter and log-capture exit 0 and build exit 0; before/after/app source-status files are empty. Those are retained records of the accepted build, not new builds in this comparison run.

| Cohort | Initial PID | Engine SHA-256 | AOT SHA-256 |
| --- | --- | --- | --- |
| control-system | 4505 | `a5d59efac8589f609dd783a6c3b35b314b1bc0a9b0ac023af23321f7f50b21ff` | `a5c223e03b29818f3982a28d8893f56f60aa5bf7921b9c095fd16f2b80344a66` |
| B-system | 4492 | `1cb9ec7c0516575ef5cdcd452a5de53761680539e5f5d78db7c88a7bad254ab3` | `e34ebc05ed2bd6bea8ce59b4e088bb7f2904f86a8f04e0ad21269d5dc6f156d5` |
| AB-package | 4618 | `1cb9ec7c0516575ef5cdcd452a5de53761680539e5f5d78db7c88a7bad254ab3` | `e34ebc05ed2bd6bea8ce59b4e088bb7f2904f86a8f04e0ad21269d5dc6f156d5` |

Each cohort's `guest/engine-loaded/loaded-artifact-SHA256SUMS` contains these values at `/home/mint/source-bundle/lib/libflutter_linux_gtk.so` and `/home/mint/source-bundle/lib/libapp.so`. A direct read-only hash of the accepted control/B extracted engine and AOT binaries reproduced all four values. `mapped-engine-paths.txt` and `mapped-aot-paths.txt` record those selected paths, and `process-executable.txt` records `/home/mint/source-bundle/localsend_app`. Raw process maps are retained alongside them.

For each PID, `guest/engine-process-map-check.txt` records `mapped_selected_engine=true` and `mapped_selected_aot=true`; `guest/bridge-process-map-check.txt` records `mapped_selected_bridge=true`; and `guest/engine-loader-deadline.txt` records `loader_gate_before_ui=true`. The PID is consistent across those three files. Recorded engine ELF build IDs are `3250d456a3d08a73a1cf86cc97fb8cca7d442d6e` for control and `301dab74f9fa5a1d880dc6c3b744391b63a7844f` for B and AB.

The loader's library-package records show stock `libatk1.0-0t64` and `libatspi2.0-0t64` version `2.52.0-1build1`, and GTK `3.24.41-4ubuntu1.3`, in all three guests. Only AB records the A bridge package version. `engine-loaded/process-loader-env.txt` is empty in all three; this supports the recorded absence of selected loader override variables, not the absence of every environment variable.

## Scope and limits

This audit read retained artifacts, compared manifest/TSV bytes, and hashed retained binaries. It changed only this `/tmp` report. No local tests, builds, app execution, reproductions, guest jobs, or dispatches occurred. Initial loader identity, package construction, and package delta are supported. Workflow completion, timing results, native chooser behavior, geometry, interactions, speech, restarted-process identities, and product acceptance require their own evidence and are outside this audit.
