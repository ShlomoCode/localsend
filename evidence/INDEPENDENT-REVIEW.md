# Independent review

Sol6.1 medium explorer `independent_402_assumptions` reviewed the thread, historical source, dependency archive, driver, and run5 evidence on 2026-10-11.

1. Run5 reaches the receiver's real approval screen with valid Downloads destination. Full-screen OCR omits both colored approval buttons; no Accept occurred. This is a harness failure, not an application transfer verdict.
2. In v1.8.0, an ordinary-file Accept opens ProgressPage. Done appears in the per-file status and the bottom action. Restrict completion actions to the bottom button, then require readiness for the next transfer.
3. Require exactly `another.txt`, 1,280 bytes, and the source hash. Archive and remove only the completed test fixture before the repeated case; a stem-prefix check can accept unintended names.
4. file_picker 5.2.5 selects qarma, then kdialog, then zenity by executable availability. Its shared conversion sets size to zero when `File(path).existsSync()` is false, otherwise uses `lengthSync()`. LocalSend trusts this size and path. There is no evidence for a general inability to follow all symbolic links.
5. After a working control, capture actual picker stdout and returned-path metadata without altering the output. Select the same link by its file-list row, then compare the supported backend.

No production patch is justified by this review.
