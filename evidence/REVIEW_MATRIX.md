# Issue 2830: long-text experiment review matrix

Eight distinct long-text content conditions, one supplementary scroll condition, and one supplementary selection condition have been exercised. Corrected selection shows the highlight, handle and toolbar, followed by successful overlay dismissal, Copy returning to Receive, and exact clipboard equality. The two 44-byte application controls, calibration repeats, repeated CJK verification, and infrastructure failures are excluded from this count.

The report describes Windows Send → Clipboard → target followed by Android freezing. It does not specify tapping, scrolling, selecting, or Copy. Every content experiment below uses original 1.17.0 applications and actual Windows Clipboard → Favorites → target actions, followed by Android Preview. Copy supplements the reported trigger with responsiveness and content verification. Scroll and selection are explicitly supplementary scenarios.

The parent has accepted all ten conditions after inspecting raw screenshots and independently checking content hashes, including corrected selection run 38132269475. For CJK/emoji, acceptance covers full Preview content and responsiveness only, not clipboard readback. The nine-condition parent review snapshot is retained at /tmp/localsend-sprint/2830-parent-pending-review.json; the tenth acceptance is the parent message after directly viewing all three corrected-selection screenshots and checking the full clipboard hash.

## Parent-accepted conditions

| Run | Changed variable and comparison | Reported scenario exercised | Observed outcome | Raw evidence directory |
| --- | --- | --- | --- | --- |
| 38108693595 / c3bc4478 | Short control → 105000 ASCII characters; same S23 / Android 13 and sender settings | Original sender clipboard selection and target; receiver message Preview | Preview and responsive Copy; complete clipboard readback equals 105000-byte source | `long-38108693595/issue2830-physical-control/evidence/` |
| 38109163891 / c3bc4478 | ASCII → ASCII with 1640 LF; same total 105000 characters/bytes and S23 environment | Same reported sender flow and receiver Preview | Preview and responsive Copy; complete clipboard readback equals source | `multiline-38109163891/issue2830-physical-control/evidence/` |
| 38109605530 / c3bc4478 | ASCII length 105000 → 107520 (105 KiB); same S23 environment | Same reported sender flow and receiver Preview | Preview and responsive Copy; complete clipboard readback equals 107520-byte source | `kib-38109605530/issue2830-physical-control/evidence/` |
| 38113374423 / 8ef99127 | Matching Xiaomi short control → ASCII105000; same Note 11 / Android 11 and 10000 ms discovery setting | Same reported sender flow and receiver Preview | Preview and responsive Copy; complete clipboard readback equals 105000-byte source | `xiaomi-ascii-10s-38113374423/issue2830-physical-control/evidence/` |

## Six additional parent-accepted conditions

All six rows below are parent accepted. The corrected selection repeat is the same condition as the first attempted selection run; it does not increase the count. The failed first attempt does not claim completed Copy or content readback.

| Run | Single changed input or action | Reported scenario exercised | Investigator observation and limitation | Raw evidence directory |
| --- | --- | --- | --- | --- |
| 38113967487 / 8ef99127 | Xiaomi ASCII → same-length ASCII with 1640 LF | Same reported sender flow and receiver Preview | Inspected Preview and Receive after Copy; source/readback both 105000 bytes and same SHA-256 | `xiaomi-multiline-10s-38113967487/issue2830-physical-control/evidence/` |
| 38115650086 / 4c0100f9 | Replace the canonical ASCII source's 1666 spaces with X; other character positions and length unchanged | Same reported sender flow and receiver Preview | Inspected Preview and Receive after Copy; source/readback both 105000 bytes, spaces0/LF0/CR0, same SHA-256 | `xiaomi-unbroken-10s-38115650086/issue2830-physical-control/evidence/` |
| 38116279930 / 4c0100f9 | Replace ASCII with CJK at fixed 105000 Unicode scalars; UTF8 grows to 315000 bytes | Same reported sender flow and receiver Preview | Inspected Preview and responsive Copy→Receive. Complete decoded Preview XML equals source. Appium clipboard-get adb broadcast times out after 20000 ms; clipboard readback unavailable | `xiaomi-cjk-10s-38116279930/issue2830-physical-control/evidence/` |
| 38119855958 / 4c0100f9 | Use 105000 U+1F600 Unicode scalars; 210000 UTF16 units, 420000 UTF8 bytes | Same reported sender flow and receiver Preview | Inspected Preview and responsive Copy→Receive. Decoded XML numeric entities reconstruct exact source. Same Appium clipboard-get timeout; clipboard readback unavailable | `xiaomi-emoji-10s-38119855958/issue2830-physical-control/evidence/` |
| 38123089865 / f026ca65 | One 600 ms vertical swipe inside actual text ScrollView; same unbroken105000 source and Xiaomi settings | Reported sender flow plus supplementary receiver scroll | Inspected receiver-1 Preview, visibly shifted text after-scroll, and Receive after Copy. Complete clipboard readback equals source | `xiaomi-unbroken-scroll-38123089865/issue2830-physical-control/evidence/` |
| 38132269475 / 9581f72c (corrected repeat of 38124266718) | 1200 ms long-press inside text ScrollView; same unbroken105000 source and Xiaomi settings | Reported sender flow plus supplementary receiver selection | Inspected highlight/handle/toolbar, then overlay dismissal via text tap. Main Copy returns to Receive and complete clipboard equals source. Parent accepted after raw review | `xiaomi-unbroken-select-fixed-38132269475/issue2830-physical-control/evidence/` |

