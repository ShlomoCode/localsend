import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func describe(_ element: AXUIElement, _ depth: Int) -> [[String: Any]] {
    guard depth < 35 else { return [] }
    var row: [String: Any] = ["depth": depth]
    for name in ["AXRole", "AXTitle", "AXDescription", "AXIdentifier", "AXValue", "AXEnabled"] {
        if let value = attribute(element, name) { row[name] = String(describing: value) }
    }
    for name in ["AXPosition", "AXSize"] {
        if let value = attribute(element, name) { row[name] = String(describing: value) }
    }
    return [row] + ((attribute(element, "AXChildren") as? [AXUIElement]) ?? []).flatMap { describe($0, depth + 1) }
}
func matches(_ element: AXUIElement, _ label: String, _ depth: Int = 0) -> [AXUIElement] {
    guard depth < 35 else { return [] }
    let role = attribute(element, "AXRole") as? String ?? ""
    let labels = ["AXTitle", "AXDescription", "AXValue"].compactMap { attribute(element, $0) as? String }
    let own = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem"].contains(role) && labels.contains(label) ? [element] : []
    return own + ((attribute(element, "AXChildren") as? [AXUIElement]) ?? []).flatMap { matches($0, label, depth + 1) }
}
func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
func focusedRoots() -> [AXUIElement] {
    var roots: [AXUIElement] = []
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 1)
    if let focused = attribute(system, "AXFocusedUIElement") {
        var element = focused as! AXUIElement
        roots.append(element)
        for _ in 0..<10 {
            guard let parent = attribute(element, "AXParent") else { break }
            element = parent as! AXUIElement
            roots.append(element)
            if ["AXWindow", "AXSheet", "AXDialog"].contains(attribute(element, "AXRole") as? String ?? "") { break }
        }
    }
    for root in roots { AXUIElementSetMessagingTimeout(root, 1) }
    return roots
}
func systemRoots() -> [AXUIElement] {
    let roots = NSWorkspace.shared.runningApplications.map { AXUIElementCreateApplication($0.processIdentifier) } + focusedRoots()
    for root in roots { AXUIElementSetMessagingTimeout(root, 1) }
    return roots
}
func normalized(_ value: String) -> String {
    value.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"").replacingOccurrences(of: "’", with: "'").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
struct PermissionCandidate {
    let button: AXUIElement
    let prompt: String
    let pid: pid_t
    let role: String
}
func enabledButtons(_ element: AXUIElement, _ label: String, _ depth: Int = 0) -> [AXUIElement] {
    guard depth < 35 else { return [] }
    let role = attribute(element, "AXRole") as? String ?? ""
    let labels = ["AXTitle", "AXDescription", "AXValue"].compactMap { attribute(element, $0) as? String }.map(normalized)
    let own = role == "AXButton" && (attribute(element, "AXEnabled") as? Bool) == true && labels.contains(label) ? [element] : []
    return own + ((attribute(element, "AXChildren") as? [AXUIElement]) ?? []).flatMap { enabledButtons($0, label, depth + 1) }
}
func networkPermissionButtons(_ element: AXUIElement, _ depth: Int = 0) -> [PermissionCandidate] {
    guard depth < 35 else { return [] }
    let role = attribute(element, "AXRole") as? String ?? ""
    var own: [PermissionCandidate] = []
    if ["AXWindow", "AXSheet", "AXDialog"].contains(role) {
        let rows = describe(element, 0)
        let labels = rows.flatMap { row in ["AXTitle", "AXDescription", "AXValue"].compactMap { row[$0] as? String } }
        let exactPrompt = "Allow \"LocalSend\" to find devices on local networks?"
        let context = normalized(labels.joined(separator: " "))
        let allow = enabledButtons(element, "Allow")
        let deny = enabledButtons(element, "Don't Allow")
        if context.contains(exactPrompt) && allow.count == 1 && deny.count == 1 {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            own = [PermissionCandidate(button: allow[0], prompt: exactPrompt, pid: pid, role: role)]
        }
    }
    return own + ((attribute(element, "AXChildren") as? [AXUIElement]) ?? []).flatMap { networkPermissionButtons($0, depth + 1) }
}
let args = CommandLine.arguments
if !AXIsProcessTrusted() { fputs("Accessibility permission unavailable\n", stderr); exit(2) }
if args[1] == "--system" {
    let inventory: [[String: Any]] = NSWorkspace.shared.runningApplications.map { app in
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        return ["pid": app.processIdentifier, "bundleIdentifier": app.bundleIdentifier ?? "", "name": app.localizedName ?? "", "elements": describe(root, 0)]
    }
    try emit(["applications": inventory, "focusedRoots": focusedRoots().map { describe($0, 0) }])
    exit(0)
}
if args[1] == "--allow-local-network" {
    var buttons: [PermissionCandidate] = []
    for candidate in systemRoots().flatMap({ networkPermissionButtons($0) }) {
        if !buttons.contains(where: { CFEqual($0.button, candidate.button) }) { buttons.append(candidate) }
    }
    guard buttons.count <= 1 else { fputs("Ambiguous LocalSend local-network permission controls\n", stderr); exit(6) }
    if buttons.isEmpty { try emit(["observed": false, "pressed": false]); exit(0) }
    let candidate = buttons[0]
    let result = AXUIElementPerformAction(candidate.button, kAXPressAction as CFString)
    try emit(["observed": true, "pressed": result == .success, "action": "Allow", "exactPrompt": candidate.prompt, "nativePromptPid": candidate.pid, "nativePromptRole": candidate.role, "otherButton": "Don't Allow", "enabledAXButton": true, "result": result.rawValue])
    exit(result == .success ? 0 : 7)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == args[1] }) else {
    fputs("Released app process unavailable\n", stderr); exit(3)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1)
if args.count > 2 && args[2] == "--enhance" {
    let key = "AXEnhancedUserInterface" as CFString
    let before = attribute(root, "AXEnhancedUserInterface").map { String(describing: $0) } ?? "unavailable"
    var settable = DarwinBoolean(false)
    let query = AXUIElementIsAttributeSettable(root, key, &settable)
    let result = query == .success && settable.boolValue ? AXUIElementSetAttributeValue(root, key, kCFBooleanTrue) : query
    let after = attribute(root, "AXEnhancedUserInterface").map { String(describing: $0) } ?? "unavailable"
    try emit(["pid": app.processIdentifier, "attribute": "AXEnhancedUserInterface", "before": before, "queryResult": query.rawValue, "settable": settable.boolValue, "attempted": query == .success && settable.boolValue, "setResult": result.rawValue, "setSucceeded": query == .success && settable.boolValue && result == .success, "after": after, "observedAfterEnabled": after == "1", "scope": "Attribute observation and setter return are separate; an enabled observation does not turn a negative setter return into success"])
    exit(0)
}
if args.count == 2 {
    let result: [String: Any] = ["pid": app.processIdentifier, "bundleIdentifier": args[1], "elements": describe(root, 0)]
    try emit(result)
} else {
    let found = matches(root, args[2])
    guard found.count == 1 else { fputs("Expected one exact semantic control; found \(found.count)\n", stderr); exit(4) }
    let result = AXUIElementPerformAction(found[0], kAXPressAction as CFString)
    guard result == .success else { fputs("AXPress failed: \(result.rawValue)\n", stderr); exit(5) }
    print("Pressed exact semantic control: \(args[2])")
}
