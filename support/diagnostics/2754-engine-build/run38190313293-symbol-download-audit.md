# Run 38190313293: strict HTTPS symbol download audit

Source-only qualification completed on 2026-10-12. No repository files changed, applications launched, builds/tests run, debugger inferiors started, cloud workloads dispatched, or retries performed.

## Finding and exact proposal

Replace only the AT-SPI debug archive source URL with:

`https://launchpad.net/ubuntu/+source/at-spi2-core/2.52.0-1build1/+build/28034835/+files/libatspi2.0-0t64-dbgsym_2.52.0-1build1_amd64.ddeb`

Retain the D-Bus build-specific URL:

`https://launchpad.net/ubuntu/+source/dbus/1.14.10-4ubuntu4.1/+build/28726865/+files/libdbus-1-3-dbgsym_1.14.10-4ubuntu4.1_amd64.ddeb`

Both exact routes were fetched with `curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 40`. Each returned curl exit 0 and HTTP 200 after exactly one HTTPS redirect. Keep all pinned hashes, Build IDs, and pre-UI hard gates unchanged. A fresh review of the concrete source change is required before proposing another workload run; this audit does not authorize a run.

## Prior failure

Run 38190313293 stopped at the host symbol gate before the VM. Its AT-SPI record reported HTTP 301, curl exit 1, effective URL `http://ddebs.ubuntu.com/pool/main/a/at-spi2-core/libatspi2.0-0t64-dbgsym_2.52.0-1build1_amd64.ddeb`. The original HTTPS ddebs route downgraded to HTTP and was correctly refused. Prior qualification with unrestricted `curl -L` did not establish strict-policy compatibility.

Raw failure: `/tmp/2754-packaged-38190313293-compact/comparison/AB-package/root-name-symbols-host/records/atspi-download.txt`.

## Official publication evidence

The Launchpad `devel` getPublishedBinaries query for exact binary name `libatspi2.0-0t64-dbgsym`, version `2.52.0-1build1`, returned noble/amd64 Published publication `208196781`, mapped to source `at-spi2-core/2.52.0-1build1`, build `28034835`.

Raw query response: `/tmp/2754-atspi-publications.json`.

Supported operation `https://api.launchpad.net/devel/ubuntu/+archive/primary/+binarypub/208196781?ws.op=binaryFileUrls` returned `https://launchpad.net/ubuntu/+archive/primary/+files/libatspi2.0-0t64-dbgsym_2.52.0-1build1_amd64.ddeb`.

Raw operation response: `/tmp/2754-atspi-file-urls.json`. The proposed build-specific route anchors the download to the exact build represented by the publication.

## Complete redirect chains

AT-SPI: proposed build-specific HTTPS URL → HTTP 303 Location `https://launchpadlibrarian.net/723726435/libatspi2.0-0t64-dbgsym_2.52.0-1build1_amd64.ddeb` → HTTP 200, 229124 bytes. Full raw headers: `/tmp/2754-atspi-https-headers.txt`; package: `/tmp/2754-atspi-strict-https.ddeb`.

D-Bus: retained build-specific HTTPS URL → HTTP 303 Location `https://launchpadlibrarian.net/742976071/libdbus-1-3-dbgsym_1.14.10-4ubuntu4.1_amd64.ddeb` → HTTP 200, 417028 bytes. Full raw headers: `/tmp/2754-dbus-https-headers.txt`; package: `/tmp/2754-dbus-strict-https.ddeb`.

## Pinned identities verified

| Identity | AT-SPI | D-Bus |
| --- | --- | --- |
| Package SHA-256 | `6be64cf137f649471785d44e373e4fba5f6e79598ebca9289f8c13f9e7d4c16b` | `3ba3c5094950d8913a56267f4f8ff13fd3d1000af44b2bdd8678119abc0928fe` |
| Debug ELF SHA-256 | `dc8d6f0039246a3dd5d5602d8bf2b5b2f2c0dd89c7f86d916ae2c040dcd1afd9` | `f27ea06d661543a3452b4e0791fba4fc4d9c92a6075a0d8b9fd1894b550bc899` |
| GNU Build ID | `d53e3f4bf82655a42a0cb86c25416fd443ee76c6` | `47829078e4267099473c6cf5f5742f16ccb2644d` |

Packages were statically extracted with `ar -x` and `tar -xf data.tar.zst`; Build IDs inspected using `/opt/homebrew/opt/llvm/bin/llvm-readelf -n`. All six identities exactly match the prior pins. Readelf warned that debug-only ELFs have no valid dynamic table; it exited 0 and read the build-id notes successfully.

Extracted AT-SPI ELF: `/tmp/2754-strict-symbol-audit/atspi/usr/lib/debug/.build-id/d5/3e3f4bf82655a42a0cb86c25416fd443ee76c6.debug`.

Extracted D-Bus ELF: `/tmp/2754-strict-symbol-audit/dbus/usr/lib/debug/.build-id/47/829078e4267099473c6cf5f5742f16ccb2644d.debug`.

No download-policy relaxation, alternate package version, or symbol-identity changes are needed. This resolves the observed source-route blocker; it does not establish future network availability or runtime causal attribution.
