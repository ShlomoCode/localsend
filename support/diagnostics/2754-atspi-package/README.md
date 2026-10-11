# Build the issue 2754 AT-SPI bridge package

`build-package.sh OUTPUT_DIR` prepares a diagnostic Debian package from the official Ubuntu Noble `at-spi2-core` source, version `2.52.0-1build1`. Run it only in a GitHub-hosted Ubuntu 24.04 amd64 Actions job in `ShlomoCode/localsend`. The script does not install the resulting package or launch LocalSend. Use a fresh `OUTPUT_DIR` and retain it as an Actions artifact even when the build fails.

The script verifies SHA-256 hashes of the official `.dsc`, upstream archive, and Debian archive, then extracts them with `dpkg-source --no-check-signature -x`. The independent hash pins supply source identity; this command does not claim OpenPGP signature verification. It adds the checksum-pinned `2754-atspi-native/A-local-dispatch.patch` to the distribution's quilt patch series and uses `dch` to set version `2.52.0-1build1+localsend2754.1`. It preserves the official `debian/control` and `debian/rules` and invokes `dpkg-buildpackage -us -uc -b` with its normal documentation, introspection, and Xvfb/D-Bus test stages. The native fixtures in patch A join the normal Meson test suite. Build or test failures stop the script.

## Install build prerequisites in Actions

The following list comes from the official Noble `debian/control`, including architecture-independent documentation and test dependencies. `build-essential`, `devscripts`, `quilt`, `curl`, `ca-certificates`, `binutils`, and `jq` support the helper itself. `dpkg-checkbuilddeps` checks the extracted control file before the build; missing or incompatible dependencies fail visibly. Installing these prerequisites belongs in the cloud workflow, before invoking the script:

```bash
sudo apt-get update
sudo apt-get install --yes --no-install-recommends \
  build-essential dpkg-dev debhelper-compat devscripts quilt curl ca-certificates binutils jq \
  dbus libdbus-1-dev dbus-broker libsystemd-dev libglib2.0-dev libxml2-dev \
  libx11-dev libxtst-dev meson pkgconf gtk-doc-tools gi-docgen python3-sphinx \
  gir1.2-dbus-1.0-dev gir1.2-glib-2.0-dev gir1.2-gobject-2.0-dev gobject-introspection \
  xauth xvfb at-spi2-core docbook-xml libglib2.0-doc libglib2.0-dev-bin
bash support/diagnostics/2754-atspi-package/build-package.sh "$RUNNER_TEMP/atspi-package"
```

Do not set `nocheck`, `nodoc`, build profiles, or loader overrides. The baseline runner must have `libatk1.0-0t64`, `libatk-bridge2.0-0t64`, and `libatspi2.0-0t64` at `2.52.0-1build1`; the helper checks this before building. The full source package produces other `.deb` and `.udeb` files for evidence, but the later Mint 22.2 experiment targets only the bridge package named in `target-deb.txt`.

## Retain and verify the result

Retain `official-source/`, `debian-official/`, `debian-final/`, `A-local-dispatch.patch`, source hashes, `package-build.log`, and `result.txt`. `work/` retains the extracted source and build tree, including logs if a build fails. `artifacts/` contains the source `.dsc` and archives, binary `.deb`/`.udeb` files, `.buildinfo`, and `.changes`. `artifacts.sha256` covers each retained product; `debs.sha256` covers each `.deb`. `metadata/` records every `.deb` control fields and contents, baseline package identities, bridge ELF metadata, and the runner's simulated apt plan. The runner's plan is supplementary: the Mint guest needs its own plan.

Copy only `candidate/` to the guest's `/home/mint/bridge-package` for installation. It contains one bridge `.deb`, `SHA256SUMS` (the `.deb` and manifest hashes), and `manifest.json`. The manifest fields are `package_name`, `package_version`, `deb_sha256`, `bridge_path` (the canonical installed library path), `bridge_sha256`, `variant` (`A`), `source_version` (`2.52.0-1build1`), and `patch_sha256`. All other build products remain in `artifacts/` for evidence.

For the later Mint guest gate:

1. Record the baseline installed package versions, dependency state, package file ownership, and mapped bridge library path/hash from the real LocalSend process. Preserve the unchanged strict geometry checks and baseline control.
2. Verify the target `.deb` against `debs.sha256` and its package/version/architecture fields. Simulate `apt-get --no-install-recommends install /ABSOLUTE/PATH/TO/TARGET.deb` inside the guest. Require that the plan upgrades only `libatk-bridge2.0-0t64`; any additional required package change needs an explicit recorded dependency justification and an equivalent baseline control before continuing. Do not install all generated packages.
3. Install the selected `.deb` through apt's normal install path. Record apt output, installed control fields, and `dpkg -V libatk-bridge2.0-0t64`. Compare the installed canonical bridge path/hash and its ownership to the extracted target package and `target-library.sha256`.
4. Restart LocalSend normally and record `/proc/PID/maps`. Require that its mapped bridge is the installed package library, with the expected hash/build ID. Run the same real UI/AT-SPI geometry scenario without `LD_LIBRARY_PATH`, `LD_PRELOAD`, or binary replacement.

A successful package build establishes the supported source and packaging path. The guest installation, process maps, and unchanged baseline/candidate experiment establish whether that package fixes the reported behavior.
