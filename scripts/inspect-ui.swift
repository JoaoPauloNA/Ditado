import AppKit
import ApplicationServices

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "app.ditado.desktop").first else {
    fputs("Ditado is not running\n", stderr)
    exit(1)
}
let element = AXUIElementCreateApplication(app.processIdentifier)
func value(_ node: AXUIElement, _ key: CFString) -> CFTypeRef? {
    var output: CFTypeRef?
    AXUIElementCopyAttributeValue(node, key, &output)
    return output
}
func walk(_ node: AXUIElement, _ depth: Int = 0) {
    guard depth < 16 else { return }
    let role = value(node, kAXRoleAttribute as CFString) as? String ?? ""
    let title = value(node, kAXTitleAttribute as CFString) as? String ?? ""
    let description = value(node, kAXDescriptionAttribute as CFString) as? String ?? ""
    let text = value(node, kAXValueAttribute as CFString) as? String ?? ""
    // This script inspects only Ditado's visible UI, not other applications.
    if !title.isEmpty || !description.isEmpty || !text.isEmpty {
        print(String(repeating: " ", count: depth) + [role, title, description, text].filter { !$0.isEmpty }.joined(separator: " | "))
    }
    if let children = value(node, kAXChildrenAttribute as CFString) as? [AXUIElement] {
        children.forEach { walk($0, depth + 1) }
    }
}
func selectTab(_ name: String, in node: AXUIElement, parents: [AXUIElement] = []) -> Bool {
    let title = value(node, kAXTitleAttribute as CFString) as? String ?? ""
    let text = value(node, kAXValueAttribute as CFString) as? String ?? ""
    if title == name || text == name {
        for parent in parents.reversed() {
            let role = value(parent, kAXRoleAttribute as CFString) as? String ?? ""
            if role == "AXRow" {
                return AXUIElementSetAttributeValue(parent, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
            }
        }
    }
    if let children = value(node, kAXChildrenAttribute as CFString) as? [AXUIElement] {
        for child in children where selectTab(name, in: child, parents: parents + [node]) { return true }
    }
    return false
}
if let windows = value(element, kAXWindowsAttribute as CFString) as? [AXUIElement] {
    if CommandLine.arguments.count == 2 {
        let tab = CommandLine.arguments[1]
        guard ["Ditado", "Conexões", "Histórico"].contains(tab), let window = windows.first,
              selectTab(tab, in: window) else { fputs("Tab selection failed\n", stderr); exit(2) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    print("Ditado windows: \(windows.count)")
    for window in windows { walk(window) }
} else { print("UI accessibility unavailable for this process") }
let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier {
    if let id = window[kCGWindowNumber as String] { print("Ditado window ID: \(id)") }
}
