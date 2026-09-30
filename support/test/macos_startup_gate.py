#!/usr/bin/env python3
"""Install the macOS startup timing gate into a disposable Runner source tree.

The overlay is intentionally branch-neutral: apply it to the same paths on
both the unfixed and fixed revisions before running the Flutter integration
test. Never run it on the permanent checkout.
"""

import argparse
from pathlib import Path


DELEGATE_CLASS = """

#if DEBUG
// Test control lives beside the real delegate, in the same Flutter engine.
final class StartupTimingGate {
    static let shared = StartupTimingGate()

    private var channel: FlutterMethodChannel?
    private var launchContinuation: (() -> Void)?
    private var heldWaiters: [FlutterResult] = []
    private var requestWaiters: [FlutterResult] = []
    private var loginItemRequested = false

    func register(binaryMessenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "startup-timing-gate", binaryMessenger: binaryMessenger)
        channel?.setMethodCallHandler { [self] call, result in
            switch call.method {
            case "waitUntilHeld":
                if launchContinuation != nil {
                    result(true)
                } else {
                    heldWaiters.append(result)
                }
            case "waitForLoginItemRequest":
                if loginItemRequested {
                    result(true)
                } else {
                    requestWaiters.append(result)
                }
            case "release":
                let continuation = launchContinuation
                launchContinuation = nil
                continuation?()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func hold(_ continuation: @escaping () -> Void) {
        launchContinuation = continuation
        for result in heldWaiters {
            result(true)
        }
        heldWaiters.removeAll()
    }

    func didRequestLoginItem() {
        loginItemRequested = true
        for result in requestWaiters {
            result(true)
        }
        requestWaiters.removeAll()
    }
}
#endif
"""

WINDOW_ANCHOR = "    let flutterViewController = FlutterViewController.init()"
WINDOW_INJECTION = """    let flutterViewController = FlutterViewController.init()
#if DEBUG
    StartupTimingGate.shared.register(binaryMessenger: flutterViewController.engine.binaryMessenger)
#endif"""
LAUNCH_SIGNATURE = "    override func applicationDidFinishLaunching(_ notification: Notification) {"
NEXT_METHOD = "    override func applicationShouldHandleReopen"
LOGIN_ASSIGNMENT = "isLaunchedAsLoginItem = LaunchAtLogin.wasLaunchedAtLogin"
REQUEST_CASE = '        case "isLaunchedAsLoginItem":'
REQUEST_OBSERVER = '''        case "isLaunchedAsLoginItem":
#if DEBUG
            StartupTimingGate.shared.didRequestLoginItem()
#endif'''


def replace_once(source: str, old: str, new: str, name: str) -> str:
    count = source.count(old)
    if count != 1:
        raise ValueError(f"{name}: expected one anchor, found {count}")
    return source.replace(old, new, 1)


def overlay(runner: Path) -> None:
    delegate_path = runner / "AppDelegate.swift"
    window_path = runner / "MainFlutterWindow.swift"
    delegate = delegate_path.read_text()
    window = window_path.read_text()
    if "StartupTimingGate" in delegate or "StartupTimingGate" in window:
        raise ValueError("timing gate already installed; use fresh disposable sources")

    window = replace_once(window, WINDOW_ANCHOR, WINDOW_INJECTION, str(window_path))
    start = delegate.index(LAUNCH_SIGNATURE)
    end = delegate.index(NEXT_METHOD, start)
    launch = delegate[start:end]
    launch = replace_once(
        launch,
        LOGIN_ASSIGNMENT,
        "isLaunchedAsLoginItem = capturedLoginItem ?? LaunchAtLogin.wasLaunchedAtLogin",
        "login-item capture",
    )
    launch = replace_once(
        launch,
        LAUNCH_SIGNATURE,
        """    override func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        // Read the Apple event during the original callback, before deferring startup work.
        let capturedLoginItem = LaunchAtLogin.wasLaunchedAtLogin
        StartupTimingGate.shared.hold { [weak self] in
            self?.finishApplicationDidFinishLaunching(notification, capturedLoginItem: capturedLoginItem)
        }
        return
#else
        finishApplicationDidFinishLaunching(notification, capturedLoginItem: nil)
#endif
    }

    private func finishApplicationDidFinishLaunching(_ notification: Notification, capturedLoginItem: Bool?) {""",
        "launch wrapper",
    )
    delegate = delegate[:start] + launch + delegate[end:]
    delegate = replace_once(delegate, REQUEST_CASE, REQUEST_OBSERVER, "login-item request observer")
    delegate += DELEGATE_CLASS

    # Validate both files before touching either source file.
    delegate_path.write_text(delegate)
    window_path.write_text(window)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runner", type=Path, help="disposable app/macos/Runner directory")
    args = parser.parse_args()
    overlay(args.runner)


if __name__ == "__main__":
    main()
