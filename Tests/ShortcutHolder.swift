import AppKit
import Carbon

@main
struct ShortcutHolder {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        var reference: EventHotKeyRef?
        let exclusive = !CommandLine.arguments.contains("--non-exclusive")
        let status = RegisterEventHotKey(UInt32(kVK_F19), UInt32(controlKey | optionKey),
                                        EventHotKeyID(signature: 0x54455354, id: 1),
                                        GetApplicationEventTarget(), exclusive ? OptionBits(kEventHotKeyExclusive) : 0, &reference)
        guard status == noErr, let reference else { print("Holder failed: \(status)"); exit(2) }
        print("Shortcut holder ready")
        fflush(stdout)
        application.run()
        UnregisterEventHotKey(reference)
    }
}
