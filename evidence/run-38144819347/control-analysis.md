# Receiver readiness OCR failure

Run 38144819347 passed the guest preflight, active fixed swap assertions, static ABI traversal and desktop startup, then launched the genuine release receiver. It stopped before launching the sender or selecting a folder because full-frame OCR omitted the small Receive and Send sidebar labels.

Direct inspection of `final/vm/guest/files-5-receiver-ready-0.png` shows Receiver2414, Receive, Send and the Quick Save Off control on a rendered normal home page. Its full-frame TSV recognizes Receiver2414 but omits Receive and Send. Focused offline processing of those actual pixels at `(70,125,110,35)` and `(70,170,110,35)`, with 4x enlargement and PSM 7, recognizes the exact labels at confidences 95.825 and 95.588. The final retained readiness frame, `files-5-receiver-ready-18.png`, yields the same exact labels and confidences through the same crops. Raw crops/TSV are retained in `offline-ocr/`; no app or build executed locally.

The harness correction supplements full-frame OCR only when the actual Receiver2414 home identity is observed, and requires the literal labels in their retained bounds. It preserves the existing Receive/Send/alias gate rather than replacing it with input coordinates or a weaker predicate. The same fallback serves normal post-Decline home observation, outside the measured Options interval.

Receiver PID 4504 and start time 9139 ticks remain alive at failure, as does its sampler. Complete kernel reads succeed and retain no OOM event since the successful baseline read. The recorded −15 exit is explicitly preceded by harness stop and SIGTERM; no forced kill occurred. This is a readiness observation failure, not an app crash, hang, Options result or passing five-file transfer control. No large case started.
