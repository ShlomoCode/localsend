# Diagnostic transport helper

This separate helper carries opaque TCP bytes between a cloud runner and an unmodified LocalSend app. Its controls validate the diagnostic transport. They do not reproduce a LocalSend bug or prove a transfer between two original apps.

## Android 15 button layout

With target SDK 35, the default ActionBar covered the `Start socket control` button on Pixel 9 running Android 15. Appium could find the button, but its tap did not start the service. The device log contained no `service-start` event.

`MainActivity` now hides the ActionBar, applies the system top and bottom insets to the layout, and requests those insets after attaching the view. These layout changes match the helper source tested in diagnostic commit `6c171bc0`. The common helper retains its additional `Relay from LocalSend` button and the existing service and transport behavior.

[Run 38105250033](https://github.com/ShlomoCode/localsend/actions/runs/38105250033) passed physical checksum and half-close controls for 0, 1, 65,537, and 8,388,608 bytes on Pixel 9 with Android 15. The run later failed because BrowserStack rejected a diagnostic `dumpsys` command. That failure does not invalidate the completed transport controls, but the run did not complete its original-app transfer scenario.

The button's `Socket control running` text appears when the activity requests a service start. Use service logs and a completed byte control to establish transport readiness; the text alone does not establish it.

## Evidence boundaries

- Forward physical controls passed on Vivo Y21 with Android 11 in [run 38102837570](https://github.com/ShlomoCode/localsend/actions/runs/38102837570), and on Pixel 9 with Android 15 in the run above.
- [Run 38104758667](https://github.com/ShlomoCode/localsend/actions/runs/38104758667), at common commit `187f39d1`, passed cloud controls for both directions, 2/10/30-second idle pauses, and a reverse 32 MiB transfer generated in 64 KiB chunks. It also compiled the reverse helper.
- Reverse transport has no physical-device proof yet. Its cloud controls do not establish Android storage behavior, a 16 GB transfer, or a transfer between original apps.
- HTTP failures and service shutdown can close transport sockets. Keep the monotonic relay trace and Android `CloudTransport` logs when attributing a connection close.

For reverse mode, start the desktop receiver on localhost port 53317, configure the relay with `reverseTargetPort: 53317`, and select `Relay from LocalSend` in the helper. The helper listens only on Android localhost port 53318. Use the original sender's UI to select that address and port. If another helper mode is running, select `Stop helper` first. Generate a fresh token and helper APK for each run; do not publish the APK containing the token.

The issue 3556 diagnostic clone imports common source from immutable commit `c458fa4dd3034b8a18c75d4fd3c72a5553838e05`. Its added `Run reverse byte control` action sends 0, 1 and 65,537 deterministic bytes through the physical Android listener, half-closes its output, and verifies a count/hash reply read through EOF. The Windows controller uses a temporary port 53317 test server before starting the actual receiver. This added probe is prepared but not yet validated on a device. Its results are transport evidence and cannot establish a LocalSend failure or a large transfer.
