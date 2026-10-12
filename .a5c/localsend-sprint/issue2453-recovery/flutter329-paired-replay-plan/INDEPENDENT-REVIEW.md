# Source-only independent review

Final assessment: no remaining P1/P2 source finding in the reviewed six-file packet. The initial scenario findings and three provisional integration findings are resolved in the final source. Root can assess this concrete proposal; this assessment does not authorize dispatch or establish runtime readiness.

Reviewed `PLAN.md`, `pair-sequence.mjs`, `session-request.template.json`, `provider-installation.md`, `pair-coordinator.mjs`, and `proposed-workflow.yml` against the LocalSend lifecycle, bug-reproduction, UI-validation, BrowserStack, and NBJ instructions. No parser, compiler, test, script, application, network request, upload, session, device, or rebuild was run. Source reads and SHA-256 hashing only; artifact facts were accepted as supplied, without re-verification.

## Material findings before plan acceptance

None remain in the final reviewed source.

## Resolved during review

The earlier final-gate finding is resolved in the current source read after the parent's refinement: `completion-send` now requires visible Media and a visible `Files: 1` name/value whose following character is not another digit. The working portrait control also rejects a positive visible file count, preventing retained Send state from serving as the completion result. These changes add no native query. This review concerns that updated source, not the earlier copied version.

The proxy/gateway/WDA timeout finding is resolved in the updated PLAN transition contract and conservative request settlement flag. Provider/native errors now stop the pair rather than authorize candidate recovery commands. The scheduling attribution finding is also resolved: the positive result is now retained-artifact responsiveness compatible with the UI-thread configuration hypothesis, with explicit causal limits.

Malformed source and element-response values are now marked unresolved; the element lookup uses optional access so null results reach that guard. No runtime validation was performed.

## Resolved integration findings

The first read of `pair-coordinator.mjs` and `proposed-workflow.yml` found three P2 items, already forwarded to the parent/helper for correction:

1. The workflow dispatch required a receipt already bound to the resulting `GITHUB_RUN_ID`, which is unknown before dispatch. A concrete admission-delivery path must avoid that circular dependency and keep all provider work behind fresh root authorization.
2. Invalid or missing admission timestamps became NaN, bypassing the age/expiry comparisons. Validate finite parsed dates before checking freshness.
3. The coordinator's 25-minute clock started after checkout, Node setup, and archive downloads, while the job timeout was 30 minutes. That did not enforce the requested 25-minute overall job bound. Establish the shared absolute start before preparation and preserve its final five-minute cleanup reserve.

The final source resolves all three: admission binds a root-generated nonce to exact source SHA/ref, both parsed timestamp checks reject non-finite dates, and the first workflow step starts the shared absolute clock with job timeout 25 minutes. Scenario operations use minute20; coordinator cleanup/evidence use minute24; the last minute remains for artifact upload. PLAN now discloses the shared Settings navigation and screenshots, captured-representation limits, provisional installation identity, and hard-cancellation ownership uncertainty.

## Obligations before a separately authorized dispatch

The concrete source implements the coordinator controls. These remain runtime readiness requirements and evidence obligations, not claims established by this source review:

- The coordinator must integrate ordinary setup, exact non-skipped same-version install/activate acknowledgments, one unchanged session/device, both visually matched sample/permission states, and one shared absolute deadline.
- The 25-minute overall bound must cover acquisition/setup and installation as well as replay, preserve the last five minutes for evidence/release, and apply bounded cleanup even after unresolved native work. Report zero ownership only after the owned session's release receipt and stopped status.
- Root/sibling coordination and immediate running/queued capacity must precede allocation. No automatic retry or replacement device follows a control, install, or pending-command failure.
- Inspect continuous video for actual raw selection, returned portrait geometry, Close response, and intended trigger completion. A command acknowledgment, XML timeout, debug capture, or distorted video alone cannot establish whole-app freeze or an app-behavior pass.
- Verify configured fork secret names, provider response schemas and supported selected-driver endpoints, exact iPhone16Pro/iOS18.6 availability, provider signing, and successful same-version installation. Retained logs must show the exact candidate URL and a completed non-skipped install before accepting candidate comparison.
- Review Settings captures and the actual sample content visually. PNG header/dimension checks and equal SHA values establish captured-representation parity only; they do not rule out compositor placeholders or prove offscreen preferences and OS permissions.

The sequence places both raw postrotation attempts before the first explicit postrotation XML read. It uses one rotation per arm and derives coordinates from each arm's portrait control. Equal-version identity is traced through immutable upload/install references; carryover and provider re-signing limits are explicit. No additional P1/P2 finding in the session template or installation report.

## Final source identity

SHA-256 values recorded after the final PLAN consistency read:

| File | SHA-256 |
| --- | --- |
| PLAN.md | e028a7cb1b0adf952fcd31feb5909be65067d149936b2eee0a14ded60764c520 |
| pair-sequence.mjs | 0a04e4c3f7dc5e09430ffc46f17e6e6c93e81092de6918babc50f913eab9d3f4 |
| session-request.template.json | 4bba9604530aeb1f56440584f4b0bd7c39e261f04288904af526d00a5c51313b |
| provider-installation.md | dc36aab8a6c859aefb6822287856147b8b5e63852807f506ac5e63a00bb56e26 |
| pair-coordinator.mjs | 88a33aa193a2101610ca1609224a04d4e5ae5e908ed0c59138f11a1002d35527 |
| proposed-workflow.yml | 0ff5036906b187379d21d2bf63f29e70fc144062a595941668c3b9ff8050bb71 |

Root can assess the final source-only packet. Execution remains separately gated on fresh admission. This review provides no runtime or syntax-validation claim, and no guarantee that cleanup survives GitHub hard cancellation.

## Focused secret-name correction

Accepted the two-line workflow correction mapping `secrets.BS_SPRINT_USERNAME` to `BROWSERSTACK_USERNAME` and `secrets.BS_SPRINT_ACCESS_KEY` to `BROWSERSTACK_ACCESS_KEY`. The executor's environment contract remains unchanged. Parent supplied the actual fork secret-name inventory; this review did not retrieve or expose secret values. No new P1/P2 finding. The updated workflow SHA-256 is `06bdfc26ede89cf84945c4d75fcc0cd6976ff1d953066d6623f578fee55e3c0b`, superseding the workflow hash above. Source-only read/hash review; no parser, test, runtime, or network operation.

## Focused registration-event correction

Accepted the added `on.push` selector for branch `codex/issue2453-investigation` and path `.github/workflows/issue2453-paired-replay.yml` in the adopted workflow source at `/tmp/localsend-bug-2453/.github/workflows/issue2453-paired-replay.yml`. The existing sole job requires both the fork repository and `github.event_name == 'workflow_dispatch'`; therefore a push event does not execute its provider steps. No new P1/P2 finding in this correction. Source-only review does not establish that GitHub will register or accept a later dispatch. Workflow SHA-256 is `a1ce070dd01f0b0dfc9dddea52eaab3fba0e5d892bb672ca2c839c689f28885a`, superseding the preceding workflow hash. No parser, network, or execution operation was performed.
