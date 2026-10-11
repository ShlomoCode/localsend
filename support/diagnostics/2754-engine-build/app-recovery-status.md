# Issue 2754 app recovery and next comparison

The reported environment is Mint 22.2, kernel 6.8.0-85, official LocalSend 1.17.0 DEB. Current-source comparisons are discriminating experiments; they do not replace that baseline.

App-only run [38164164206](https://github.com/ShlomoCode/localsend/actions/runs/38164164206) built complete control and B applications using the supported local-engine invocation. Both Flutter and log-capture statuses are zero, all observer gates passed, source status and diff are empty before/after, and lock hashes match. Local inspection verified each entire archive and every extracted file against retained SHA-256 lists. No local build, test or application ran.

| Variant | Artifact ID | Bundle SHA-256 | Engine SHA-256 |
|---|---|---|---|
| control | 11711782451 | 7370c93ee6074881d6b35b924d56d7ec95ba0deb34a9ea32aec1f7533338e32e | a5d59efac8589f609dd783a6c3b35b314b1bc0a9b0ac023af23321f7f50b21ff |
| B | 11711368558 | 1fa3fb6808e47c6259031c52b6c49c05d241fd6475431aefb577556cd454922d | 1cb9ec7c0516575ef5cdcd452a5de53761680539e5f5d78db7c88a7bad254ab3 |

Compact evidence artifact: 11711318726. Full evidence artifact: 11711149273. Downloaded evidence: `/tmp/2754-accepted-app-evidence`. The original engine run remains 38153341418; additive shader restoration descriptors link its unchanged archives and engine binaries. Exact CMake engine source, variant and host fields and x86-64 ELF identities are retained in each artifact.

Prepared next stage: `packaged-comparison`, `bundle_run_id=38164164206`. It builds A through pinned Ubuntu 2.52.0-1build1 source, quilt and unchanged Debian rules/tests, then runs three fresh Mint live sessions sequentially: control/system, B/system, A+B/package. The package case uses apt installation and verifies the plan, actual package delta, ownership and mapped library hash. No loader substitution is used in that case. File/Folder/Paste controls share the same application PID as repeated Text under the enabled keyboard. Each VM is stopped before reuse; PID start time and command line guard the TERM fallback.

The parent independently inspected both complete bundles and accepted them for diagnostic runtime use. The sequential package comparison was dispatched as [38165470861](https://github.com/ShlomoCode/localsend/actions/runs/38165470861), diagnostic head `1afaad9b`. The complete unmodified bundle descriptors were also sent to the issue 3161 investigator. Geometry, screen reader, editing, actions and lifecycle remain unproven by this build. The earlier public geometry timeout is a failure, not a pass. No PR or product-fix claim is authorized at this point.

A fresh read-only consumer audit inspected the actual raw app artifacts and pending comparison source. It found no bundle acceptance blocker or obvious remaining package/UI mismatch. It confirmed the package-delta, system bridge identity and owned-QEMU cleanup changes address its earlier findings. This audit did not execute the applications and cannot establish guest behavior.

## First normal-package Mint matrix

Run 38165470861 completed with failure because the new File observer misread the rendered native chooser's **Cancel** as `Can`. Independent visual inspection confirmed all three variants actually opened the **Open File** chooser; **Open** was recognized correctly. The observer aborted before Folder/repeated Text/geometry, so this run proves none of those later phases. The correction scopes OCR to the actual active native chooser button strip, requires exact full labels, clicks the observed Cancel coordinates, and still requires return to Selection. It does not globally accept `Can` or extend the timeout.

The normal source-package build ran all ten distribution/native tests, with zero failures or skips. The A candidate DEB SHA-256 is `5537a201255f8001f5b93a12eafda6aaa6a06a668f50772e2fabf50b6f2c8286`; bridge SHA-256 is `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297`. In Mint, apt planned and changed only the target bridge package; libatk/libatspi remained unchanged, dpkg verification was empty, ownership matched, and the actual app mapped that exact canonical bridge without loader overrides. All three app engine/AOT/bridge loader gates passed.

Compact artifact 11712003280 and full artifact 11712048182 are preserved locally at `/tmp/2754-packaged-compact` and `/tmp/2754-packaged-full`. HTTP 418 artifact downloads were retried successfully through the authorized SOCKS5 proxy.

The original 1280×800, 10-fps H.264 recordings were preserved. Aligned visual samples show the control Text dialog appearing about 25 seconds after the keyboard-on trigger, while A+B/package renders during the first second and contains the genuinely typed control. Exact frame-bound timing and repeated conditions remain to be completed; this early observation does not prove geometry, speech or a complete fix.

Prepared next run adds an opt-in post-geometry phase for public editing/action/lifecycle checks and real Orca backend/audio evidence. A fresh independent source review found and resolved asynchronous mutation-readback races, missing Send navigation after restart, event identity/lifetime gaps, cleanup deadlines and requested-phase failure propagation. It also reviewed the targeted File oracle correction. No remaining blocking source/API issue was found; compilation, OCR and real public-method behavior still require the cloud run. Speech/audio stay unknown until raw correlated evidence is inspected.

The next single sequential matrix is [38167982047](https://github.com/ShlomoCode/localsend/actions/runs/38167982047), diagnostic source head `4d24b6b4`, same accepted app run 38164164206, with `capture_interactions=true`. No concurrent job for this bug was dispatched.

Native 10-fps sampling around the first keyboard-on modal transition bounds the control and B fully rendered field at roughly 25.1 seconds after the recorded trigger. A+B/package renders within 0.3 seconds and shows progressively typed real control text. Review-derived continuous clips preserve the entire pause: `/tmp/2754-control-keyboard-on-continuous.mp4` is source interval 118–152 seconds (34 seconds), `/tmp/2754-AB-keyboard-on-continuous.mp4` is source interval 118–128 seconds (10 seconds). Both are 1280×800 H.264 at 10 fps, with no overlays, speed changes, stitched frames or hidden interval. Original wall-clock PTS recordings remain untouched. These first-trigger observations do not establish repeated control, geometry or interaction success.
