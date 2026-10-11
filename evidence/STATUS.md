# Issue 402 investigation

Full thread and screenshot read on 2026-10-11. The original report selects a valid relative file symlink with the File picker on Ubuntu 20.04. Expected output is `another.txt` containing the target bytes. The screenshot shows one selected file with `Size: 0 B`.

The reporter confirms File picker selection in comment 1529263471. Comment 1529023949 reports success on Ubuntu 23.04 for both picker and drag and drop. Comment 2525539129 claims macOS reproduction without versions. Comment 3397445552 describes omission of symlinks when selecting a directory; this is a distinct scenario.

Release version and installation format were not specified. v1.8.0, published 2023-03-05, is the last official release before the 2023-04-19 report. It ships an AppImage for Linux. This is a documented assumption, not the reporter's confirmed version.

Current fork PR inventory checked on 2026-10-11. No file-symlink correction exists in open PRs. PR 71 head `7c2c26e19b480342817cb8479c18573636f056d6` changes picker error dialogs, not selected file metadata or transfer. Upstream search for symlink PRs returns unrelated CLI folder and macOS application-bundle changes.

Validated condition E1: [38138571498](https://github.com/ShlomoCode/localsend/actions/runs/38138571498), diagnostic head `f97aae2b`, passed the direct-file control and both relative-symlink repeats. The receiver used actual named Accept and Done actions. Each repeat saved exactly `another.txt`, 1,280 bytes, with the target SHA-256. The sender shows Finished. Three actual saved files are archived under `evidence/run6/issue402-historical-picker-evidence/receiver/saved/`. This is one substantive condition and no observed original failure.

Validated condition E2: [38140481350](https://github.com/ShlomoCode/localsend/actions/runs/38140481350), diagnostic head `c540b9ea`, passed direct control and both symlink repeats using real pointer selection of picker rows. Native zenity stdout returns `/home/probe/fixture/another.txt`, readlink returns `whatever.txt`, and stat-L reports1280 bytes. Exact receiver filenames and all three archived hashes match. Sender screenshot shows Finished. Evidence is in `evidence/run10/issue402-historical-picker-evidence/`. Original failure did not reproduce; this is the second substantive condition.

Validated E3: [38140856758](https://github.com/ShlomoCode/localsend/actions/runs/38140856758), head `9a76e545`, v1.7.0 official AppImage, zenity path selection with native stdout capture. Direct control and two symlink repeats pass exact names,1280-byte size and actual archived hash. Native stdout preserves another.txt. Sender Finished. Official AppImage SHA256 `0b498728876f8743e388ffa54cf881bbc33aef95b2c2122047006318aa9638bc`. Three substantive conditions now pass without original failure.

Validated E4: [38141247632](https://github.com/ShlomoCode/localsend/actions/runs/38141247632), head `766e1257`, v1.8.0 with supported kdialog backend and typed paths. Real KDialog screenshot verified. Direct control and both symlink repeats preserve exact receiver names and1280-byte contents; all archived hashes match. Native stdout preserves another.txt. Four substantive conditions now pass without original failure.

Native infrastructure attempt: [38141730938](https://github.com/ShlomoCode/localsend/actions/runs/38141730938), Ubuntu20 GNOME3.36.9/Xorg VM and ordinary v1.8 AppImage. Official hash and actual FUSE mount verified, but GTK icon/pixbuf loading aborts before visible app and control. This does not count as a substantive condition or original issue402 failure. Reviewer investigating runtime/environment fidelity; no package change made.

Validated E5: [38142559579](https://github.com/ShlomoCode/localsend/actions/runs/38142559579), head `5f56e02d`, v1.8 zenity typed paths with accessible absolute another.txt target. Control and both repeats pass exact names,1280-byte contents and actual archived hash. Five substantive conditions now pass without original failure.

Validated E6: [38143315209](https://github.com/ShlomoCode/localsend/actions/runs/38143315209), head `b3a3d94a`, native Ubuntu20.04.6 GNOME3.36.9/Xorg VM. Ordinary unchanged official AppImage launch and actual FUSE mount verified. Driver inherits actual GNOME XDG_DATA_DIRS/config dirs/GTK_MODULES; no fabricated defaults or pixbuf cache override. Actual File picker and GUI manual address10.0.2.2/IP/Confirm send to known Docker receiver. Direct control and two relative symlink repeats pass exact names,1280B and target hash. Actual archived outputs independently hashed. Inspected native sender screenshot shows another.txt1.3KB,Done,Finished. Manual address route does not test discovery. Six substantive conditions now pass without original failure. Artifacts in evidence/run15/issue402-historical-picker-evidence; sender under gnome-guest/sender and actual saved files under receiver/saved.

Independent package review confirms AppRun.env prepends bundled directories to inherited XDG_DATA_DIRS and bundle omits themes. Restoring actual GNOME variables resolves I13 startup blocker. Historical PR415 adds host system data paths, but is not proven to fix402. Original PNG cache cause was not established and no cache override was applied.

Validated E7: [38144391011](https://github.com/ShlomoCode/localsend/actions/runs/38144391011), v1.8 zenity path selection, another.txt -> ../target/whatever.txt. Direct control and both repeats save exact names,1280B and independent archived target hash. Seven substantive conditions pass without original failure.

Validated E8: [38145009651](https://github.com/ShlomoCode/localsend/actions/runs/38145009651), v1.8 zenity typed paths, ordinary accessible link chain another.txt -> intermediate.txt -> whatever.txt. Direct control and two repeats save exact names, 1,280 bytes and independently verified archived hashes. Eight substantive conditions pass without original failure.

Initial kdialog row comparison 38145656821 selected direct file at 1.25 KiB but clicked window title Open instead of confirmation; dialog remained open, so it is an infrastructure locator failure. Screenshot and logs preserved in evidence/run18.

Validated E9: [38146114903](https://github.com/ShlomoCode/localsend/actions/runs/38146114903), head f84c5294, v1.8 kdialog native file-list row selection. Native stdout preserves original another.txt path. Direct control and both repeats save exact names, 1,280 bytes and independently verified archived hashes. Sender Done/Finished screenshot inspected. Nine substantive conditions pass without original failure.

Validated E10: [38146696210](https://github.com/ShlomoCode/localsend/actions/runs/38146696210), v1.7 zenity file-list row selection. Real pointer row actions recorded. Direct control and two link repeats save exact names, 1,280 bytes and independently verified archived hashes. Sender Finished screenshot inspected.

Ten substantive conditions now pass without original failure. The stop-gate packet is in STOP-GATE.md. Parent owns the stop decision; no production patch is proposed without an observed reported failure and causal evidence.

Validated E11: [38147444960](https://github.com/ShlomoCode/localsend/actions/runs/38147444960), official v1.7.0 with kdialog typed-path selection. Native stdout preserves another.txt. Direct control and both repeats save exact names, 1,280 bytes and independently verified archived target hashes. Full raw workflow log and application evidence preserved in run21.

Eleven substantive conditions now pass without original failure; 33 actual saved files are archived. The independent quality review rehashed all 30 saved files from E1–E10 and examined E6/E9/E10 against the original report; E11 was verified separately by the owning agent. The parent approved stopping the original Ubuntu 20 file-picker investigation as a documented reproduction blocker. Resume only with the release, package, picker backend, target filesystem and link fixture from a failing installation. The unversioned December 2024 macOS claim and October 2025 directory-symlink omission remain separate gaps; the whole issue thread is not resolved. All owned resources are closed and no workload is active. No further workload will start without a new lead.

The current validated desktop session is XFCE under Xvfb; the report does not identify a desktop environment, and a container is different from a physical Ubuntu installation. Raw picker stdout and status are passed back to the unchanged app without alteration. Artifact preservation is enforced before upload.

The official AppImage SHA-256 is `49eb71c34bab7c90a21c8f8cb3e220ae88b508b0a00741f906c57a464c7204c1`. Runtime is Ubuntu 20.04.6, GTK 3.24.20, zenity 3.32.0, and XFCE 4.14.2. The normal shared text payload is 1,280 bytes, SHA-256 `0db53a1320c10f437c2bdca9b4d4049b74f2729f7a07cb3d656b62226311f014`.

Run 38137246675 selected the valid relative symlink twice as 1.3 KB. Its transfer result is invalid as a control: XDG Downloads was missing, and the receiver failed before approval for the direct file and symlink. A green run without saved-file assertions was rejected. Infrastructure repairs are recorded separately and do not count as substantive reproduction conditions.

File-row selection and the supported kdialog backend were covered in the completed matrix. Source history identifies desktop migration commit `6b4ff0b7c80be6622f2558a6468078514523f6dd` as a possible historical comparison, without proving it corrected this report.

No application workload has run locally. No production patch exists.

Independent Sol6.1 medium review completed in child `independent_402_assumptions`. It confirmed provider/dependency assumptions and recommended source-specific completion handling: ordinary transfers use ProgressPage, whose file status and bottom button can both say Done. The active harness first tries named AT-SPI actions, then OCR in an enlarged footer. It archives each received fixture, requires the exact filename, and resets only acknowledged fixture outputs between cases. AT-SPI availability is a tested locator candidate, not an assumed application property.
