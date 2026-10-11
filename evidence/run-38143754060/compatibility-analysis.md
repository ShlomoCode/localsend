# Debian tools compatibility qualification

Run 38143754060 completed successfully in a Debian 12 container as a non-login probe user, without executing LocalSend. util-linux is 2.38.1 and glibc is 2.36. The exact shared preflight script accepted `swapon --show=NAME` and `--show=SIZE --bytes`, explicit `/sbin` paths, `stat --format`, `getconf PAGESIZE`, `findmnt` and the inventory/readelf commands. The actual static ABI traversal retained 92 bundle/provider ELF records and no failures.

The actual receiver driver sampled an ordinary sleep process four times, with all proc/status/vmstat/PSI strings readable and unchanged start time. Reads took 0.532–0.622 milliseconds. Its stage reader retained valid RSS, PSS, Swap and SwapPss fields, with the PSS read taking 0.206 milliseconds. These costs qualify the readers in this container; they do not predict cost in the smaller VM.

CLI help parsing qualified journalctl and cloud-init flags. Runtime status was retained explicitly: journalctl returned zero with no entries; cloud-init returned zero with status not run. Neither result qualifies a booted VM or absence of OOM. This evidence also motivates requiring timestamped kernel entries, not merely a zero journalctl exit, in the guest's journal evidence gate.

The container shares the host kernel and verifies no swap activation, minimum RAM, graphical desktop, discovery, application interaction or save. Its zero-byte `/swap.img` is only a pathname fixture for the shared findmnt/stat calls, never formatted or activated. VM mode still requires the real 2 GiB allocation and active disk swap. No experiment condition changed. The same verified shared preflight file is now ready for VM reuse before the mandatory full five-file app control.
