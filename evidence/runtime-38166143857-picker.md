# Exact source pair: folder-name OCR failure

Run https://github.com/ShlomoCode/localsend/actions/runs/38166143857 successfully started both receiver and sender applications in both variants. Logs show isolate initialization, HTTPS server startup and mutual discovery. It stopped in the real GTK directory picker before metadata approval, five-file save or any 5,000-file measurement.

Actual retained parent picker frame `files-5-folder-row-26.png` visibly contains the correct directory `Case2414Files5Flat`. Its retained OCR TSV recognizes `Case2414FilesSFlat`. The exact-label predicate therefore never matched. This is an observation failure, not a missing directory or product reproduction.

The source-pair-only correction enters the exact absolute fixture path through GTK's ordinary Ctrl+L location field and Return, retains the selection frame, and uses the visible Open action. Application selection, metadata count, manual approval and full five-file byte/hash checks remain mandatory. Historical release UI flow remains unchanged. No app bytes or measured resource conditions change.

Raw evidence is retained under `.a5c/localsend-sprint/recovered/2414/runtime-38166143857/`. Setup failures do not increase the substantive-condition count.
