# Issue 2414: substantive coverage and remaining distinctions

This is a decision packet, not a closure claim. The coordinator has not approved ending the investigation. No new probe, build, application workload or production change is authorized here.

## Exact original report

Source: https://github.com/localsend/localsend/issues/2414, created 2025-04-21. Exact body and metadata: `original-issue-2026-10-11.json`; all four comments: `comments-2026-10-11.json`.

The title is “Receiving many files causes hang and large memory usage”. The body says: “I tried to send a directory with 5k files on a old pc and got OOM”, proposes lazy loading the receive “option” list, and links `receive_options_page.dart` at source commit `09b9482358b4f3846ff8f9fc9e340f14b1ff1e3a`, line121. Its second paragraph asks for a directory-name/content-count presentation rather than many individual selected files; this is a separate UI request, not an additional failure trigger. The four later comments describe other triggers and do not identify the original reporter's environment.

The original report supplies no OS, architecture, installed version/package, RAM, CPU, swap, graphics/backend, filename lengths, extensions/content, directory depth, sender details, exact action timing, or kernel OOM evidence. “Old PC” is not a numerical hardware specification. The reported OOM is a report, not a independently correlated victim event.

## Shared tested artifact and fixture

All substantive rows use the unmodified official v1.17.0 Linux x86-64 TAR (SHA256 `6f05e851b72dbeaac764d3446b5a61c34db22f6278baa92607d5b080997f8c81`). Its date makes it plausible for the report, not confirmed. Static `git diff v1.17.0 09b948… -- app/lib/pages/receive_options_page.dart` is empty: the linked Options page is identical at those two sources. That does not prove the reporter used this binary, its engine or the same other code.

The real GUI folder picker selects flat directories of ordinary `.txt` files. Each file is 49 bytes with fixed content/hash; leaf names `file-00000.txt` are 14 ASCII characters. The 5000 folder `Case2414Files5000` is 17 characters; displayed relative names are 32 characters including slash. Extensions, content size, name lengths and depth are constant, not varied. A five-file full save/hash/both-Finished prerequisite precedes the larger cases. No protocol metadata is injected, no process memory cap or artificial pressure is applied.

## Material conditions actually exercised

Infrastructure/readiness/OCR retries are excluded. Repeated runs with identical product conditions corroborate a row; they are not extra coverage dimensions.

| Condition | Receiver / resources | Counts and actions | Qualified observations | Limit / evidence |
| --- | --- | --- | --- | --- |
| High-memory host | Linux x64 Actions host,4 CPUs,15989MiB RAM,3071MiB configured swap | 5 control;5000 folder→approval→Options; one partial save | Control completes;5000 Options visible in retained frames, large RSS rise, no retained kernel OOM | Does not model old hardware; large save initially missed Accept, later advanced507 files in180s. Runs38106985658,38107406174,38107835899 |
| Ordinary guest, complete transfer | Ubuntu24.04 x64,2 vCPU,2GiB configured RAM,zero swap | 5 full control;5000 folder→approval→Options→Back→Accept→save |5000 expected names/hashes and both Finished; list observed by5.502s after input; peakRSS1110.8MiB/PSS1076.7MiB,min available601.4MiB; no kernel OOM | Roughly31.7min observed save progression; observation/hash overhead prevents isolated throughput/paint timing. Run38111506442, final-analysis.json |
| Guest Options interaction | Same2CPU/2GiB/zero-swap guest |5 and5000; real scroll, filename dialog, ordinary draft, Cancel, Back, then save |5000 scroll/draft/Cancel works; first draft frame partial `P`, later full by4.630s after type start; every save sample increases to4660 hash-complete files | Per-case save window ends, not full completion or hang; sparse input bounds. Run38133441018, input-analysis.md/final-analysis.md |
| Repeated typing vs paste | Same2CPU/2GiB/zero-swap guest |5 and5000;3 typing and3 clipboard paste attempts per count, actual draft/Cancel; save | All12 draft/Cancel gates pass;5000 full typing observed by0.533–0.595s,paste0.368–0.392s; all save samples increase to4602 hash-complete | High-frequency observer uses25–30% of two-CPU capacity; outer50min timeout, no full save result or OOM. Run38136480853, input-comparison-analysis.md/final-analysis.md |
| Qualified lower-memory desktop | Installed Debian12/Openbox x64,2 vCPU,1GiB configured RAM,fixed ordinary2GiB disk swap |5 full control;500 and5000 folder→approval→Options hold→Back→one normal Decline→home; no large save | All gates pass and larger saved_files=0.5000 list seen by11.277s; Back approval by1.415s; Decline home by4.682s. Peak sampled RSS821.6MiB,processswap269.1MiB,systemswap713.5MiB,min available6.77MiB; no OOM | Initial5000 frame stillapproval at+1.121–1.190s; transient blank afterDecline at+2.092–2.161s recovers. Cheap sampler has1.126s read/gap; no continuous responsiveness claim. Run38150625402,memory-analysis.md; same-condition partial run38149100467 corroborates delayed recovery |

