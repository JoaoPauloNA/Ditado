import AppKit
import Carbon

enum ShortcutError: LocalizedError {
    case invalid(String), systemConflict, occupied, registration(OSStatus), systemCheckFailed, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .systemConflict: return "Essa combinação já está ativada nos atalhos do macOS. Escolha outra."
        case .occupied: return "Essa combinação está reservada exclusivamente por outro aplicativo. O atalho anterior foi mantido."
        case .registration(let code): return "O macOS não permitiu registrar esta combinação (\(code)). O atalho anterior foi mantido."
        case .systemCheckFailed: return "Não foi possível verificar os atalhos do macOS. Tente novamente antes de salvar."
        case .unavailable: return "O controle de atalhos não está disponível. Reinicie o BlabberType e tente novamente."
        }
    }
}

extension ShortcutConfiguration {
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers & Self.control != 0 { result |= UInt32(controlKey) }
        if modifiers & Self.option != 0 { result |= UInt32(optionKey) }
        if modifiers & Self.shift != 0 { result |= UInt32(shiftKey) }
        if modifiers & Self.command != 0 { result |= UInt32(cmdKey) }
        return result
    }
}

/// Checks system shortcuts and probes exclusive ownership, then registers without
/// exclusivity so this app cannot permanently mute another app's non-exclusive key.
/// macOS does not expose other apps' non-exclusive registrations to this API.
@MainActor
final class ShortcutRegistration {
    private(set) var current: ShortcutConfiguration?
    private(set) var activeID: UInt32 = 0
    private var reference: EventHotKeyRef?
    private var nextID: UInt32 = 1
    private var retired: [EventHotKeyRef] = []
    private let systemKeys: @MainActor () throws -> [(code: UInt32, modifiers: UInt32)]
    static let signature: OSType = 0x44495441

    init(systemKeys: @escaping @MainActor () throws -> [(code: UInt32, modifiers: UInt32)] = { try ShortcutRegistration.enabledSystemKeys() }) {
        self.systemKeys = systemKeys
    }
    func check(_ shortcut: ShortcutConfiguration) throws {
        try validate(shortcut)
        if shortcut == current, reference != nil { return }
        try probeExclusiveOwnership(shortcut)
    }
    func replace(with shortcut: ShortcutConfiguration, persist: () throws -> Void) throws {
        try validate(shortcut)
        if current == shortcut, reference != nil { return }
        let (candidate, identifier) = try reserve(shortcut)
        do { try persist() }
        catch { UnregisterEventHotKey(candidate); throw error }
        let previous = reference
        reference = candidate
        current = shortcut
        activeID = identifier
        if let previous, UnregisterEventHotKey(previous) != noErr { retired.append(previous) }
    }
    func stop() {
        if let reference { UnregisterEventHotKey(reference) }
        retired.forEach { UnregisterEventHotKey($0) }
        retired = []
        reference = nil
        current = nil
        activeID = 0
    }
    func matches(_ event: EventHotKeyID) -> Bool {
        reference != nil && event.signature == Self.signature && event.id == activeID
    }
    private func validate(_ shortcut: ShortcutConfiguration) throws {
        if let error = shortcut.validationError { throw ShortcutError.invalid(error) }
        let modifiersMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        if try systemKeys().contains(where: { $0.code == shortcut.keyCode && $0.modifiers & modifiersMask == shortcut.carbonModifiers }) {
            throw ShortcutError.systemConflict
        }
    }
    private func reserve(_ shortcut: ShortcutConfiguration) throws -> (EventHotKeyRef, UInt32) {
        try probeExclusiveOwnership(shortcut)
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        var candidate: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id,
                                        GetApplicationEventTarget(), 0, &candidate)
        if result == eventHotKeyExistsErr { throw ShortcutError.occupied }
        guard result == noErr, let candidate else { throw ShortcutError.registration(result) }
        return (candidate, id.id)
    }
    private func probeExclusiveOwnership(_ shortcut: ShortcutConfiguration) throws {
        var probe: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                        EventHotKeyID(signature: 0x4454434b, id: nextID),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &probe)
        if result == eventHotKeyExistsErr { throw ShortcutError.occupied }
        guard result == noErr, let probe else { throw ShortcutError.registration(result) }
        let released = UnregisterEventHotKey(probe)
        guard released == noErr else { retired.append(probe); throw ShortcutError.registration(released) }
    }
    static func enabledSystemKeys() throws -> [(code: UInt32, modifiers: UInt32)] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let array else { throw ShortcutError.systemCheckFailed }
        guard let entries = array.takeRetainedValue() as? [[String: Any]] else { throw ShortcutError.systemCheckFailed }
        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let flags = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return nil }
            return (code.uint32Value, flags.uint32Value)
        }
    }
}
