import AppKit
import ApplicationServices

// Uses only Ditado's Accessibility elements. No activation, mouse movement,
// keyboard events, microphone, or settings changes.
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "app.ditado.desktop").first else { fatalError("Ditado is not running") }
let application = AXUIElementCreateApplication(app.processIdentifier)
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &result)
    return result
}
func find(_ node: AXUIElement, role: String, text: String) -> AXUIElement? {
    let strings = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attribute(node, $0) as? String }
    if attribute(node, kAXRoleAttribute) as? String == role, strings.contains(where: { $0 == text }) { return node }
    if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children { if let result = find(child, role: role, text: text) { return result } }
    }
    return nil
}
func selectTab(_ node: AXUIElement, parents: [AXUIElement] = []) -> Bool {
    if attribute(node, kAXValueAttribute) as? String == "Conexões" {
        for parent in parents.reversed() where attribute(parent, kAXRoleAttribute) as? String == kAXRowRole {
            return AXUIElementSetAttributeValue(parent, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
        }
    }
    if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children where selectTab(child, parents: parents + [node]) { return true }
    }
    return false
}
func wait() { RunLoop.current.run(until: Date().addingTimeInterval(0.35)) }
guard let window = (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first else { fatalError("Missing Ditado window") }
if CommandLine.arguments.contains("--cancel-only") {
    guard let cancel = find(window, role: kAXButtonRole, text: "Cancelar"),
          AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success else { fatalError("Cannot dismiss editor") }
    wait()
    print("Shortcut editor dismissed; active shortcut preserved")
    exit(0)
}
guard selectTab(window) else { fatalError("Cannot open connections") }
wait()
guard let edit = find(window, role: kAXButtonRole, text: "Alterar atalho…"),
      AXUIElementPerformAction(edit, kAXPressAction as CFString) == .success else { fatalError("Shortcut edit button unavailable") }
wait()
if CommandLine.arguments.contains("--open-only") { print("Shortcut editor opened for visual QA"); exit(0) }
guard let save = find(window, role: kAXButtonRole, text: "Salvar atalho"),
      attribute(save, kAXEnabledAttribute) as? Bool == true,
      let shift = find(window, role: kAXCheckBoxRole, text: "⇧ Shift") else { fatalError("Shortcut editor controls unavailable") }
guard AXUIElementPerformAction(shift, kAXPressAction as CFString) == .success else { fatalError("Cannot test modifier selection") }
wait()
guard attribute(save, kAXEnabledAttribute) as? Bool == false else { fatalError("Invalid shortcut left Save enabled") }
guard let cancel = find(window, role: kAXButtonRole, text: "Cancelar"),
      AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success else { fatalError("Cannot cancel editor") }
wait()
print("PASS: installed UI opens the editor, validates modifiers, disables Save for an unsafe combination, and cancels without changing settings.")
