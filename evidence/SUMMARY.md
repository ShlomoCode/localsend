# Issue 2830: evidence summary

The reported Android freeze is not reproduced in nine completed long-text conditions so far. Two additional short controls are excluded from that count. Selection is active. The parent has accepted nine conditions; corrected selection raw evidence awaits parent review (see REVIEW_MATRIX.md). Original LocalSend 1.17.0 applications complete four fixtures on Galaxy S23 / Android 13, plus short, ASCII105000, and multiline105000 on Xiaomi Redmi Note 11 / Android 11. Unbroken105000 also passes on Xiaomi. No production fix or PR is justified by these results.

The observed flow is Windows Send → Clipboard → Favorites → target, then Android message preview. Copy is supplementary responsiveness and full-content verification; the report does not require scrolling, selection, or Copy to trigger the freeze. Android Quick Save is Off in inspected screenshots.

| Run | Fixture | UTF-8 bytes | UTF-16 bytes | LF | Result |
| --- | --- | ---: | ---: | ---: | --- |
| 38108176962 | Short ASCII | 44 | 88 | 0 | Preview, Copy, exact readback passed |
| 38108693595 | 105000 ASCII | 105000 | 210000 | 0 | Preview, Copy, exact readback passed |
| 38109163891 | 105000 ASCII with LF | 105000 | 210000 | 1640 | Preview, Copy, exact readback passed |
| 38109605530 | 105 KiB ASCII | 107520 | 215040 | 0 | Preview, Copy, exact readback passed |
| 38111742971 | Short ASCII on Xiaomi | 44 | 88 | 0 | Preview, Copy, exact readback passed |
| 38113374423 | 105000 ASCII on Xiaomi, timeout 10000 ms | 105000 | 210000 | 0 | Preview, Copy, exact readback passed |
| 38113967487 | 105000 with LF on Xiaomi, timeout 10000 ms | 105000 | 210000 | 1640 | Preview, Copy, exact readback passed |
| 38115650086 | Unbroken105000 on Xiaomi, timeout 10000 ms | 105000 | 210000 | 0 | Preview, Copy, exact readback passed |
| 38116279930 | CJK105000 on Xiaomi | 315000 | 210000 | 0 | Preview and responsive Copy; complete preview XML equals source; clipboard tool timeout |
| 38119855958 | Emoji105000 on Xiaomi | 420000 | 420000 | 0 | Preview and responsive Copy; complete decoded preview XML equals source; clipboard tool timeout |
| 38123089865 | Unbroken105000 + receiver scroll on Xiaomi | 105000 | 210000 | 0 | Scrolled content visibly shifts; Copy and exact readback passed |

Each source/readback pair has an identical SHA-256:

- Short: `10f6b75f53e5d94f86ef113f23647fba57e411f34f8ba74c30ca334e92b02fd4`
- ASCII: `83b801b3087bde5b41b2309cd1e364dbcccf7d9a8c86652a8479e08d3bffaf5a`
- LF: `caad1d316ceadf1c0b89ce451b846056c35476f84fd662c7c32177fd7c60c838`
- 105 KiB: `0dbb926773683d012337417d054047989fa9eed6319736bec4e26931ccf1da56`

All four use diagnostic c3bc4478. The first preview source responses are 197, 315, 351, and 333 ms respectively; these are Appium source-response times, not end-to-end rendering times. Home-page source responses take about ten seconds because of UI idle detection and do not alone indicate a freeze. Raw result-field `sourceMatches: false` on long fixtures means XML full-text equality was not checked; [the erratum](source-matches-erratum.md) preserves the original artifacts and explains the full clipboard assertion.

## Review paths

Each directory contains `scenario-results.json`, fixture metadata, source/readback text, sender action records, receiver XML, before/preview/after screenshots, and timeline:

- `physical-38108176962/issue2830-physical-control/evidence/`
- `long-38108693595/issue2830-physical-control/evidence/`
- `multiline-38109163891/issue2830-physical-control/evidence/`
- `kib-38109605530/issue2830-physical-control/evidence/`
- `xiaomi-short-repeat-38111742971/issue2830-physical-control/evidence/`
- `xiaomi-short-10s-38112860787/issue2830-physical-control/evidence/`
- `xiaomi-ascii-10s-38113374423/issue2830-physical-control/evidence/`
- `xiaomi-multiline-10s-38113967487/issue2830-physical-control/evidence/`