## Exclusions and remaining environment gaps

- Runs 38108176962 and 38111742971 are 44-byte controls, not long-text freeze experiments. Run 38112860787 is the repeated Xiaomi control after a supported discovery-timeout setting change.
- CJK repeat 38117578456 repeats the complete Preview and responsive Copy→Receive, together with the same Appium clipboard-get timeout. It adds repeatability evidence, not another condition.
- HTTP download failures, token propagation, HWND targeting, relay handoff, StartupOnly exits, and Favorites discovery failures do not exercise long-text reception.
- No completed condition shows the reported LocalSend freeze. The Appium clipboard timeout is a verification limitation; it is not treated as a product bug.
- Original Redmi Note 10 Pro / MIUI 14 / Android 13 remains unavailable in the device catalog. The available Xiaomi is Redmi Note 11 / Android 11 / MIUI Global 13.0.8 Stable (13.0.8.0(RGCINXM)), confirmed by the About phone screenshot in run 38134203137. The later XML shows Home, so the automated XML-label flag is false; the screenshot establishes the version.
- Windows 11 ARM runs the original x64 release under emulation. The original Dell / native x64 sender is uncovered. Release 1.17.0 is inferred from report date, not explicitly confirmed by the reporter.
- The report leaves original source content, K unit, line count, encoding, acceptance setting, and whether Preview ever appeared unspecified. These gaps prevent claiming resolution of the original report.

## Firmware diagnostic

Run 38134203137 / 7e144bdd opened About phone using the standard Android DEVICE_INFO_SETTINGS intent without changing settings. The screenshot, inspected directly, shows Android 11 RKQ1.211001.001, MIUI Global 13.0.8 Stable / 13.0.8.0(RGCINXM), security update 2022-02-01, and model 2201117TI. The later XML already shows com.miui.home, so firmware-ui-result.json reports aboutPageObserved=false; that field checks XML labels, not the preceding screenshot. Firmware version is screenshot evidence. The reason Settings returns to Home remains unknown. Raw path: xiaomi-firmware-direct-38134203137/issue2830-physical-control/evidence/.

A fresh authenticated BrowserStack App Automate device catalog read at 2026-10-11 11:17:33 UTC returns 110 rows. Case-insensitive Xiaomi/Redmi/Poco filtering returns only Xiaomi Redmi Note 11 / Android 11.0 (device_limit 5). No Xiaomi Android 13 alternative is present; catalog rows contain no MIUI/firmware version field. The firmware screenshot confirms this available device uses MIUI 13.0.8. The final owned session status is done; the Actions run completed successfully. No owned job/session remains active. Sanitized evidence and screenshot hash: firmware-catalog-review.json.

Parent decision: investigation blocked after independent review of all ten conditions, firmware screenshot, and fresh catalog. No evidence-backed product freeze or cause is established. Resume only with new evidence: access to the original Redmi Note 10 Pro / MIUI 14 / Android 13 environment, or the reporter's exact clipboard source together with confirmed LocalSend build and settings. A legitimate native Windows 11 x64 sender can close the separate architecture gap. No additional arbitrary payloads, product change, PR, or upstream post is authorized by this checkpoint.
