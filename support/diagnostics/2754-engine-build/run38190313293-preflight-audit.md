# Independent retained-evidence audit: run 38190313293

Audit scope: static reads, directory inventory, comparisons and SHA-256 hashes only. No source edits, application launch, build, test, syntax execution, reproduction, inferior, VM, network request, cloud dispatch or retry was performed by this audit.

## Finding

The authorized run stopped at the host symbol-preparation gate, on the first AT-SPI debug-package download. This is a preflight infrastructure failure. It supplies no fresh application, accessibility, UI, Name-transport, debugger-inferior or video observation.

The compact and full `comparison/` trees compare byte-for-byte equal. Both retain only AB-package selection metadata, resources, host-symbol download records, the incomplete symbol result and the scenario/suite exit statuses. Full evidence does not contain hidden guest captures omitted by the compact filter.

## Exact boundary

`comparison/AB-package/root-name-symbols-host/records/atspi-url.txt` starts with:

`https://ddebs.ubuntu.com/pool/main/a/at-spi2-core/libatspi2.0-0t64-dbgsym_2.52.0-1build1_amd64.ddeb`

The matching download record reports `http_code=301`, `size_download=194`, an effective URL with the same host/path but `http://`, and `curl_exit_status=1`. Its stderr says `curl: (1) Protocol "http" not supported or disabled in libcurl`.

At checked diagnostic source HEAD `79dabd46203e74b2edcbd2318f780004d3bd1bf2`, `prepare-root-name-symbols-host.sh:44` requests `--proto =https` and `--proto-redir =https`. Line 52 requires status zero before archive SHA verification, package identity checks, extraction, build-ID checks and transfer-manifest insertion. The first call is AT-SPI at lines 70–74; D-Bus staging and static GDB type qualification follow at lines 75–83. Therefore the failed HTTPS-to-HTTP redirect stopped processing before those later gates. The retained transfer manifest has only its header; there is no staged required-symbol row, checksum manifest or type-gate evidence. Neither static GDB qualification nor GDB attachment/inferior observation was reached.

`2754-mint-vm.sh:74–83` calls host preparation and exits on its nonzero status before ISO downloading (`:85`), seed creation and QEMU launch. The host preparation result explicitly remains `{"status":"incomplete","reason":"Host symbol preparation did not finish; no VM/UI may start."}`; both preparation status files report 1. Scenario and suite status files also report 1. Host prerequisite installation can have run; these are not guest/UI observations.

## Scope and completed gates

Dispatch metadata records one workflow_dispatch, run `38190313293`, branch `codex/diagnose-2754-text-freeze`, head `79dabd46203e74b2edcbd2318f780004d3bd1bf2`, source commit `47b58a9b44ae8e28ccd27bc6b8b18ccb687e967f`, stage `packaged-comparison`, accepted app run `38164164206`, and root-name/interactions inputs enabled. Authorization is explicitly `ONE cloud diagnostic; no automatic rerun`.

Although the workflow step title mentions control/B/AB comparison, root-name mode reduces the script labels to AB-package. The actual capture-scope file confirms `selected_cohorts=AB-package`; selection JSON specifies engine B, bridge A, package delivery, and post-timing observer scope. This run was not a new completed three-cohort matrix.

The official source-package A build completed. `package/build/result.txt` reports exit zero; its gates assert official source checksums, quilt source patch, unchanged official packaging and full binary build. The build-log tail includes normal dpkg packaging and completion. Candidate identity is `libatk-bridge2.0-0t64`, version `2.52.0-1build1+localsend2754.1`, source `2.52.0-1build1`, variant A. Independently hashed retained full-artifact files match candidate SHA256SUMS:

- package SHA-256: `360a39960307bc149a17f2acfba5812b332b0710121e857dbc4bf76173f8392b`
- manifest SHA-256: `e9e55e81b864e10a45ea4bf840fdfc255e1b71d8e7587d2e9fcab7798544c2b8`
- recorded bridge SHA-256: `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297`
- A patch SHA-256: `d4348bcd7197e837b03004f7e80ca6dc69b4bee8cd81ea35dba94dd37424f01d`

Build success does not establish guest installation or loaded runtime identity; neither guest gate ran.

## Accepted application provenance

The run retains `package/app-run.json` showing accepted application run `38164164206` completed successfully. Static inspection of retained accepted bundle artifacts under `/tmp/2754-accepted-app-evidence` confirms both variants have compilation-completed/pass validation, zero Flutter/build exit status, app-build run `38164164206`, original engine run `38153341418`, LocalSend commit `c1ce322fb3acf08e44f329b8b7208b8b0d91e244`, engine commit `42d3d75a56efe1a2e9902f52dc8006099c45d937` and framework commit `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694`. Original engine manifests are retained at `provenance/shader-inputs/original-engine-manifest.json`, distinct from augmented app manifests.

Independent bundle archive hashes match the accepted manifests and archive checksum files:

- control bundle: `7370c93ee6074881d6b35b924d56d7ec95ba0deb34a9ea32aec1f7533338e32e`; recorded engine SO `a5d59efac8589f609dd783a6c3b35b314b1bc0a9b0ac023af23321f7f50b21ff`
- B bundle: `1fa3fb6808e47c6259031c52b6c49c05d241fd6475431aefb577556cd454922d`; recorded engine SO `1cb9ec7c0516575ef5cdcd452a5de53761680539e5f5d78db7c88a7bad254ab3`

`run-packaged-comparison.sh:13–23` requires bundle archive hashes, those app/engine provenance fields, compilation validation and candidate package hashes before creating the comparison selection later observed in this run. Thus the failure is downstream of accepted bundle/package input gates, not a replacement or invalidation of those artifacts.

## Interpretation limits

No fresh VM/UI, public accessibility client call, root Properties.Get wire capture, Name request/reply identity, pending-call state, transport decode, GDB inferior stack or recording/video was produced by this run. Evidence absence here means the observer never reached the application. It must not be described as an absent Name reply, an unmatched Name call, a confirmed deadlock, a freeze, a latency result, or an A/B application regression. Earlier runs retain their separate evidentiary status; this run adds only the symbol-host preflight failure and successful package-build records.

The reported protocol error is consistent with enforced HTTPS-only redirects; it does not establish that libcurl generally lacks HTTP support. No alternative endpoint qualification was duplicated by this audit.
