import AppKit
import Carbon

@main
struct ShortcutTests {
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        var checks = 0
        func expect(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: \(name)") }; checks += 1
        }
        func rejects(_ name: String, _ block: () throws -> Void) {
            do { try block(); fatalError("FAIL: expected rejection: \(name)") }
            catch { checks += 1 }
        }
        let old = ShortcutConfiguration(keyCode: UInt32(kVK_F18), modifiers: ShortcutConfiguration.control | ShortcutConfiguration.option)
        let occupied = ShortcutConfiguration(keyCode: UInt32(kVK_F19), modifiers: ShortcutConfiguration.control | ShortcutConfiguration.option)
        if CommandLine.arguments.contains("--non-exclusive") {
            // Preserve the experimentally observed macOS limitation as a regression:
            // a successful probe cannot be presented as proof that all apps are clear.
            let checker = ShortcutRegistration(systemKeys: { [] })
            try checker.check(occupied)
            try checker.replace(with: occupied, persist: { })
            expect(checker.current == occupied, "non-exclusive registration is not detectable as a conflict")
            checker.stop()
            print("PASS: macOS limitation verified: another app's non-exclusive registration cannot be detected. UI discloses this limitation.")
            return
        }
        let replacement = ShortcutConfiguration(keyCode: UInt32(kVK_F17), modifiers: ShortcutConfiguration.control | ShortcutConfiguration.option | ShortcutConfiguration.shift)
        expect(ShortcutConfiguration.standard.displayName == "⌃ ⇧ Espaço", "default label")
        expect(old.carbonModifiers == UInt32(controlKey | optionKey), "Carbon modifier mapping")
        expect(ShortcutConfiguration(keyCode: 0, modifiers: 0).validationError != nil, "bare typing key rejected")
        expect(ShortcutConfiguration(keyCode: 0, modifiers: ShortcutConfiguration.shift).validationError != nil, "Shift-only rejected")
        expect(ShortcutConfiguration(keyCode: 0, modifiers: ShortcutConfiguration.command).validationError != nil, "common Command-only command rejected")
        expect(ShortcutConfiguration(keyCode: 6, modifiers: ShortcutConfiguration.command | ShortcutConfiguration.shift).validationError != nil, "redo shortcut protected")
        expect(ShortcutConfiguration(keyCode: 3, modifiers: ShortcutConfiguration.control | ShortcutConfiguration.command).validationError != nil, "fullscreen shortcut protected")
        expect(ShortcutConfiguration(keyCode: 41, modifiers: ShortcutConfiguration.command).validationError == nil, "Command + ; accepted")
        expect(ShortcutConfiguration(keyCode: 41, modifiers: ShortcutConfiguration.shift).validationError != nil, "Shift + ; rejected")
        expect(ShortcutConfiguration(keyCode: 999, modifiers: 5).validationError != nil, "unsupported key rejected")
        expect(ShortcutConfiguration(keyCode: 49, modifiers: 0x80000005).validationError != nil, "unknown modifier bits rejected")
        let symbolic = ShortcutRegistration(systemKeys: { [(old.keyCode, old.carbonModifiers)] })
        rejects("enabled system shortcut") { try symbolic.check(old) }
        let failedCheck = ShortcutRegistration(systemKeys: { throw ShortcutError.systemCheckFailed })
        rejects("system check failure") { try failedCheck.check(old) }
        let realSystemKeys = try ShortcutRegistration.enabledSystemKeys()
        expect(!realSystemKeys.isEmpty, "read active symbolic hotkeys from macOS")

        let registration = ShortcutRegistration(systemKeys: { [] })
        defer { registration.stop() }
        var saved: ShortcutConfiguration?
        try registration.replace(with: old) { saved = old }
        expect(registration.current == old && saved == old, "initial registration and persistence")
        let firstID = registration.activeID
        try registration.check(old)
        expect(registration.activeID == firstID, "checking current shortcut keeps its active ID")
        do {
            try registration.replace(with: occupied) { saved = occupied }
            fatalError("Expected a real cross-process conflict")
        } catch ShortcutError.occupied { checks += 1 }
        expect(registration.current == old && saved == old, "real conflict preserves old shortcut and settings")
        rejects("occupied preview") { try registration.check(occupied) }
        enum DiskFailure: Error { case full }
        rejects("failed persistence") {
            try registration.replace(with: replacement) { throw DiskFailure.full }
        }
        expect(registration.current == old && registration.activeID == firstID && saved == old,
               "disk failure leaves active registration and saved settings intact")
        // The failed replacement must have released its candidate, so a fresh
        // native reservation of that same combination must succeed.
        let probe = ShortcutRegistration(systemKeys: { [] })
        try probe.replace(with: replacement, persist: { })
        expect(probe.current == replacement, "failed save releases candidate registration")
        probe.stop()
        try registration.replace(with: replacement) { saved = replacement }
        expect(registration.current == replacement && saved == replacement, "successful replacement commits the new shortcut")
        expect(!registration.matches(EventHotKeyID(signature: ShortcutRegistration.signature, id: firstID)), "queued old hotkey events ignored")
        expect(registration.matches(EventHotKeyID(signature: ShortcutRegistration.signature, id: registration.activeID)), "current hotkey ID accepted")
        expect(!registration.matches(EventHotKeyID(signature: 0, id: registration.activeID)), "other event signatures ignored")
        try probe.replace(with: old, persist: { })
        expect(probe.current == old, "previous shortcut released only after successful replacement")
        probe.stop()
        registration.stop()
        expect(registration.current == nil && registration.activeID == 0, "stop clears active state")
        print("PASS: \(checks) shortcut checks, including a real exclusive conflict with another process and persistence rollback. No keyboard events or recordings generated.")
    }
}
