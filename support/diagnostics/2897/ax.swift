import AppKit
import ApplicationServices
import CoreGraphics

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    fputs(message + "\n", stderr); exit(code)
}
func attr(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    return names as? [String] ?? []
}
func tree(_ root: AXUIElement) -> [(AXUIElement, Int)] {
    var result: [(AXUIElement, Int)] = []
    func visit(_ element: AXUIElement, _ depth: Int) {
        guard depth < 50, result.count < 12000,
              !result.contains(where: { CFEqual($0.0, element) }) else { return }
        result.append((element, depth))
        AXUIElementSetMessagingTimeout(element, 1)
        for attribute in ["AXChildren", "AXVisibleChildren", "AXSelectedChildren", "AXWindows"] {
            for child in attr(element, attribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
        }
    }
    visit(root, 0)
    return result
}
func labels(_ element: AXUIElement) -> [String] {
    ["AXTitle", "AXDescription", "AXValue"].compactMap { attr(element, $0) as? String }
}
func visible(_ element: AXUIElement) -> Bool {
    if (attr(element, "AXHidden") as? Bool) == true { return false }
    if (attr(element, "AXEnabled") as? Bool) == false { return false }
    return true
}
func hasBounds(_ element: AXUIElement) -> Bool {
    guard let value = attr(element, "AXSize") else { return false }
    var size = CGSize.zero
    return CFGetTypeID(value as AnyObject) == AXValueGetTypeID() &&
        AXValueGetValue(value as! AXValue, .cgSize, &size) && size.width > 0 && size.height > 0
}
func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
func normalized(_ value: String) -> String {
    value.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        .replacingOccurrences(of: "’", with: "'").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: ax BUNDLE dump|press|menu|contains|absent|key [LABEL]") }
let mode = args[2]
if mode == "displays" {
    var count: UInt32 = 0
    let countResult = CGGetActiveDisplayList(0, nil, &count)
    guard countResult == .success, count > 0 else { fail("No active native displays", 31) }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    let listResult = ids.withUnsafeMutableBufferPointer { CGGetActiveDisplayList(count, $0.baseAddress, &count) }
    guard listResult == .success else { fail("Active display enumeration failed", 31) }
    try emit(["mainDisplayID": CGMainDisplayID(), "activeDisplayCount": count,
        "displays": ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            return ["displayID": id, "main": CGDisplayIsMain(id) != 0, "online": CGDisplayIsOnline(id) != 0,
                "pixelsWide": CGDisplayPixelsWide(id), "pixelsHigh": CGDisplayPixelsHigh(id),
                "bounds": ["x": bounds.origin.x, "y": bounds.origin.y, "width": bounds.width, "height": bounds.height]] as [String: Any]
        }])
    exit(0)
}
if mode == "capability" {
    print("accessibilityTrusted=\(AXIsProcessTrusted()) screenCaptureAllowed=\(CGPreflightScreenCaptureAccess())")
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { fail("Native GUI permission unavailable", 10) }
    exit(0)
}
guard AXIsProcessTrusted() else { fail("Accessibility permission unavailable", 10) }
if mode == "allow-network" {
    guard args[1] == "com.apple.UserNotificationCenter" else { fail("Permission action requires the native notification process") }
    var candidates: [(AXUIElement, pid_t)] = []
    let prompt = "Allow \"LocalSend\" to find devices on local networks?"
    for native in NSRunningApplication.runningApplications(withBundleIdentifier: args[1]) {
        let nativeRoot = AXUIElementCreateApplication(native.processIdentifier)
        AXUIElementSetMessagingTimeout(nativeRoot, 1)
        for (element, _) in tree(nativeRoot) where ["AXWindow", "AXSheet", "AXDialog"].contains(attr(element, "AXRole") as? String ?? "") {
            let descendants = tree(element).map { $0.0 }
            let context = normalized(descendants.flatMap(labels).joined(separator: " "))
            func buttons(_ label: String) -> [AXUIElement] {
                descendants.filter {
                    (attr($0, "AXRole") as? String) == "AXButton" && (attr($0, "AXEnabled") as? Bool) == true &&
                    actions($0).contains("AXPress") && labels($0).map(normalized).contains(label)
                }
            }
            let allow = buttons("Allow")
            if context.contains(prompt), allow.count == 1, buttons("Don't Allow").count == 1,
               !candidates.contains(where: { CFEqual($0.0, allow[0]) }) {
                candidates.append((allow[0], native.processIdentifier))
            }
        }
    }
    guard candidates.count <= 1 else { fail("Ambiguous native LocalSend local-network prompt", 24) }
    guard let candidate = candidates.first else { try emit(["observed": false, "pressed": false]); exit(0) }
    let status = AXUIElementPerformAction(candidate.0, kAXPressAction as CFString)
    try emit(["observed": true, "pressed": status == .success, "exactPrompt": prompt,
        "process": args[1], "pid": candidate.1, "otherButton": "Don't Allow", "result": status.rawValue])
    guard status == .success else { fail("Native local-network Allow failed", 24) }
    exit(0)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
    fail("Application process unavailable: \(args[1])", 11)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1)
if mode == "windows" {
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    try emit(["pid": app.processIdentifier, "bundle": args[1], "active": app.isActive, "windows": windows])
    guard !windows.isEmpty else { fail("No visible native application window; startup qualification pending", 25) }
    exit(0)
}
if mode == "enhance" {
    let key = "AXEnhancedUserInterface" as CFString
    let before = attr(root, "AXEnhancedUserInterface").map { String(describing: $0) } ?? "unavailable"
    var settable = DarwinBoolean(false)
    let query = AXUIElementIsAttributeSettable(root, key, &settable)
    let attempted = query == .success && settable.boolValue
    let result = attempted ? AXUIElementSetAttributeValue(root, key, kCFBooleanTrue) : query
    let afterValue = attr(root, "AXEnhancedUserInterface")
    let after = afterValue.map { String(describing: $0) } ?? "unavailable"
    let enabled = (afterValue as? Bool) == true
    try emit(["pid": app.processIdentifier, "attribute": "AXEnhancedUserInterface", "before": before,
        "queryResult": query.rawValue, "settable": settable.boolValue, "attempted": attempted,
        "setResult": result.rawValue, "setSucceeded": attempted && result == .success,
        "after": after, "observedAfterEnabled": enabled])
    // Flutter's setter can return -25208 while readback is enabled. Retain both observations.
    guard enabled else { fail("Native enhanced accessibility readback is not enabled", 26) }
    exit(0)
}
if mode == "active" {
    guard app.isActive, !app.isHidden else { fail("Target application is not visible and frontmost", 12) }
    print("pid=\(app.processIdentifier) visible=true frontmost=true")
    exit(0)
}
let rows = tree(root)
if mode.hasPrefix("picker-") {
    guard app.isActive else { fail("Native picker owner is not frontmost", 28) }
    let panels = rows.map { $0.0 }.filter {
        (attr($0, "AXRole") as? String) == "AXSheet" && (attr($0, "AXIdentifier") as? String) == "open-panel" && hasBounds($0)
    }
    if mode == "picker-closed" {
        guard panels.isEmpty else { fail("Native file picker remains open", 28) }
        try emit(["nativeOpenPanelClosed": true]); exit(0)
    }
    guard panels.count == 1 else { fail("Expected one native open-panel sheet", 28) }
    let panel = panels[0]
    let panelRows = tree(panel).map { $0.0 }
    if mode == "picker-ready" {
        try emit(["nativeOpenPanel": true, "role": "AXSheet", "identifier": "open-panel"]); exit(0)
    }
    if mode == "picker-go" {
        let raised = AXUIElementPerformAction(panel, kAXRaiseAction as CFString)
        guard raised == .success else { fail("Could not raise the native picker sheet", 28) }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 5, keyDown: true)!
        down.flags = [.maskCommand, .maskShift]; down.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 5, keyDown: false)!
        up.flags = [.maskCommand, .maskShift]; up.post(tap: .cghidEventTap)
        try emit(["nativeSheetRaiseResult": raised.rawValue, "requestedShortcut": "Command-Shift-G",
            "verification": "Next operation must observe the native Go to Folder editor"]); exit(0)
    }
    if ["picker-editor", "picker-path", "picker-confirm"].contains(mode) {
        // Require native Go to Folder context before touching an editable field.
        let contexts = panelRows.filter { element in
            ["AXSheet", "AXDialog", "AXPopover"].contains(attr(element, "AXRole") as? String ?? "") &&
                tree(element).flatMap { labels($0.0) }.map(normalized).contains {
                    ["Go to the folder:", "Go to Folder", "Go to folder:"].contains($0)
                }
        }
        var editors: [AXUIElement] = []
        for context in contexts {
            for (element, _) in tree(context) {
                guard ["AXTextField", "AXComboBox"].contains(attr(element, "AXRole") as? String ?? ""),
                      (attr(element, "AXIdentifier") as? String) != "Search", visible(element), hasBounds(element) else { continue }
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
                      settable.boolValue, !editors.contains(where: { CFEqual($0, element) }) else { continue }
                editors.append(element)
            }
        }
        guard editors.count == 1 else { fail("Expected one editable native Go to Folder field in verified context", 29) }
        let editor = editors[0]
        if mode == "picker-editor" {
            try emit(["nativeGoToFolderEditor": true, "role": attr(editor, "AXRole") as? String ?? "",
                "identifier": attr(editor, "AXIdentifier") as? String ?? "", "value": attr(editor, "AXValue") as? String ?? ""]); exit(0)
        }
        guard args.count == 4, args[3].hasPrefix("/") else { fail("Native picker operation requires an absolute fixture path", 29) }
        let expected = args[3]
        if mode == "picker-path" {
            let result = AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, expected as CFString)
            let readback = attr(editor, "AXValue") as? String ?? ""
            try emit(["setResult": result.rawValue, "expectedPath": expected, "readback": readback])
            guard result == .success, readback == expected else { fail("Native path editor write/readback failed", 29) }
            exit(0)
        }
        guard (attr(editor, "AXValue") as? String) == expected else { fail("Go to Folder path changed before confirm", 29) }
        let goButtons = panelRows.filter {
            (attr($0, "AXRole") as? String) == "AXButton" && labels($0).contains("Go") && visible($0) && hasBounds($0) && actions($0).contains("AXPress")
        }
        let target: AXUIElement
        let action: String
        if goButtons.count == 1 { target = goButtons[0]; action = "AXPress" }
        else if goButtons.isEmpty, actions(editor).contains("AXConfirm") { target = editor; action = "AXConfirm" }
        else { fail("No unique native Go to Folder confirmation control", 29) }
        let result = AXUIElementPerformAction(target, action as CFString)
        try emit(["expectedPath": expected, "confirmationAction": action, "result": result.rawValue])
        guard result == .success else { fail("Native path confirmation failed", 29) }
        exit(0)
    }
    if ["picker-selected", "picker-open"].contains(mode) {
        guard args.count == 4 else { fail("Expected the fixture filename", 30) }
        let filename = args[3]
        var selected: [AXUIElement] = []
        for element in panelRows {
            if (attr(element, "AXSelected") as? Bool) == true { selected.append(element) }
            selected += attr(element, "AXSelectedChildren") as? [AXUIElement] ?? []
        }
        let named = selected.filter { tree($0).flatMap { labels($0.0) }.contains(filename) }
        let open = panelRows.filter {
            (attr($0, "AXRole") as? String) == "AXButton" && (attr($0, "AXIdentifier") as? String) == "OKButton" &&
                labels($0).contains("Open") && (attr($0, "AXEnabled") as? Bool) == true && hasBounds($0) && actions($0).contains("AXPress")
        }
        guard !named.isEmpty, open.count == 1 else { fail("Named native fixture selection or enabled open-panel OKButton unavailable", 30) }
        try emit(["selectedFixture": filename, "selectedNativeRoles": named.map { attr($0, "AXRole") as? String ?? "" },
            "selectedNativeURLs": named.compactMap { attr($0, "AXURL").map { String(describing: $0) } },
            "nativeOpenRole": "AXButton", "nativeOpenIdentifier": "OKButton", "nativeOpenEnabled": true])
        if mode == "picker-open" {
            let result = AXUIElementPerformAction(open[0], kAXPressAction as CFString)
            guard result == .success else { fail("Native open-panel OKButton press failed", 30) }
            print("Pressed enabled native picker OKButton for selected fixture: \(filename)")
        }
        exit(0)
    }
    fail("Unknown picker operation", 28)
}
if mode == "count-absent" {
    let counts = rows.filter { visible($0.0) }.flatMap { labels($0.0) }.flatMap { $0.components(separatedBy: .newlines) }
        .filter { $0.range(of: "^Files:\\s*[0-9]+$", options: .regularExpression) != nil }
    try emit(["visibleSelectionCounts": counts])
    guard counts.isEmpty else { fail("Unexpected selection count in an expected empty selection", 27) }
    exit(0)
}
if mode == "dump" {
    let elements: [[String: Any]] = rows.map { element, depth in
        var row: [String: Any] = ["depth": depth, "actions": actions(element)]
        for name in ["AXRole", "AXTitle", "AXDescription", "AXIdentifier", "AXValue", "AXEnabled", "AXHidden", "AXSelected", "AXFocused", "AXURL", "AXPosition", "AXSize"] {
            if let value = attr(element, name) { row[name] = String(describing: value) }
        }
        return row
    }
    let data = try JSONSerialization.data(withJSONObject: ["pid": app.processIdentifier, "bundle": args[1], "active": app.isActive, "hidden": app.isHidden, "elements": elements], options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}
guard args.count == 4 else { fail("This operation requires exactly one label") }
let label = args[3]
if mode == "key" {
    guard app.isActive else { fail("Target app must be frontmost before keyboard input", 12) }
    let key: CGKeyCode
    let flags: CGEventFlags
    switch label {
    case "go": key = 5; flags = [.maskCommand, .maskShift]
    case "return": key = 36; flags = []
    case "escape": key = 53; flags = []
    default:
        let text = Array(label.utf16)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        text.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!) }
        event.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        up.post(tap: .cghidEventTap)
        exit(0)
    }
    let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
    down.flags = flags; down.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)!
    up.flags = flags; up.post(tap: .cghidEventTap)
    exit(0)
}
if mode == "contains" || mode == "absent" {
    let found = rows.contains { visible($0.0) && labels($0.0).contains { text in
        text == label || text.components(separatedBy: .newlines).contains(label)
    } }
    guard found == (mode == "contains") else { fail("Visible label assertion failed: \(mode) \(label)", 20) }
    print("Visible label assertion passed: \(mode) \(label)")
    exit(0)
}
let action = mode == "menu" ? "AXShowMenu" : "AXPress"
guard ["menu", "press"].contains(mode) else { fail("Unknown operation") }
let matches = rows.map { $0.0 }.filter { element in
    guard visible(element), actions(element).contains(action) else { return false }
    if args[1] != "com.apple.finder", mode == "press", (attr(element, "AXRole") as? String) == "AXMenuItem" { return false }
    if label == "LocalSend" && (attr(element, "AXRole") as? String) == "AXMenuItem" {
        return labels(element).contains {
            ["LocalSend", "LocalSend.app", "LocalSend (1.18.2)", "LocalSend.app (1.18.2)"].contains($0)
        }
    }
    if args[1] != "com.apple.finder", mode == "press", ["Send", "Receive"].contains(label),
       (attr(element, "AXRole") as? String) == "AXButton" {
        let expected = label == "Send" ? "Send\nTab 2 of 3" : "Receive\nTab 1 of 3"
        return labels(element).contains(expected)
    }
    return labels(element).contains(label)
}
if mode == "menu", matches.isEmpty, args[1] == "com.apple.finder" {
    // Some Finder views expose a selected icon without AXShowMenu. Use its native
    // bounds for a right-click, never a guessed screen position.
    let candidates = rows.map { $0.0 }.filter {
        visible($0) && labels($0).contains(label) && (attr($0, "AXSelected") as? Bool) == true
    }
    guard candidates.count == 1, app.isActive,
          let position = attr(candidates[0], "AXPosition"),
          let size = attr(candidates[0], "AXSize") else {
        fail("No unique selected Finder item with native bounds", 23)
    }
    guard CFGetTypeID(position as AnyObject) == AXValueGetTypeID(),
          CFGetTypeID(size as AnyObject) == AXValueGetTypeID() else { fail("Finder bounds unavailable", 23) }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          dimensions.width > 0, dimensions.height > 0 else { fail("Finder bounds invalid", 23) }
    point.x += dimensions.width / 2; point.y += dimensions.height / 2
    CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)!.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)!.post(tap: .cghidEventTap)
    print("Native right-click on selected Finder item: \(label) at \(point)")
    exit(0)
}
guard matches.count == 1 else { fail("Expected one visible \(action) target for \(label); found \(matches.count)", 21) }
let status = AXUIElementPerformAction(matches[0], action as CFString)
guard status == .success else { fail("\(action) failed: \(status.rawValue)", 22) }
print("Performed \(action): \(label)")
