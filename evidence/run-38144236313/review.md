# Owned nonloopback IPv4 transport discriminator

Run [38144236313](https://github.com/ShlomoCode/localsend/actions/runs/38144236313), head `9c2413e6`, passed cloud helper compilation and Node syntax checks. It launched only the separate synthetic transport helper on Samsung S20 / Android 10; no LocalSend app or large file transfer ran.

Windows adapter inventory selected the only candidate: Ethernet 4, interface index 15, `10.1.0.185/20`, gateway `10.1.0.1`, status Up. Both actual listeners bound `10.1.0.185`, HTTP port 8080 and TCP port 53317. Adapter selection and listener addresses are independently retained in `adapter-selection.json` and `results.json`.

The HTTP control to that exact address passed the fresh marker. Native resolution of the literal address returned the same address. The Java Socket connection to `10.1.0.185:53317`, reported source `10.0.0.7`, failed at `native-connect-start` with SocketTimeoutException. Device timestamps show a 10,009 ms connect interval. Runner cases are empty: no byte payload, half-close or hash case completed. This establishes failure of this chosen owned-private-address route in this Local/forceLocal profile; it is not a verdict on every TCP topology or OS.

I independently viewed `after.png`: its target, HTTP marker, literal DNS result and connection timeout match the native result JSON. This is infrastructure evidence and does not add to the four accepted product conditions.

Cleanup errors are empty. The actual Local process exit event records PID 1696, exit code null, signal SIGTERM, UTC 13:43:39.310; `exited=true`. This confirms that signal termination can legitimately leave exitCode null and explains why the earlier controller could falsely report a live process. The controller trace retains the owned session DELETE, and a subsequent ordinary provider final-state read is preserved separately; no cleanup app trial was needed.

The authorized next route improves only the diagnostic helper/relay. It must preserve opaque application bytes, TLS identity, order and EOF, prove reverse data while upload is still open, backpressure and peer cancellation/isolation, and then repeat the original-app 64 MiB Accept/save/hash/Finished gate. No 16 GB network transfer is authorized by this negative discriminator alone.
