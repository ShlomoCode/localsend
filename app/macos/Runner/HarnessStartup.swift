#if STARTUP_HARNESS
import Cocoa
import FlutterMacOS

// The harness uses the same delegate and Flutter engine as Runner. Only the
// completion of native launch is delayed; the Apple event is read on time.
final class HarnessAppDelegate: AppDelegate {
    override func finishNativeStartup(_ notification: Notification, launchedAsLoginItem: Bool) {
        StartupTimingGate.shared.hold { [weak self] in
            self?.completeHeldLaunch(notification, launchedAsLoginItem: launchedAsLoginItem)
        }
    }

    @MainActor private func completeHeldLaunch(_ notification: Notification, launchedAsLoginItem: Bool) {
        super.finishNativeStartup(notification, launchedAsLoginItem: launchedAsLoginItem)
    }

    override func handleFlutterCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "isLaunchedAsLoginItem" {
            StartupTimingGate.shared.didRequestLoginItem()
        }
        super.handleFlutterCall(call, result: result)
    }
}

final class HarnessFlutterWindow: MainFlutterWindow {
    override func awakeFromNib() {
        super.awakeFromNib()
        guard let controller = contentViewController as? FlutterViewController else {
            preconditionFailure("Harness window requires the Runner Flutter controller")
        }
        StartupTimingGate.shared.register(binaryMessenger: controller.engine.binaryMessenger)
    }
}

@MainActor
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
