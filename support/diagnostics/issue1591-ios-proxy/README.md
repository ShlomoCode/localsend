# Issue 1591 iOS byte proxy

This standalone diagnostic app connects a Windows TCP relay to an unmodified LocalSend app on the same physical iPad. It forwards opaque TCP bytes to `127.0.0.1:53317`. TLS negotiation, client certificates, protocol requests, receive decisions, and saving remain in the actual LocalSend applications.

The helper uses an ordinary UIKit app, `URLSession`, and `NWConnection`. Its source-defined Info.plist permits HTTP only for the exact `bs-local.com` diagnostic relay hostname, without subdomains or a global ATS exception. The helper has no Photos permission or background modes. It requests a finite `UIApplication.beginBackgroundTask` budget before the operator switches to LocalSend. iOS controls that budget and can suspend or expire the helper. An expired or stalled helper is a transport failure, not a LocalSend reproduction.

## Build and install

Dispatch `issue1591-ios-proxy.yml` only in `ShlomoCode/localsend`. Its single macOS job uses Xcode 16.2 and XcodeGen 2.44.1. It retains the source commit, runner and tool versions, generator download SHA-256, build log, and IPA SHA-256 in `issue1591-ios-proxy-RUN_ID`. The generator release version is pinned; the artifact hash records provenance but is not a preconfigured integrity check.

Upload `Issue1591ByteProxy.ipa` through BrowserStack normal app upload and re-signing. Install it as an additional app with the unmodified LocalSend artifact. The helper bundle identifier is `org.shlomocode.diagnostics.issue1591.byteproxy`. Building an unsigned device application and packaging its built bundle as an IPA do not modify LocalSend or rewrite a built executable.

## Run the relay

Use the matching acknowledged Node relay with a private random bearer token. Expose its HTTP port through BrowserStack Local. The relay origin must have only a scheme, host, and optional port. Use `http://bs-local.com:8080` for the configured HTTP exception. The helper accepts other HTTPS origins under normal ATS requirements; its configuration does not exempt other HTTP hostnames or IP-address URLs.

Apple documents that on iOS 10 and later, the presence of `NSAllowsLocalNetworking` causes `NSAllowsArbitraryLoads` to be ignored and its default `NO` value to apply. The former combination therefore failed before polling with `NSURLErrorDomain -1022` in cloud trial 38180108492. The replacement uses the supported `NSExceptionDomains` dictionary and `NSExceptionAllowsInsecureHTTPLoads` for the exact hostname. This affects only the outer URLSession relay connection. The opaque LocalSend TCP/TLS stream and its certificates remain unchanged. See Apple's [global ATS key behavior](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads), [domain matching rules](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains), and [HTTP exception semantics](https://developer.apple.com/documentation/bundleresources/information-property-list/nsexceptionallowsinsecurehttploads).

1. Open the helper and fill **Relay origin** and **Relay token**. Their accessibility identifiers are `relayURL` and `relayToken`.
2. Select **Start proxy** (`startProxy`) while the helper is in the foreground.
3. Confirm `started` and `health-posted` appear in the log, the relay retains the initial `/health` sample, and a `/pull` request is pending.
4. Switch to LocalSend using the normal device interaction. Record the helper background transition and remaining budget in the device log.
5. In the real Windows app, select the files and send to the relay TCP endpoint. Perform the real approval and save actions in LocalSend on the iPad.
6. Preserve the device log and relay status/trace. Verify the received file separately against the source. If the helper expires or stops, stop the sender and relay, record a transport failure, and repeat with a fresh helper start.
7. Return to the helper and select **Stop proxy** (`stopProxy`). Stop the Node relay to close any remaining Windows peer sockets.

Official app launch arguments can prefill the same fields: `--relay-url ORIGIN --relay-token TOKEN --start-proxy`. Prefer the secure input field when the test service records capabilities or command arguments. The helper itself does not log tokens, URLs, or payloads.

## Transport and logs

The helper long-polls `GET /pull` and consumes ordered events `{seq, id, kind, data?}`. Each sequence number must increase within the batch and exceed the last acknowledged sequence in the current helper generation. `open` creates one plain TCP connection; `data` decodes base64 and forwards those bytes; `eof` closes only the sender direction; `close` or `error` cancels that connection. After every event in a nonempty batch has completed, the helper sends `POST /ack` with `{seq: LAST_SEQUENCE}`. The relay retains the batch until that exact final sequence is acknowledged. The helper waits for local send completion callbacks before acknowledging a batch; this establishes local socket acceptance, not application save completion.

Returned bytes are base64 encoded in `POST /push` events with `kind: data`, followed by `eof` or `error`. Both EOF directions complete the connection. Each local read waits for the corresponding POST response before requesting another read, limiting pending device-to-relay data.

Relay failures stop the helper rather than retry an ambiguous POST and duplicate bytes. A failed poll or acknowledgment invalidates the trial; the helper does not retry a partially consumed batch or an ambiguous acknowledgment. Stopping or background expiry immediately cancels local connections and requests; the controller must stop the relay to close its remote sender sockets. No claim is made that an expiry callback can complete network cleanup before iOS suspends the process.

`NSLog` and the `proxyLog` UI emit elapsed monotonic seconds, `backgroundTimeRemaining`, lifecycle transitions, expiration, connection IDs, and byte counts. Error logs use only NSError domain/code. The UI retains a bounded suffix; collect the device log for the full record. A surviving TLS handshake or equal transport byte counts alone does not prove that LocalSend saved the file.

The helper also sends authenticated `POST /health` samples through the same ephemeral URLSession. The first sample follows Start; later samples occur about once a second while running. Each request finishes before the next sample, so slow responses reduce frequency without accumulating requests. A health request failure stops the helper and invalidates the transport trial.

Each JSON sample contains `pid`, `elapsedSeconds` (monotonic), `generation` (one UUID per Start), `applicationState`, `budgetState`, `remainingBudgetSeconds` (present only for a finite budget), `running`, and `peers`. Each peer summary contains `id`, `ready`, `toLocalSendBytes`, `fromLocalSendBytes`, `inputEOF`, and `outputEOF`. `budgetState` is `finite` or `foreground-unbounded`; the latter represents the foreground sentinel rather than a duration guarantee. The controller must retain server receive timestamps and show samples with a finite budget through the actual LocalSend Accept/save interval. The payload contains no token, relay URL, or forwarded bytes. No terminal health POST is promised during background expiry.

## Validation boundary

The source has received direct inspection only. No local build, test, application, or reproduction was run. The first cloud build must establish compiler and IPA compatibility. The first physical-device control must establish loopback access, background duration, unchanged TLS transfer, and real application save behavior. Keep those results separate from any media-save defect.
