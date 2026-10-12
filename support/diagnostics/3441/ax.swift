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
let args = CommandLine.arguments
if !AXIsProcessTrusted() { fputs("Accessibility permission unavailable\n", stderr); exit(2) }
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == args[1] }) else {
    fputs("Released app process unavailable\n", stderr); exit(3)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
if args.count == 2 {
    let result: [String: Any] = ["pid": app.processIdentifier, "bundleIdentifier": args[1], "elements": describe(root, 0)]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    let found = matches(root, args[2])
    guard found.count == 1 else { fputs("Expected one exact semantic control; found \(found.count)\n", stderr); exit(4) }
    let result = AXUIElementPerformAction(found[0], kAXPressAction as CFString)
    guard result == .success else { fputs("AXPress failed: \(result.rawValue)\n", stderr); exit(5) }
    print("Pressed exact semantic control: \(args[2])")
}
