# Issue 2830: long-text experiment review matrix

Eight distinct long-text content conditions and one supplementary scroll condition have completed. Selection is active and would be the tenth condition if its input is exercised. The two 44-byte application controls, calibration repeats, repeated CJK verification, and infrastructure failures are excluded from this count.

The report describes Windows Send → Clipboard → target followed by Android freezing. It does not specify tapping, scrolling, selecting, or Copy. Every content experiment below uses original 1.17.0 applications and actual Windows Clipboard → Favorites → target actions, followed by Android Preview. Copy supplements the reported trigger with responsiveness and content verification. Scroll and selection are explicitly supplementary scenarios.

The parent has accepted four conditions after inspecting raw screenshots and independently checking content hashes. Remaining rows are review candidates, not accepted canonical evidence.

## Parent-accepted conditions

| Run | Changed variable and comparison | Reported scenario exercised | Observed outcome | Raw evidence directory |
| --- | --- | --- | --- | --- |
| 38108693595 / c3bc4478 | Short control → 105000 ASCII characters; same S23 / Android 13 and sender settings | Original sender clipboard selection and target; receiver message Preview | Preview and responsive Copy; complete clipboard readback equals 105000-byte source | `long-38108693595/issue2830-physical-control/evidence/` |
| 38109163891 / c3bc4478 | ASCII → ASCII with 1640 LF; same total 105000 characters/bytes and S23 environment | Same reported sender flow and receiver Preview | Preview and responsive Copy; complete clipboard readback equals source | `multiline-38109163891/issue2830-physical-control/evidence/` |
| 38109605530 / c3bc4478 | ASCII length 105000 → 107520 (105 KiB); same S23 environment | Same reported sender flow and receiver Preview | Preview and responsive Copy; complete clipboard readback equals 107520-byte source | `kib-38109605530/issue2830-physical-control/evidence/` |
| 38113374423 / 8ef99127 | Matching Xiaomi short control → ASCII105000; same Note 11 / Android 11 and 10000 ms discovery setting | Same reported sender flow and receiver Preview | Preview and responsive Copy; complete clipboard readback equals 105000-byte source | `xiaomi-ascii-10s-38113374423/issue2830-physical-control/evidence/` |

## Candidates awaiting parent raw review

These six conditions bring the proposed matrix to ten only after selection actually runs. They remain outside the accepted canonical set until the parent reviews their raw evidence.

| Run | Single changed input or action | Reported scenario exercised | Investigator observation and limitation | Raw evidence directory |
| --- | --- | --- | --- | --- |
| 38113967487 / 8ef99127 | Xiaomi ASCII → same-length ASCII with 1640 LF | Same reported sender flow and receiver Preview | Inspected Preview and Receive after Copy; source/readback both 105000 bytes and same SHA-256 | `xiaomi-multiline-10s-38113967487/issue2830-physical-control/evidence/` |
| 38115650086 / 4c0100f9 | Replace the canonical ASCII source's 1666 spaces with X; other character positions and length unchanged | Same reported sender flow and receiver Preview | Inspected Preview and Receive after Copy; source/readback both 105000 bytes, spaces0/LF0/CR0, same SHA-256 | `xiaomi-unbroken-10s-38115650086/issue2830-physical-control/evidence/` |
| 38116279930 / 4c0100f9 | Replace ASCII with CJK at fixed 105000 Unicode scalars; UTF8 grows to 315000 bytes | Same reported sender flow and receiver Preview | Inspected Preview and responsive Copy→Receive. Complete decoded Preview XML equals source. Appium clipboard-get adb broadcast times out after 20000 ms; clipboard readback unavailable | `xiaomi-cjk-10s-38116279930/issue2830-physical-control/evidence/` |
| 38119855958 / 4c0100f9 | Use 105000 U+1F600 Unicode scalars; 210000 UTF16 units, 420000 UTF8 bytes | Same reported sender flow and receiver Preview | Inspected Preview and responsive Copy→Receive. Decoded XML numeric entities reconstruct exact source. Same Appium clipboard-get timeout; clipboard readback unavailable | `xiaomi-emoji-10s-38119855958/issue2830-physical-control/evidence/` |
| 38123089865 / f026ca65 | One 600 ms vertical swipe inside actual text ScrollView; same unbroken105000 source and Xiaomi settings | Reported sender flow plus supplementary receiver scroll | Inspected receiver-1 Preview, visibly shifted text after-scroll, and Receive after Copy. Complete clipboard readback equals source | `xiaomi-unbroken-scroll-38123089865/issue2830-physical-control/evidence/` |
| 38124266718 / f026ca65 | 1200 ms long-press inside text ScrollView; same unbroken105000 source and Xiaomi settings | Reported sender flow plus supplementary receiver selection | Active. No result or selection success claimed yet | Not downloaded yet |

## Exclusions and remaining environment gaps

- Runs 38108176962 and 38111742971 are 44-byte controls, not long-text freeze experiments. Run 38112860787 is the repeated Xiaomi control after a supported discovery-timeout setting change.
- CJK repeat 38117578456 repeats the complete Preview and responsive Copy→Receive, together with the same Appium clipboard-get timeout. It adds repeatability evidence, not another condition.
- HTTP download failures, token propagation, HWND targeting, relay handoff, StartupOnly exits, and Favorites discovery failures do not exercise long-text reception.
- No completed condition shows the reported LocalSend freeze. The Appium clipboard timeout is a verification limitation; it is not treated as a product bug.
- Original Redmi Note 10 Pro / MIUI 14 / Android 13 remains unavailable in the device catalog. The available Xiaomi is Redmi Note 11 / Android 11. MIUI is unknown because BrowserStack rejects the requested getprop commands; regular Settings → About phone is the next planned read-only diagnostic.
- Windows 11 ARM runs the original x64 release under emulation. The original Dell / native x64 sender is uncovered. Release 1.17.0 is inferred from report date, not explicitly confirmed by the reporter.
- The report leaves original source content, K unit, line count, encoding, acceptance setting, and whether Preview ever appeared unspecified. These gaps prevent claiming resolution of the original report.
