# Issue 2830: evidence summary

The reported Android freeze is not reproduced yet. Original LocalSend 1.17.0 applications complete four fixtures on Galaxy S23 / Android 13, plus short, ASCII105000, and multiline105000 on Xiaomi Redmi Note 11 / Android 11. No production fix or PR is justified by these results.

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

The report specifies Dell Inspiron 3501 / Windows 11 Pro and Xiaomi Redmi Note 10 Pro / MIUI 14 / Android 13. The Windows runner is ARM running the original x64 release under emulation; the receiver is Galaxy S23. Exact Dell/native x64 and original Xiaomi/MIUI remain uncovered. Version 1.17.0 is inferred from the issue date; fixture content, K unit, line count, and acceptance setting were unspecified. The sole issue comment adds no reproduction detail.

Run 38110353448 failed its short Xiaomi control at Windows Favorites discovery. Android remained on Receive; socket controls passed and relay connections returned data. Same-fixture repeat 38111742971 / 9eccc165 passed with no timeout change, proving the actual Xiaomi short control. Run 38112230754 then failed before ASCII105000 transfer; its Windows error screenshot explicitly shows `RhttpTimeoutException` for `/api/localsend/v1/info`. These discovery failures do not exercise long-text reception and are excluded from substantive experiments.

Run 38112860787 / 8ef99127 changes only the supported Windows discovery-timeout setting from its default 500 to 10000 ms; the fresh short control passed with exact content and responsive Copy. Sender settings fixture confirms 10000. This accommodates the cloud relay's latency; upload-client timeout and original applications are unchanged. This repeat is excluded from the substantive count. Run 38113374423 passed ASCII105000 under matching settings, with the same full-content SHA as the Galaxy fixture and inspected responsive Copy. Run 38113967487 changes only content to the LF fixture. MIUI/build property commands were explicitly unsupported, so MIUI remains unknown. Varied legitimate 105K content will further distinguish text-shape conditions. Any matching product failure requires an identical repeat before a causal experiment or product change.
