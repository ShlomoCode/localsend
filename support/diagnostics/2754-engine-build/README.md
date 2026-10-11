# Source-built engine diagnostics for issue 2754

These scripts prepare a clean engine control and B from Flutter engine revision `42d3d75a56efe1a2e9902f52dc8006099c45d937`, then rebuild unmodified LocalSend `c1ce322fb3acf08e44f329b8b7208b8b0d91e244` using Flutter 3.41.9 framework revision `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694`. They are diagnostic tooling. A source-built artifact does not establish UI behavior or a shipping decision.

The parent must coordinate every dispatch after the native A/B plan gate. This directory does not change or dispatch a workflow. Keep at most one owned cloud job active; do not create a concurrent variant matrix. No application patch, engine shim, code generation, or API-only engine-library substitution is used.

## Workflow interface

Invoke the three cloud scripts through Bash on a public GitHub-hosted Ubuntu 24.04 x64 runner. They refuse other hosts, including the local development host. Use a fresh output directory per stage. `RUNNER_TEMP` supplies all source/build scratch paths; never use a user's checkout as `PROBE_ENGINE_ROOT`.

Every cloud stage also requires `GITHUB_REPOSITORY=ShlomoCode/localsend`, including bootstrap and engine compilation.

`workflow-job-fragment.yml` is an integration draft stored outside `.github/workflows`; it does not run automatically. Merge its `engine` stage choice and jobs into the existing diagnostic workflow while preserving the other inputs/jobs and the `issue2754-cinnamon-diagnostic` concurrency group. The draft puts bootstrap and engine compilation on one Ubuntu 24.04 runner with a 360-minute job limit, followed by separate 90-minute control and B app jobs with sequential dependencies. The engine script still enforces its own 180-minute compilation budget. Resource exit 3 remains an ordinary failed step with an explicit error and recorded exit code, so downstream app jobs cannot run after that failure.

The draft explicitly enables the authorized disposable SDK cleanup for the engine job. It uploads compact evidence first on every outcome, retains complete stage evidence, and uploads whole engine variant directories and full app bundle directories under distinct control/B artifact names. Compact uploads whitelist logs, manifests, hashes, test XML, and configuration evidence; they include no source checkouts, dependency trees, or binary archives. GitHub step failure skips later build steps, while `always()` evidence steps preserve partial results. Final runner/time feasibility and every dispatch remain the parent's decision; the draft includes no VM launch.

| Script | Arguments and input | Output |
| --- | --- | --- |
| `bootstrap.sh OUTPUT_DIR` | Optional `PROBE_RECLAIM_RUNNER_SDKS=1`; optional scratch `PROBE_ENGINE_ROOT` and `PROBE_DEPOT_ROOT` under `RUNNER_TEMP` | Resource measurements, source and resolved dependency/toolchain provenance; source checkout ready for build |
| `build-engines.sh OUTPUT_DIR` | The same source/depot roots from successful bootstrap, on the same runner | `control/` and `B/`, each containing `host-release.tar.gz`, its SHA256, and `provenance/`; official B native test XML/logs |
| `build-app.sh ENGINE_VARIANT_ARTIFACT_DIR OUTPUT_DIR` | Explicit `PROBE_VARIANT=control` or `B`; Rustup available; run in `ShlomoCode/localsend` | Full c1ce `source-bundle.tar.gz`, SHA256, source/framework/lock/engine manifests |
| `verify-loaded-engine.sh PID BUNDLE_DIR PROVENANCE_DIR OUTPUT_DIR` | Invoke in the Mint guest while the actual app scenario process remains alive; requires jq/binutils/coreutils | Actual executable and engine mappings, hashes, ELF identity, GTK/ATK package reports |

GitHub jobs do not share scratch directories. Run bootstrap and engine compilation on the same physical runner, or repeat bootstrap in a later engine-build job. A separate 30-minute bootstrap probe can establish feasibility, but its `engine-root.txt` path cannot bootstrap another job. Transport the engine variant TARs and provenance to app-build jobs through named artifacts. Complete the control app-build job before starting the B app-build job.

Default scratch paths are `$RUNNER_TEMP/issue2754-engine-source` and `$RUNNER_TEMP/issue2754-depot-tools`. The app builder creates fresh per-run, per-variant source/framework/engine paths. An interrupted attempt retains those directories for evidence; retry in a fresh runner or explicit new bootstrap scratch paths rather than removing an unknown directory.

## Resource and bootstrap gate

`bootstrap.sh` records `free`, `df`, disk use, and timestamps before/after each resource stage. Its preflight requires at least 50 GiB available disk and approximately the public runner's 16 GiB memory. These are conservative planning budgets, not measured minimum engine requirements. It exits 3 with `RESOURCE_GATE_FAILED` when those criteria fail. It does not represent that failure as an engine or B test failure.

Optional SDK reclamation removes only `/usr/share/dotnet`, `/usr/local/lib/android`, `/opt/ghc`, and `/opt/hostedtoolcache/CodeQL`, after verifying a fresh GitHub-hosted runner and rejecting symbolic links. It logs each present directory's size. It never removes user data, workspace checkouts, runner state, or a generic home/cache tree. On a standard runner that cannot provide the free-space budget after this explicit cleanup, preserve the report and use a coordinated runner with sufficient space; do not reduce the gate silently.

