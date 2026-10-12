# Issue 2453: one-session iOS installation plan

This is a documentation-only plan, researched on 2026-10-12. No IPA was uploaded, no session or device was acquired, and no application or harness was run. The plan remains subject to the root's independent review and later explicit execution authorization.

## Recommended installation strategy

Use one fresh App Automate native XCUITest session. Install the retained default IPA as the session's initial `app`, replay the agreed flow, terminate LocalSend, and install the retained candidate with BrowserStack's documented mid-session installation facility. Activate the same bundle ID and replay the same flow. Keep the original session alive across both arms; do not quit and create another session between them.

BrowserStack explicitly documents an iOS example using:

```java
// Session creation, before any device is acquired:
caps.setCapability("app", "bs://DEFAULT_EXACT_UPLOAD_ID");
browserstackOptions.put("midSessionInstallApps",
    new String[] {"bs://CANDIDATE_EXACT_UPLOAD_ID"});
caps.setCapability("bstack:options", browserstackOptions);

// In the same driver/session, after the default replay:
driver.terminateApp("org.localsend.localsendApp");
driver.installApp("bs://CANDIDATE_EXACT_UPLOAD_ID");
driver.activateApp("org.localsend.localsendApp");
```

The `bs://…` placeholders must be the exact `app_url` values returned for those uploads. They are not local paths or mutable custom aliases. BrowserStack requires matching signatures and bundle ID for upgrade tests. Its capability reference documents `resignApp: true` for uploaded iOS apps: BrowserStack signs them with its provisioning profile to install on real devices, removing entitlements. The retained unsigned IPAs therefore require that provider signing path; do not set `resignApp: false`. Matching provider signatures must be confirmed from the upload/install result rather than assumed from the unsigned source artifacts.

Use the exact accepted device/OS selectors from the earlier successful allocation: iPhone 16 Pro, iOS 18.6, native XCUITest, portrait. Record the returned model, full OS version, Appium/XCUITest versions, session ID, and any physical device identifier disclosed by provider logs. Do not substitute iOS 18, latest, or another model if 18.6 is unavailable. The minor-version documentation now advertises recent iOS 26 versions; it does not establish present availability of the earlier 18.6 combination.

## Same-version and same-bundle limitations

Both artifacts advertise LocalSend `1.17.0+58`. Version metadata alone cannot identify the installed arm. XCUITest's documented `mobile: installApp` installs by default even when versions are equal; `checkVersion: true` would skip equal or older `CFBundleVersion` and must not be enabled. Session-start `appium:enforceAppInstall: false` has the same version-comparison hazard and must not be used to select the baseline.

The BrowserStack iOS example uses `driver.installApp(bsUrl)`. Prefer that documented provider path. Its Android example uses `mobile:installApp` with `appPath`; the current upstream XCUITest extension instead calls its parameter `app`. Do not copy Android's extension payload into iOS without checking the selected provider/driver API. No trial installation is authorized during this plan stage.

`otherApps` is documented as installing apps before tests. It is not a sequential arm selector and cannot retain two copies with the same bundle ID. `appVersion` selects versions when an `app` custom/shareable ID is used; it cannot distinguish these equal-version artifacts. Uploading a newer binary under a custom ID is not documented as replacing a binary already installed in an active session. Use the explicit mid-session install command and immutable upload references.

`fullReset` acts before a new session starts. It does not reset between arms or select the candidate. XCUITest warns that application data can remain cached on real devices even with `fullReset`. A one-session in-place installation is an upgrade comparison with potential state carryover, not two independently fresh installations.

## Evidence and state handling

Before execution, retain a manifest linking each full original IPA SHA-256 to its upload response and exact `bs://` URL: default run `38185684847` (accepted SHA starts `cc980b`), candidate run `38191446249` (accepted SHA starts `5b11c2`). Use the parent's accepted full hashes; the prefixes here are labels only. Preserve capability JSON and timestamped terminate/install/activate request/response trace. Download provider Appium logs, device logs, and video. Appium logs are enabled by default and retained for 30 days; the documented API is `GET /app-automate/builds/<build-id>/sessions/<session-id>/appiumlogs`.

Verify the advertised bundle ID and version using available provider upload/session metadata and installation logs. If the selected driver/provider supports XCUITest `mobile: listApps`, its documented real-device result can return `CFBundleIdentifier`, `CFBundleVersion`, and `CFBundleShortVersionString`; this is supplementary metadata, not proof of binary bytes. Do not introduce this extra command merely to claim artifact identity when both arms report the same version. Neither cited BrowserStack page promises an on-device IPA hash, AOT hash, or Mach-O UUID. State identity as exact original IPA → provider upload URL → explicit install command → acknowledged install/launch. Stop if logs show a skipped install or cannot tie the candidate request to its exact upload reference.

