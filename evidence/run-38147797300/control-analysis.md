# Five-file Options observed; control save not yet qualified

Run: https://github.com/ShlomoCode/localsend/actions/runs/38147797300
Head: 3de6ab80cabb1df5da41ca2a6c4e4ce73fdc3aaf. The job completed; no larger case ran.

Both windows have measured 1000x700 geometry at X=2,Y=40. Real folder selection, five-file metadata approval, Options appearance and Back to approval succeeded. Initial and held list observations are true. The host wrapper hold is 10.273573 seconds; actual guest PSS stages occur 1.952508, 5.947235 and 10.966448 seconds after input initiation. The nominal ten-second hold starts after the click wrapper, so it is not a ten-second deadline measured from input.

The run stops at `control-save` with `Accept button not observed after Back`, before clicking Accept. The raw Back frame visibly contains normal Accept and Decline buttons at the established bounds. Full-frame OCR misses them; the previous whole-button crop includes the icon and rounded border and returns unrelated tokens. Offline label-only crops from the same raw frame recognize exact Accept (96.261574 confidence, 60x24 at 558,658) and Decline (96.337891, 66x24 at 420,658). Retained crops/TSVs are in `offline-ocr/`; no local application workload was executed.

Receiver PID4596/starttime8409 and sampler remain alive, with 56 baseline and 89 post-hold valid samples and no read errors. Options-stage PSS is 201294, 203890 and 205071 KiB; process Swap is zero. Kernel baseline/final reads succeed and contain no OOM/victim events. Exit -15 is explicitly harness cleanup. These facts qualify only a partial five-file control; they do not qualify saving, both Finished screens, 500/5000-file behavior, or a reproduction of the reported failure.

Independent read-only GUI audit found no further proven blocker in folder selection, Save/Finished, Back or cleanup. Decline remains unexecuted in this harness. Its strict exact-label gate and cancellation/home/no-save predicates remain mandatory. The fixed Options input is verified by current retained approval pixels; delayed metadata would remain an unknown UI observation outcome. No extra OCR is inserted into the approved metadata/Options measured interval. Timing reporting now retains guest offsets and the held capture offset from input explicitly.