Transport controls of 0, 1, 65537, and 8388608 bytes also passed. Earlier HWND, environment propagation, StartupOnly exit, and pending-long-poll failures are diagnostic infrastructure failures and do not count as application experiments. Details remain in `STATUS.md` and `experiments.jsonl`.

## Remaining boundary

The report specifies Dell Inspiron 3501 / Windows 11 Pro and Xiaomi Redmi Note 10 Pro / MIUI 14 / Android 13. The Windows runner is ARM running the original x64 release under emulation; receivers are Galaxy S23 / Android 13 and Redmi Note 11 / Android 11; the latter MIUI version is unknown. Exact Dell/native x64 and original Xiaomi/MIUI remain uncovered. Version 1.17.0 is inferred from the issue date; fixture content, K unit, line count, and acceptance setting were unspecified. The sole issue comment adds no reproduction detail.

Run 38110353448 failed its short Xiaomi control at Windows Favorites discovery. Android remained on Receive; socket controls passed and relay connections returned data. Same-fixture repeat 38111742971 / 9eccc165 passed with no timeout change, proving the actual Xiaomi short control. Run 38112230754 then failed before ASCII105000 transfer; its Windows error screenshot explicitly shows `RhttpTimeoutException` for `/api/localsend/v1/info`. These discovery failures do not exercise long-text reception and are excluded from substantive experiments.

Run 38112860787 / 8ef99127 changes only the supported Windows discovery-timeout setting from its default 500 to 10000 ms; the fresh short control passed with exact content and responsive Copy. Sender settings fixture confirms 10000. This accommodates the cloud relay's latency; upload-client timeout and original applications are unchanged. This repeat is excluded from the substantive count. Run 38113374423 passed ASCII105000 under matching settings, with the same full-content SHA as the Galaxy fixture and inspected responsive Copy. Run 38113967487 changes only content to the LF fixture. MIUI/build property commands were explicitly unsupported, so MIUI remains unknown. Varied legitimate 105K content will further distinguish text-shape conditions. Any matching product failure requires an identical repeat before a causal experiment or product change.

Unbroken source/readback SHA-256 is `19d2eb39f3714bc4270a1e9aba5f85fb732af570947a65354a5dcc7e2949ab4b`; source has no spaces/LF/CR. Review path: `xiaomi-unbroken-10s-38115650086/issue2830-physical-control/evidence/`. CJK run 38116279930 is pending.

CJK105000 run 38116279930 / 4c0100f9 displayed Preview and returned to Receive after Copy. The complete decoded preview XML equals all source content (105000 scalars / 315000 UTF8 bytes, SHA-256 `3da506076ee6bc84232952084c34db61f1b633c10dc48498bfa9ab2161db3bd4`). Appium clipboard retrieval timed out after 20000 ms; workflow failed at that supplemental gate, so clipboard success is not claimed. Review path: `xiaomi-cjk-10s-38116279930/issue2830-physical-control/evidence/`, including `cjk105000-preview-verification.json`. Identical repeat 38117578456 is pending.

Emoji105000 run 38119855958 / 4c0100f9 displayed Preview and returned to Receive after Copy. Decoding XML numeric entities reconstructs the entire source: 105000 Unicode scalars, 210000 UTF16 units, 420000 UTF8 bytes, SHA-256 `a678d1812d2f5caa2d9673c2600f7311093407ca55fda549782e756bb108d1c2`. Appium clipboard retrieval has the same 20000 ms timeout as CJK; clipboard success is not claimed. Review path: `xiaomi-emoji-10s-38119855958/issue2830-physical-control/evidence/`, with `emoji105000-preview-verification.json`.

Supplementary scroll run 38123089865 / f026ca65 changes only receiver interaction on unbroken105000. Actual Preview receiver-1 and after-scroll visibly show shifted text; after-Copy returns to Receive and full clipboard readback matches the105000-byte source. Review path: `xiaomi-unbroken-scroll-38123089865/issue2830-physical-control/evidence/`. Selection run 38124266718 is pending. Neither interaction is specified by the report.
