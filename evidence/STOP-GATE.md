# Issue 402 evidence gate

The original file-picker report has not reproduced in eleven distinct substantive conditions. Every condition passed one ordinary-file control and two real symlink transfers. All 33 archived receiver files preserve the expected basename and 1,280-byte payload with SHA-256 `0db53a1320c10f437c2bdca9b4d4049b74f2729f7a07cb3d656b62226311f014`.

| ID | Condition | Successful run | Archived evidence |
| --- | --- | --- | --- |
| E1 | v1.8, Ubuntu20 XFCE, zenity, typed path, relative link | [38138571498](https://github.com/ShlomoCode/localsend/actions/runs/38138571498) | run6 |
| E2 | v1.8, zenity, actual file-row pointer selection | [38140481350](https://github.com/ShlomoCode/localsend/actions/runs/38140481350) | run10 |
| E3 | v1.7, zenity, typed path | [38140856758](https://github.com/ShlomoCode/localsend/actions/runs/38140856758) | run11 |
| E4 | v1.8, supported kdialog backend, typed path | [38141247632](https://github.com/ShlomoCode/localsend/actions/runs/38141247632) | run12 |
| E5 | v1.8, zenity, accessible absolute link target | [38142559579](https://github.com/ShlomoCode/localsend/actions/runs/38142559579) | run14 |
| E6 | v1.8, native Ubuntu20 GNOME/Xorg, unchanged AppImage through FUSE | [38143315209](https://github.com/ShlomoCode/localsend/actions/runs/38143315209) | run15 |
| E7 | v1.8, zenity, relative target in sibling directory | [38144391011](https://github.com/ShlomoCode/localsend/actions/runs/38144391011) | run16 |
| E8 | v1.8, zenity, ordinary two-link file chain | [38145009651](https://github.com/ShlomoCode/localsend/actions/runs/38145009651) | run17 |
| E9 | v1.8, kdialog, actual file-row selection | [38146114903](https://github.com/ShlomoCode/localsend/actions/runs/38146114903) | run19 |
| E10 | v1.7, zenity, actual file-row selection | [38146696210](https://github.com/ShlomoCode/localsend/actions/runs/38146696210) | run20 |
| E11 | v1.7, supported kdialog backend, typed path | [38147444960](https://github.com/ShlomoCode/localsend/actions/runs/38147444960) | run21 |

Each archive directory contains `issue402-historical-picker-evidence/receiver/receipts.json` and actual files under `receiver/saved/1`, `/2`, `/3`. Sender screenshots and events show real file selection and completion. Native E6 sender evidence is under `gnome-guest/sender`; it records the unchanged AppImage hash, observed FUSE mount, real GNOME session variables, and actual GUI manual-address/IP/Confirm actions. That route is not a discovery test.

Infrastructure runs are recorded separately in EXPERIMENTS.md and are not counted. These include system/session setup, missing Downloads, OCR/confirmation locators, and the SSH environment omission that initially prevented the native AppImage window. No application failure was inferred from those runs. The independent native environment review is in NATIVE-ENVIRONMENT-REVIEW.md.

The release and packaging of the original report were unspecified. v1.8.0 was the last official release before the report; v1.7.0 was its predecessor. Both used file_picker 5.2.5. The source follows valid file symlinks when calculating size. Raw native picker stdout captures preserve the original symlink path; accessible links were never made dangling or denied.

These are legitimate configurations and interactions, not eleven independent environments. Most conditions share the XFCE container and ordinary payload; E6 supplies native GNOME/FUSE coverage. The supported qarma backend was not tested and was not identified in the report.

The December 2024 macOS claim remains unversioned and untested. The October 2025 directory-symlink omission is a distinct traversal scenario. Non-reproduction of the original Ubuntu file-picker case does not resolve either later claim. Independent quality review of all 30 files in E1–E10 and deeper E6/E9/E10 evidence is preserved in QUALITY-REVIEW.md; E11 was verified separately by the owning agent.

The original file-picker problem was not substituted with the later directory-symlink omission. No LocalSend application, build, test or reproduction ran locally. All application scenarios ran in serialized cloud jobs against unchanged official releases. No production patch or PR exists, and no historical commit is claimed to fix issue 402. An independent reviewer challenged source and environment assumptions.

The independent quality review is complete, and the parent approved stopping the original Ubuntu 20 file-picker investigation as a documented reproduction blocker after eleven conditions and 33 saved files. Resume only with the release, package, picker backend, target filesystem and link fixture from a failing installation. The unversioned macOS claim and directory-symlink omission remain separate gaps; the whole thread is not resolved. All owned resources are closed and no workload is active. No further workload will start without a new lead. Current evidence supports non-reproduction in the tested conditions; it does not establish the cause of the original report or justify a speculative production fix.
