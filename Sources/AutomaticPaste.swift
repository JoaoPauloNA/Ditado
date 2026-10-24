import AppKit
import ApplicationServices
import Carbon

struct PasteTarget {
    let pid: pid_t
    let launchDate: Date?
    let element: AXUIElement
    let range: CFRange?
}

enum PasteResult: Equatable {
    case inserted, shortcutSent, permissionRequired, noTarget, focusChanged, unavailable

    var status: String {
        switch self {
        case .inserted: return "Texto inserido no campo de destino"
        case .shortcutSent: return "Colagem enviada ao campo de destino"
        case .permissionRequired: return "Texto copiado · permita Acessibilidade para colar automaticamente"
        case .noTarget: return "Texto copiado · selecione um campo e inicie pelo atalho"
        case .focusChanged: return "O campo de destino mudou · texto copiado para colar com ⌘ V"
        case .unavailable: return "Este campo não aceitou a colagem · texto copiado para colar com ⌘ V"
        }
    }
}

/// Retains the focused element and selection, never the contents of another app.
@MainActor
final class AutomaticPaste {
    private var lastExternalApplication: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let isTrusted: () -> Bool

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.remember(app) }
        }
    }
    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var hasPermission: Bool { isTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ownPID, app.activationPolicy == .regular else { return }
        lastExternalApplication = app
    }

    func captureTarget() -> PasteTarget? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.processIdentifier == ownPID ? lastExternalApplication : frontmost
        guard let app else { return nil }
        return captureTarget(in: app)
    }

    func captureTarget(in app: NSRunningApplication) -> PasteTarget? {
        guard isTrusted(), !app.isTerminated, app.processIdentifier != ownPID,
              let element = Self.focusedElement(pid: app.processIdentifier), Self.isTextInput(element) else { return nil }
        return PasteTarget(pid: app.processIdentifier, launchDate: app.launchDate, element: element,
                           range: Self.selection(in: element))
    }

    func insert(_ text: String, into target: PasteTarget?) async throws -> PasteResult {
        try Task.checkCancellation()
        guard isTrusted() else { return .permissionRequired }
        guard let target, !text.isEmpty else { return .noTarget }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.launchDate == target.launchDate else { return .unavailable }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if foreground == ownPID {
            // Recording via the app button may bring Ditado forward. Return only to
            // the original destination, and only while Ditado itself is frontmost.
            guard app.activate(options: []) else { return .unavailable }
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { break }
            }
        }
        try Task.checkCancellation()
        // Same app and same field. The exact cursor position is only enforced before an
        // AXSelectedText write; terminals redraw constantly and move it.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              Self.targetIsUnchanged(target, checkRange: false) else { return .focusChanged }
        switch writeSelection(text, in: target) {
        case .inserted: return .inserted
        case .failed: return .unavailable
        case .unsupported: break
        }
        // Some browser/Electron editors support paste but not AXSelectedText writes.
        // Send the shortcut only to the validated PID, never to the global event tap.
        guard Self.targetIsUnchanged(target, checkRange: false),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              NSPasteboard.general.string(forType: .string) == text,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return .unavailable }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        return .shortcutSent
    }

    /// The caller validates foreground ownership before this operation. Kept
    /// separate so native QA can exercise only its own background fixture window.
    func replaceSelection(_ text: String, in target: PasteTarget) -> Bool {
        writeSelection(text, in: target) == .inserted
    }

    private enum WriteResult { case inserted, unsupported, failed }
    private func writeSelection(_ text: String, in target: PasteTarget) -> WriteResult {
        guard isTrusted(), !text.isEmpty, Self.targetIsUnchanged(target, checkRange: false) else { return .failed }
        var settable: DarwinBoolean = false
        let capability = AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable)
        if capability == .attributeUnsupported || capability == .notImplemented { return .unsupported }
        guard capability == .success else { return .failed }
        guard settable.boolValue else { return .unsupported }
        guard Self.targetIsUnchanged(target) else { return .failed }
        let result = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString)
        if result == .success { return .inserted }
        if result == .attributeUnsupported || result == .notImplemented { return .unsupported }
        // A timed-out AX write might have succeeded. Do not risk a second insertion.
        return .failed
    }

    static func targetIsUnchanged(_ target: PasteTarget, checkRange: Bool = true) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.launchDate == target.launchDate,
              let current = focusedElement(pid: target.pid), CFEqual(current, target.element),
              isTextInput(current) else { return false }
        if checkRange, let original = target.range {
            guard let range = selection(in: current), range.location == original.location,
                  range.length == original.length else { return false }
        }
        return true
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let value = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    static func selection(in element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let wrapped = value as! AXValue
        guard AXValueGetType(wrapped) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(wrapped, .cfRange, &range) else { return nil }
        return range
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        if subrole == kAXSecureTextFieldSubrole { return false }
        if let enabled = attribute(element, kAXEnabledAttribute) as? Bool, !enabled { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) || selection(in: element) != nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