BrowserStack provides preloaded iOS sample photos and videos in the device photo library. Keep that library unchanged throughout the single session. Reinstallation can carry LocalSend preferences, permission grants, and other user data. Do not interpret the absence of a candidate Photos prompt as a behavioral difference. Before each measured arm, visually verify the agreed Limited Photos state with one allowed photo, identical visible sample content, portrait orientation, and an unselected picker/grid. Record any re-establishment needed as a harness/state difference.

BrowserStack's `updateAppSettings` Photos example sets `All Photos`; its supported settings list does not document choosing one allowed photo in Limited mode or resetting a real device to an undetermined Photos prompt. XCUITest's `appium:permissions` capability is simulator-only, and `mobile:clearApp` is also simulator-only. Do not use either as a real-iPhone reset mechanism. Reset/clear permission operations, uninstalling between arms, or broad auto-accept logic would alter this comparison and require a separately reviewed plan. Prefer the same native permission/picker UI flow and preserve the agreed Limited state across the upgrade.

An uninstall/reinstall in the still-live session could remove more app state, but it is unnecessary for the smallest upgrade comparison. It changes permission and sample-container assumptions, and upstream warns about real-device leftovers. Treat it as an alternative requiring explicit review, not an automatic retry if the candidate install fails.

## Minimal lifecycle and stop conditions

1. After execution is separately authorized, use retained verified artifacts and existing valid exact upload URLs, or upload only those two artifacts if needed. Acquire at most one owned device in one session. Do not enable Test Companion, BrowserStack AI agents, or self-healing.
2. Confirm the allocated iPhone 16 Pro/iOS 18.6 and preserve session/device metadata. Establish the native limited-one-photo starting state and agreed replay. Keep baseline native-source failure distinct from application behavior.
3. Capture the default arm's input sequence and observations. Terminate, install the exact candidate upload, require an acknowledged non-skipped install, and activate the same bundle ID within the unchanged session.
4. Verify carryover state and replay exactly the reviewed sequence. A default failure before selection/Close cannot be reported as a selection/Close failure; any change to the timing of native XML requests must be disclosed and reviewed as a harness change before dispatch.
5. Preserve evidence, quit the session in the cleanup path, and verify its release. A dead WDA/provider session is an infrastructure blocker: do not claim a candidate comparison or automatically acquire a replacement device.

A continuous session is the smallest documented way to keep both arms on its assigned real device. Same model/OS across separate sessions does not prove the same physical iPhone. If the provider disconnects/reallocates, or evidence cannot establish session continuity, report the paired comparison as blocked. A later two-session comparison would require a revised claim (same model/OS only) and authorization. No cited public documentation establishes the ability to request the identical physical public-cloud iPhone after releasing a session.

The accepted packaging comparison still contains unattributed App AOT byte differences. A successful same-device upgrade replay would compare these two retained artifacts; it would not isolate `FLTEnableMergedPlatformUIThread=false` as the only cause.

## Official sources inspected

- [BrowserStack: Test app upgrade in Appium tests](https://www.browserstack.com/docs/app-automate/appium/advanced-features/test-app-upgrades), including the iOS snippet, matching-signature/bundle requirement, and `midSessionInstallApps` capability.
- [BrowserStack: Capabilities reference](https://www.browserstack.com/docs/app-automate/capabilities), including `app`, `appVersion`, `midSessionInstallApps`, `otherApps` generator label, log defaults, and the expanded reference's `resignApp` explanation. The generator's misleading mid-session label says “prior to running test”; the dedicated upgrade page's explicit iOS commands determine the recommended sequence.
- [BrowserStack: View logs for Appium tests](https://www.browserstack.com/docs/app-automate/appium/debug-failed-tests/appium-logs), log retention and download API.
- [BrowserStack: Update iOS app settings](https://www.browserstack.com/docs/app-automate/appium/advanced-features/ios-app-settings), supported permissions, Photos All Photos example, permission-popup prerequisite, and plan restrictions.
- [BrowserStack: Run Appium tests using sample data](https://www.browserstack.com/docs/app-automate/appium/advanced-features/test-with-sample-data), preloaded photo/video library.
- [BrowserStack: Test on iOS minor versions](https://www.browserstack.com/docs/app-automate/appium/advanced-features/ios-minor-version), latest/latest-1 allocation semantics and current advertised iOS versions.
- [Appium XCUITest: Capabilities](https://appium.github.io/appium-xcuitest-driver/latest/reference/capabilities/), `fullReset`, `noReset`, `enforceAppInstall`, `otherApps`, and simulator-only permission capability.
- [Appium XCUITest: Execute methods](https://appium.github.io/appium-xcuitest-driver/latest/reference/execute-methods/), install/checkVersion, terminate/activate, real-device listApps, removeApp, and simulator-only clearApp. These are upstream latest-driver semantics, not evidence that BrowserStack's selected version exposes every extension.