## Match to every failure-related original detail

| Original detail | Match / result | What remains different or unknown |
| --- | --- | --- |
| Receiving, rather than sender selection only | Real separate sender/receiver processes; actual incoming approval then receiver Options | Reporter sender/transport setup unknown; sender-side comments are not substitutes |
| Send a directory | Actual folder picker and relative directory-prefixed names | Nested folders, multiple folders, depth and original directory layout not supplied; only flat fixture tested |
|5k files | Exactly5000, with5 controls and500 in lower-memory row | No necessity established for other counts;10k–100k comment is another claim |
|“option” screen and linked eager list | Actual Options before Accept; linked source file identical to tested tag | Full linked-source build/binary, current release and isolated builder correction not executed |
|“old pc” |2CPU/2GiB no-swap and qualified2CPU/1GiB swap configurations | Neither matches unknown CPU generation/speed, OS/backend, physical GPU, storage or reporter RAM/swap; vCPU count does not establish old-PC performance |
| Large memory usage | Clear increase around Options and strong pressure at5000 | On latest1GiB run, readyPSS190084KiB→approval202908KiB/Swap0→post-input +10.989s PSS795401KiB/Swap183352KiB. This is temporal association, not isolated allocation attribution |
| Hang | Recovered delays and one transient blank observed; normal navigation/cancel and one complete5000 save demonstrated | Sparse snapshots cannot prove uninterrupted responsiveness; original hang duration/action sequence unknown |
| OOM | Complete kernel reads contain no correlated OOM/victim event in qualified guests | Tested outcomes cannot disprove OOM on the reporter's unknown environment; swap may avert it and2GiB has headroom |
| Individual files displayed instead of directory summary | Fixture is visibly expanded as directory-prefixed individual file rows, matching this display observation | Requested alternate presentation is not implemented or evaluated; it is not a validated fix |

## What is excluded, and what is still needed for a stopping decision

The completed runs did not reproduce a persistent hang or a recorded kernel OOM with this verified Linux release and flat, short-name, 49-byte, 5000-file fixture. They do not establish that every repeat in these configurations will behave identically. Advancing save samples and later Back recovery do not substantiate a persistent stall in those observed intervals; transient stalls are not excluded. Platform/artifact differences, original file/name/depth effects, hardware/backend differences and swap-dependent OOM remain open. Debian 1 GiB and Ubuntu 2 GiB differ in OS/desktop/swap, so they do not isolate RAM alone.

Independent read-only source-fidelity review checked the original body, retained artifacts, fixture dimensions, historical metrics and the empty Options-file diff. It found no contradicted original detail; its objection to a broad exclusion claim is incorporated above. This is not investigation closure approval.

The remaining discriminators are: (1) exact reporter artifact/version and OS/architecture/backend; (2) original RAM/CPU/swap and independent OOM victim evidence/action timing; (3) original extensions, sizes, name lengths and folder depth. Those details would determine whether a matched artifact/platform/fixture experiment is justified. Rebuilding linked source or comparing the existing builder correction would answer a different causal question and needs coordinator scope; the existing correction `76a356a…` in v1.18+ is only a static hypothesis so far. No Windows/macOS/Android receiver, mixed/large contents, long/Unicode names or nested fixture has been tested for this original report. No new probe or production patch follows automatically from recovered delay/blank.
