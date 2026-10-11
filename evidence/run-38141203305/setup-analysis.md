# Memory experiment setup failure

Run 38141203305 ended in `guest-runtime-preflight` with exit code 127, before desktop launch or any application workload. The script reports `bash: line 9: swapon: command not found` from the non-login SSH user's PATH. Debian's installed `util-linux` package is retained in the inventory as version 2.38.1-5+deb12u3.

The guest kernel confirms `Adding 2097148k swap on /swap.img` at monotonic 8.549453 seconds; final `free` reports 2047 MiB total swap. This is command resolution failure, not missing swap or an application OOM. The release and cloud image hash checks completed.

Correction: invoke `/sbin/swapon` explicitly in environment recording, invariant checks and final collection, matching the existing explicit `/sbin/ldconfig` path. RAM, CPUs, disk swap size, OS, release and UI actions remain identical. No app control or large-case observation from this run is accepted.
