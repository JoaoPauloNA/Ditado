import SwiftUI
import AppKit

extension ShortcutConfiguration {
    init(event: NSEvent) {
        let flags = event.modifierFlags
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= Self.control }
        if flags.contains(.option) { mask |= Self.option }
        if flags.contains(.shift) { mask |= Self.shift }
        if flags.contains(.command) { mask |= Self.command }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mask)
    }
}

struct ShortcutRecorderButton: View {
    @Binding var draft: ShortcutConfiguration
    @Binding var message: String?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Pressione o atalho… (Esc cancela)" : "Clique e pressione o atalho") {
            recording ? stop() : start()
        }
        .controlSize(.large).frame(maxWidth: .infinity)
        .onDisappear { stop() }
    }
    private func start() {
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let captured = ShortcutConfiguration(event: event)
            if !ShortcutConfiguration.keys.contains(where: { $0.code == captured.keyCode }) {
                message = "Essa tecla não é aceita. Use letra, número, pontuação, F1–F20 ou Espaço."
            } else {
                draft = captured
            }
            stop()
            return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var model: DictationModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShortcutConfiguration
    @State private var conflict: String?

    init(model: DictationModel) {
        self.model = model
        _draft = State(initialValue: model.settings.shortcut)
    }
    private func modifier(_ flag: UInt32) -> Binding<Bool> {
        Binding(get: { draft.modifiers & flag != 0 }, set: { enabled in
            if enabled { draft.modifiers |= flag } else { draft.modifiers &= ~flag }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Atalho do ditado").font(.title2.weight(.semibold))
            Text("Clique em gravar e aperte a combinação desejada para iniciar e parar. O atalho atual continua reservado enquanto você escolhe.")
                .foregroundStyle(.secondary)
            LabeledContent("Atalho atual", value: model.shortcutStatus)
            ShortcutRecorderButton(draft: $draft, message: $conflict)
            Text("Ou ajuste manualmente:").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Toggle("⌃ Control", isOn: modifier(ShortcutConfiguration.control))
                Toggle("⌥ Option", isOn: modifier(ShortcutConfiguration.option))
                Toggle("⇧ Shift", isOn: modifier(ShortcutConfiguration.shift))
                Toggle("⌘ Command", isOn: modifier(ShortcutConfiguration.command))
            }.toggleStyle(.checkbox)
            Picker("Tecla", selection: $draft.keyCode) {
                ForEach(ShortcutConfiguration.keys) { key in Text(key.title).tag(key.code) }
            }
            Text(draft.displayName).font(.title2.monospaced()).frame(maxWidth: .infinity).padding(18)
                .background(.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            Label(conflict ?? "Nenhum conflito detectado nas verificações disponíveis. Será conferido ao salvar.",
                  systemImage: conflict == nil ? "checkmark.circle" : "exclamationmark.circle")
                .font(.callout).foregroundStyle(conflict == nil ? Color.mint : Color.orange)
            Text("Use pelo menos dois modificadores, incluindo Control ou Command (um só vale com ; , . / etc.). Recomendado: Control + Shift. Verificamos o macOS e reservas globais exclusivas. O sistema não informa todos os atalhos de outros apps, incluindo registros não exclusivos; teste a combinação nos apps que você usa.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Usar padrão") { draft = .standard }
                Button("Verificar novamente") { validate() }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar atalho") { save() }.buttonStyle(.borderedProminent).disabled(conflict != nil)
            }
        }
        .padding(28).frame(width: 550)
        .onAppear { validate() }
        .onChange(of: draft) { validate() }
    }
    private func validate() {
        do {
            guard let check = model.checkShortcut else { throw ShortcutError.unavailable }
            try check(draft)
            conflict = nil
        } catch { conflict = error.localizedDescription }
    }
    private func save() {
        do {
            guard !model.isBusy, let change = model.changeShortcut else { throw ShortcutError.unavailable }
            try change(draft)
            dismiss()
        } catch { conflict = error.localizedDescription }
    }
}