Bootstrap installs runner-native packages needed by the GN/test/app path and uses the engine's own pinned Clang, GN, Ninja, Dart SDK, and Debian sysroot for engine compilation. It clones exact engine/depot_tools commits, disables depot_tools auto-update, verifies the original DEPS SHA256, records standard and actual `.gclient` configurations, disables unneeded Android/Fuchsia/Windows/web/RBE dependencies via supported custom variables, and runs `gclient sync --no-history --jobs=2` with a 25-minute timeout. Give the workflow at least 30 minutes and always upload the stage directory, even on failure.

The pinned JDK dependency lacks a DEPS condition, so `download_jdk=False` is recorded but is not a claim that no JDK bytes are downloaded. Linux sysroot hooks include other architectures as well as x64. The script preserves the official hooks rather than editing source to save space. `gclient revinfo -a` and `cipd installed` record source revisions and resolved package instance IDs. Successful bootstrap writes a completion marker only after the provenance checks pass.

Completed dependency/toolchain records are snapshotted in `issue2754-bootstrap-provenance` inside the engine scratch checkout and in `bootstrap-provenance/` inside the bootstrap evidence output. A relative `records-SHA256SUMS` pins the snapshot. The engine gate verifies it and the actual recorded tool binaries before compilation. Each engine variant transports that snapshot in `provenance/bootstrap/`, and its manifest contains the SHA256 of `records-SHA256SUMS`. Upload the complete variant directory, including provenance, rather than its TAR alone. The app gate verifies that manifest link and all snapshot records before accepting an engine; its resulting bundle provenance carries the same records onward to the guest artifact.

## Sequential engine gate

`build-engines.sh` uses one 180-minute budget for the release control, official B test compilation/execution, and release B build. Every Ninja invocation uses `-j2 -l2`. Release GN flags match the pinned desktop CI path: `--runtime-mode release --enable-fontconfig --prebuilt-dart-sdk --no-lto`, with unit test building explicitly disabled for release. RBE is omitted because it requires Google's infrastructure. Preserve these differences in artifact provenance.

The release builder requests the existing GTK engine target and additional sky/Dart/frontend/font/const-finder/shader targets consumed by Flutter local-engine tooling. It asserts the expected artifacts and generates a TAR containing the complete selected local-engine consumer inputs. Generated links are dereferenced so their targets are included in the transport. It excludes compiler object directories and temporary unstripped trees rather than transporting an entire build workspace.

The control is built from clean tracked engine source. It is preserved before applying `B-with-tests.patch`. That file is the complete previously reviewed experimental patch copied without reconstructing GN registration or test bodies; `assets-SHA256SUMS` pins it. B is applied with `git apply --check` and the resulting source diff is retained. B's native tests use the existing `flutter_linux_unittests` target in a separate debug/unoptimized output with Xvfb. Require all five candidate tests to pass, none skipped. The official target includes GTK mocks, so its coordinate tests remain modeled geometry.

The release B build uses the same source checkout, DEPS, toolchain, GN flags, and output path as the control. Ninja rebuilds dependencies affected by B. Its engine hash must differ from the preserved control hash. Each variant manifest records its exact engine hash and experiment patch hash; the control identifies B as the candidate being compared but contains no B production edit. No runtime outcome is inferred from compilation.

The first cloud run still needs to establish bootstrap compatibility, peak resources, exact generated target layout, and completion time. A failed artifact-presence assertion is a concrete build-route blocker; preserve it and adjust the exact existing GN target list from evidence. Never fill a missing local artifact by substituting cached official engine bytes.

## App and guest gate

The app script validates the selected engine manifest, TAR SHA256, and per-file SHA256 list, then restores the output under an isolated `engine/src/out/host_release`. It fetches the exact framework commit and its verified release tag so shallow-checkout version reporting remains 3.41.9. It checks the framework's engine-version file and `flutter --version --machine`, fetches c1ce from the fork repository, and installs Rust 1.97.1 explicitly.

Both pub dependency resolutions use `--enforce-lockfile`. Before/after hashes cover workspace pub, Cargo, and standalone cargokit locks. Changed tracked app source or changed locks fail the gate and are retained even on a failed build. No models, codegen, application semantics, or public Dart API are changed.

The Flutter invocation supplies `--local-engine-src-path`, `--local-engine=host_release`, and `--local-engine-host=host_release` before `build linux --release -v`. It records generated CMake configuration and the verbose build, then requires the bundle's `libflutter_linux_gtk.so` SHA256 to match both the source-built output hash and manifest. It retains `libapp.so` and complete bundle hashes. Package the entire release bundle for the Mint transport.

The app artifact also carries source SHA, machine-readable Flutter version, lock hashes, source diff, and build exit result in `provenance/`, matching the existing c1ce staging evidence conventions. The workflow must select a distinct artifact name for engine control/B and validate `provenance/manifest.json`; it must not mistake an earlier official-engine c1ce TAR for these variants.

In the guest, launch the bundle through the existing Cinnamon session and actual scenario. While its process is alive, invoke the read-only loaded-engine script. It requires `/proc/PID/exe` to be the selected bundle executable, exactly one mapped engine path, a non-deleted engine library in that bundle, and matching engine and AOT hashes. It saves loaded ELF Build ID information and accessibility library mappings. Main-binary loading and the supported process path remain the dependency gate; standalone plugin `ldd` reports can contain symbols supplied by the main process.

The workflow should always upload compact logs, XML, manifests, hashes, diffs, and loader evidence separately from full engine/app artifacts and videos. A pass in native compilation or artifact equality cannot substitute for the real SCREEN/WINDOW geometry, widget teardown, accessible descendants, hit-testing, supported keyboard/Text/Paste, and combined A+B checks required by the accepted experiment plan.
