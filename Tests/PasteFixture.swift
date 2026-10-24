import AppKit

@main
struct PasteFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 420, height: 230),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Ditado · teste de colagem"
        let editor = NSTextView(frame: NSRect(x: 15, y: 70, width: 390, height: 140))
        editor.string = "Antes café depois"
        editor.setAccessibilityLabel("Ditado QA editor")
        let other = NSTextField(string: "Outro campo")
        other.frame = NSRect(x: 15, y: 20, width: 390, height: 30)
        other.setAccessibilityLabel("Ditado QA outro campo")
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 6, length: 4))
        window.makeKey()
        window.orderBack(nil)
        print("Fixture ready: \(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        app.run()
        _ = window
    }
}
