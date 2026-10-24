import AppKit
import ApplicationServices

@main
struct PasteTests {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]),
              let app = NSRunningApplication(processIdentifier: pid) else { fatalError("Missing fixture PID") }
        var checks = 0
        func expect(_ condition: Bool, _ name: String) {
            guard condition else { fatalError("FAIL: \(name)") }
            checks += 1
        }
        func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
            var output: CFTypeRef?
            AXUIElementCopyAttributeValue(node, key as CFString, &output)
            return output
        }
        func findEditor(_ node: AXUIElement) -> AXUIElement? {
            if attribute(node, kAXRoleAttribute) as? String == kAXTextAreaRole { return node }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { if let found = findEditor(child) { return found } }
            }
            return nil
        }
        let service = AutomaticPaste()
        guard service.hasPermission else { print("Native paste test needs Accessibility for the test runner."); exit(3) }
        let application = AXUIElementCreateApplication(pid)
        guard let editor = findEditor(application) else { fatalError("Fixture editor unavailable") }
        expect(AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
               "focus only the controlled fixture editor")
        var selected = CFRange(location: 6, length: 4)
        let rangeValue = AXValueCreate(.cfRange, &selected)!
        expect(AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success,
               "select synthetic fixture text")
        guard let target = service.captureTarget(in: app) else { fatalError("Cannot capture native text target") }
        expect(target.pid == pid && target.range?.location == 6 && target.range?.length == 4,
               "capture PID, field and selection")
        expect(service.replaceSelection("voz ☕️", in: target), "insert Unicode through native Accessibility")
        expect(attribute(editor, kAXValueAttribute) as? String == "Antes voz ☕️ depois", "replace selection without replacing surrounding text")
        expect(!service.replaceSelection("duplicado", in: target), "reject stale selection after insertion")
        guard let caret = service.captureTarget(in: app) else { fatalError("Cannot capture updated caret") }
        expect(service.replaceSelection("!", in: caret), "insert at empty caret")
        expect(attribute(editor, kAXValueAttribute) as? String == "Antes voz ☕️! depois", "caret insertion preserves existing text")
        let untrusted = AutomaticPaste(isTrusted: { false })
        expect(untrusted.captureTarget(in: app) == nil, "missing permission does not capture a target")
        let denied = try await untrusted.insert("não inserir", into: caret)
        expect(denied == .permissionRequired, "missing permission reports clipboard fallback")
        guard let backgroundTarget = service.captureTarget(in: app) else { fatalError("Missing background target") }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID != pid && frontPID != ProcessInfo.processInfo.processIdentifier {
            let result = try await service.insert("não inserir", into: backgroundTarget)
            expect(result == .focusChanged, "do not activate or paste into another foreground application")
            expect(attribute(editor, kAXValueAttribute) as? String == "Antes voz ☕️! depois", "focus change leaves destination untouched")
        }
        let cancelled = Task { @MainActor in try await service.insert("cancelado", into: backgroundTarget) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation was ignored") }
        catch is CancellationError { checks += 1 }
        func findOther(_ node: AXUIElement) -> AXUIElement? {
            if attribute(node, kAXRoleAttribute) as? String == kAXTextFieldRole { return node }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { if let found = findOther(child) { return found } }
            }
            return nil
        }
        guard let other = findOther(application) else { fatalError("Fixture second field unavailable") }
        expect(AXUIElementSetAttributeValue(other, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
               "focus second fixture field")
        expect(!service.replaceSelection("destino incorreto", in: backgroundTarget), "reject changed focused field")
        expect(attribute(editor, kAXValueAttribute) as? String == "Antes voz ☕️! depois", "original field unchanged after focus switch")
        expect(attribute(other, kAXValueAttribute) as? String == "Outro campo", "new focused field is never overwritten")
        print("PASS: \(checks) native paste checks. Only the controlled fixture was edited; no global keyboard events or microphone used.")
    }
}
