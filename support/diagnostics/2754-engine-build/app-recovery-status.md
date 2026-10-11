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
