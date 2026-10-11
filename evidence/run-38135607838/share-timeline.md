# Original 1.18.2 native Share

The exact 16,000,000,000-byte fixture eventually reached Selection and responded to actual Manual address entry and Cancel. The preparation included a prolonged black display and six accessibility-source timeouts. No visible ANR or Wait was observed. This is a supplemental Share condition: the reporter's original picker route remains unknown, and the fixture is a valid one-second 320x240 MP4 padded with a legal free box.

Raw evidence is under `windows-transfer/share-scenario/`: `large-share-warm-result.json`, `large-fixture.json`, `large-staging-result.json`, `large-share-warm-selected-before-input.png/xml`, `large-share-warm-manual-cancel-9-typed.png/xml`, and `large-share-warm-manual-cancel-9-dismissed.png/xml`. Source-unavailable black samples are `large-share-warm-observe-001` through `006`, with foreground/error JSON. `windows-transfer/wd-commands.jsonl` preserves request timestamps and duration. The source video is `session.mp4` (1309.367944s, h264, 800x800, 60fps); native logcat JSON and `device-logs-redacted.log` preserve provider records.

| Clock | Event |
| --- | --- |
| Controller UTC 11:35:25.256 | Observed native chooser LocalSend target input |
| Device 11:35:29.271 | FileDirectory logs exact owned 16GB filename, PID 12751 |
| Controller UTC 11:37:41.503–41.962 | Screenshot for observe-007; it precedes source recovery |
| Controller UTC 11:37:42.321–57.953 | Source request returns Selection after 15,632ms |
| Controller UTC 11:37:57.956–58.139 | Fresh source confirms Selection |
| Controller UTC 11:37:58.140–58.545 | Fresh selected-before-input PNG captures visible Selection |
| Controller UTC 11:37:58.657–58.856 | Actual observed Manual sending input |
| Controller UTC 11:38:04.554–04.624 | Source returns actual Enter address dialog |
| Source video (387.50, 387.75]s | Chooser disappears; dimmed helper is visible |
| Source video (393.00, 393.25]s | Transition from dimmed helper to black display |
| Source video (535.75, 536.00]s | First visible Selection 16.0GB after black display |
| Source video (540.50, 540.75]s | First visible Enter address |
| Source video (546.50, 546.75]s | First visible typed 127.0.0.1 with keyboard |
| Source video (548.00, 548.25]s | Dialog disappears; Selection retained after Cancel |

Video/controller/device clocks remain separate. The command sequence establishes Selection roughly 152.7s after chooser input. Video independently places recovery about 148.25s after chooser disappearance, including about 142.75s of black display. Screenshot and source within an observation are not atomic: observe-007 has black pixels from an earlier time and Selection XML from the later successful source response.

The 900,953ms observation contains 133 records and six source timeouts. Focused package/activity reads remain `org.localsend.localsend_app/.MainActivity` during those timeouts. Both 1MiB and 64MiB Share controls also established Selection and actual Manual input/Cancel. Native logs use brief format with PID only, so runtime TID/main-thread execution is unproven. CPU, native stacks and private-cache byte-growth remain unavailable through established ordinary APIs. No permissions, production app or provider configuration was changed.

The exact APK source/runtime seam supports a native cache-copy lead, but neither progress during the blank interval nor the reporter's repeated Wait/transfer ANR has been established. PR3395's existing native URI path is a candidate causal comparison with author credit, not a validated correction for the original report.
