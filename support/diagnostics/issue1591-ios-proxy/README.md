# Issue 1591 iOS byte proxy

This standalone diagnostic app connects a Windows TCP relay to an unmodified LocalSend app on the same physical iPad. It forwards opaque TCP bytes to `127.0.0.1:53317`. TLS negotiation, client certificates, protocol requests, receive decisions, and saving remain in the actual LocalSend applications.

The helper uses an ordinary UIKit app, `URLSession`, and `NWConnection`. Its source-defined Info.plist permits HTTP for the private diagnostic relay. The helper has no Photos permission or background modes. It requests a finite `UIApplication.beginBackgroundTask` budget before the operator switches to LocalSend. iOS controls that budget and can suspend or expire the helper. An expired or stalled helper is a transport failure, not a LocalSend reproduction.

## Build and install

Dispatch `issue1591-ios-proxy.yml` only in `ShlomoCode/localsend`. Its single macOS job uses Xcode 16.2 and XcodeGen 2.44.1. It retains the source commit, runner and tool versions, generator download SHA-256, build log, and IPA SHA-256 in `issue1591-ios-proxy-RUN_ID`. The generator release version is pinned; the artifact hash records provenance but is not a preconfigured integrity check.

Upload `Issue1591ByteProxy.ipa` through BrowserStack normal app upload and re-signing. Install it as an additional app with the unmodified LocalSend artifact. The helper bundle identifier is `org.shlomocode.diagnostics.issue1591.byteproxy`. Building an unsigned device application and packaging its built bundle as an IPA do not modify LocalSend or rewrite a built executable.

## Run the relay

Use the retained `android-relay.mjs` Node relay with a private random bearer token. Expose its HTTP port through BrowserStack Local. The relay origin must have only a scheme, host, and optional port, for example `http://bs-local.com:8080`. The helper accepts HTTP or HTTPS origins.

1. Open the helper and fill **Relay origin** and **Relay token**. Their accessibility identifiers are `relayURL` and `relayToken`.
2. Select **Start proxy** (`startProxy`) while the helper is in the foreground.
3. Confirm `started` appears in the log and the relay reports a pending `/pull` request.
4. Switch to LocalSend using the normal device interaction. Record the helper background transition and remaining budget in the device log.
5. In the real Windows app, select the files and send to the relay TCP endpoint. Perform the real approval and save actions in LocalSend on the iPad.
6. Preserve the device log and relay status/trace. Verify the received file separately against the source. If the helper expires or stops, stop the sender and relay, record a transport failure, and repeat with a fresh helper start.
7. Return to the helper and select **Stop proxy** (`stopProxy`). Stop the Node relay to close any remaining Windows peer sockets.

Official app launch arguments can prefill the same fields: `--relay-url ORIGIN --relay-token TOKEN --start-proxy`. Prefer the secure input field when the test service records capabilities or command arguments. The helper itself does not log tokens, URLs, or payloads.

## Transport and logs

The helper long-polls `GET /pull` and consumes ordered events `{id, kind, data?}`. `open` creates one plain TCP connection; `data` decodes base64 and forwards those bytes; `eof` closes only the sender direction; `close` or `error` cancels that connection. Returned bytes are base64 encoded in `POST /push` events with `kind: data`, followed by `eof` or `error`. Both EOF directions complete the connection. Each local read waits for the corresponding POST response before requesting another read, limiting pending device-to-relay data.

Relay failures stop the helper rather than retry an ambiguous POST and duplicate bytes. The existing relay dequeues pull events without acknowledgments, so a disconnected poll can lose events. Treat a failed poll as a failed trial. Stopping or background expiry immediately cancels local connections and requests; the controller must stop the relay to close its remote sender sockets. No claim is made that an expiry callback can complete network cleanup before iOS suspends the process.

`NSLog` and the `proxyLog` UI emit elapsed monotonic seconds, `backgroundTimeRemaining`, lifecycle transitions, expiration, connection IDs, and byte counts. Error logs use only NSError domain/code. The UI retains a bounded suffix; collect the device log for the full record. A surviving TLS handshake or equal transport byte counts alone does not prove that LocalSend saved the file.

## Validation boundary

The source has received direct inspection only. No local build, test, application, or reproduction was run. The first cloud build must establish compiler and IPA compatibility. The first physical-device control must establish loopback access, background duration, unchanged TLS transfer, and real application save behavior. Keep those results separate from any media-save defect.
