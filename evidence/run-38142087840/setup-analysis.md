# Debian swap CLI compatibility failure

Run 38142087840 ended at `guest-runtime-preflight`, exit code 1, before desktop launch or any app workload. The explicit `/sbin/swapon` resolved correctly, but Debian util-linux 2.38.1 does not support the newer `--output=NAME` selector: it reports `option '--output-all' doesn't allow an argument`.

The environment and kernel retain active ordinary disk swap with the expected 2 GiB allocation. This is diagnostic CLI compatibility, not application behavior. The corrected selector uses the established `--show=NAME` and `--show=SIZE` forms, and retains `swapon --help` from the actual guest before the invariant gates. No experiment condition or UI action changes.
