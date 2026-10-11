# Exact source pair: invalid inherited settings

Run https://github.com/ShlomoCode/localsend/actions/runs/38164945782 stopped before sender launch or the five-file control in both variants. This is a setup failure, not an additional substantive condition or a reproduction of issue 2414.

The retained final readiness frames show the application's initialization error. Both receiver logs identify `bool` not being a subtype of `String?` in `PersistenceService.getQuickSave`. The harness wrote `flutter.ls_quick_save: false`, the format used by its official 1.17 scenarios. Exact source parent `165d7fe3` reads this key with `getString` and supports enum names `off`, `on`, and `paired`; its correcting child has the same persistence code.

The diagnostic-only correction supplies `off` when source-pair mode is enabled and preserves the Boolean for the historical release path. Other explicitly supplied preference types match the source getters. No application bytes, guest resources, fixture or measurement stages change.

Both static runtime preflights passed. Receiver processes remained alive until labelled harness SIGTERM, and successful kernel reads contain no matching OOM victim. No recording had started. The cleanup warning about recorder completion is secondary to the startup failure and supplies no product evidence.

Raw artifact was downloaded through the authorized SOCKS fallback after HTTP 418 and retained at `.a5c/localsend-sprint/recovered/2414/runtime-38164945782/`. Readiness, real five-file save/hash, actual loaded-library maps and stderr remain mandatory before the 5,000-file scenario.
