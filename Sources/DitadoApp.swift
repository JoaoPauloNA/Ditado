import SwiftUI

@main
struct DitadoApp: App {
    @NSApplicationDelegateAdaptor(DictationAppDelegate.self) var delegate
    @StateObject private var model = DictationModel()

    var body: some Scene {
        Window("Ditado", id: "ditado") {
            DitadoView(model: model)
                .frame(minWidth: 820, minHeight: 600)
                .preferredColorScheme(.dark)
                .tint(.mint)
                .onAppear { if delegate.model == nil { delegate.installShortcut(model: model) }; model.refreshPastePermission() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPastePermission() }
                .onChange(of: model.settings) { model.saveSettings() }
        }
        .defaultSize(width: 960, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Ditado") {
                Button(model.isRecording ? "Parar e transcrever" : "Gravar") { model.toggle() }
                    .disabled(model.isProcessing)
                Button("Cancelar ditado") { model.cancel() }.disabled(!model.isBusy && !model.canRetry)
                Button("Copiar texto") { model.copy() }.disabled(model.text.isEmpty)
            }
        }
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.isRecording ? "mic.fill" : model.isProcessing ? "ellipsis.bubble" : "waveform")
                .accessibilityLabel("Ditado")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: DictationModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status)
        Button(model.isRecording ? "Parar e transcrever" : "Gravar · \(model.settings.shortcut.displayName)") { model.toggle() }
            .disabled(model.isProcessing)
        if model.isBusy { Button("Cancelar") { model.cancel() } }
        Button("Copiar último texto") { model.copy() }.disabled(model.text.isEmpty)
        Divider()
        Button("Abrir Ditado") { openWindow(id: "ditado"); NSApp.activate(ignoringOtherApps: true) }
        Button("Abrir Painel CLI") { model.openPainel() }
        Divider()
        Button("Sair") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private enum DictationTab: String, CaseIterable, Identifiable {
    case dictate = "Ditado", connections = "Conexões", history = "Histórico"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .dictate: return "waveform"; case .connections: return "point.3.connected.trianglepath.dotted"; case .history: return "clock.arrow.circlepath" }
    }
}

struct DitadoView: View {
    @ObservedObject var model: DictationModel
    @State private var tab: DictationTab? = .dictate
    @State private var confirmClear = false
    @State private var editingShortcut = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2.weight(.bold)).foregroundStyle(.mint)
                    Text("ditado").font(.title2.weight(.semibold))
                }.padding(.horizontal, 20).padding(.top, 28)
                List(DictationTab.allCases, selection: $tab) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item).padding(.vertical, 5)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sua voz, por escrito.", systemImage: "sparkle").font(.caption).foregroundStyle(.secondary)
                    Text("Conectado à sua central de modelos.").font(.caption2).foregroundStyle(.tertiary)
                    Button("Abrir Painel CLI ↗") { model.openPainel() }.buttonStyle(.plain).font(.caption).foregroundStyle(.mint)
                }.padding(20)
            }.navigationSplitViewColumnWidth(200)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Fechar aviso")
                    }.padding(16).background(.orange.opacity(0.08))
                }
                switch tab ?? .dictate {
                case .dictate: dictation
                case .connections: connections
                case .history: history
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .confirmationDialog("Apagar todos os textos do histórico?", isPresented: $confirmClear) {
            Button("Apagar histórico", role: .destructive) { model.clearHistory() }
            Button("Cancelar", role: .cancel) { }
        } message: { Text("Os textos salvos neste Mac serão removidos.") }
        .sheet(isPresented: $editingShortcut, onDismiss: { model.isEditingShortcut = false }) {
            ShortcutSettingsView(model: model)
        }
    }

    private func title(_ heading: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dictation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                title("É só falar.", subtitle: "Transforme suas ideias em texto, no seu ritmo.")
                if model.settings.autoPaste && !model.accessibilityGranted {
                    HStack(alignment: .center, spacing: 12) {
                        Label("Permita Acessibilidade para colar o ditado no campo selecionado.", systemImage: "text.cursor")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Permitir colagem automática") { model.allowAutomaticPaste() }
                    }
                    .padding(14).background(.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(spacing: 18) {
                    HStack {
                        Label(model.settings.provider.title, systemImage: model.settings.provider == .api ? "cloud" : "desktopcomputer")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.isRecording {
                            Circle().fill(.red).frame(width: 6, height: 6)
                            Text(String(format: "%02d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else { Text("ATÉ 5 MIN POR DITADO").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.tertiary) }
                    }
                    HStack(alignment: .center, spacing: 4) {
                        ForEach(Array(model.levels.enumerated()), id: \.offset) { _, value in
                            Capsule().fill(model.isRecording ? Color.mint : Color.mint.opacity(0.15))
                                .frame(width: 4, height: model.isRecording ? 4 + value * 48 : 5)
                        }
                    }.frame(height: 60).accessibilityLabel(model.isRecording ? "Nível do microfone" : "Microfone parado")
                    Button { model.toggle() } label: {
                        Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.8))
                            .frame(width: 72, height: 72)
                            .background(model.isRecording ? Color.red.opacity(0.85) : Color.mint, in: Circle())
                    }.buttonStyle(.plain).disabled(model.isProcessing)
                        .accessibilityLabel(model.isRecording ? "Parar e transcrever" : "Iniciar gravação")
                    HStack(spacing: 8) {
                        if model.isProcessing { ProgressView().controlSize(.small) }
                        Text(model.status).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Text(model.shortcutStatus).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        if model.isBusy || model.canRetry {
                            Button("Cancelar") { model.cancel() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.canRetry { Button("Tentar novamente") { model.retry() }.font(.caption) }
                    }
                }
                .padding(24).frame(maxWidth: .infinity)
                .background(Color.mint.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.mint.opacity(0.12)))

                HStack {
                    Text("Seu texto").font(.headline)
                    Spacer()
                    if !model.original.isEmpty && model.original != model.text {
                        Button("Ver original") { model.text = model.original }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.copy() } label: { Label("Copiar", systemImage: "doc.on.doc") }.disabled(model.text.isEmpty)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.text).font(.body).scrollContentBackground(.hidden)
                        .padding(10).frame(minHeight: 130).accessibilityLabel("Texto transcrito")
                    if model.text.isEmpty {
                        Text("Seu próximo ditado aparece aqui. Você pode editar antes de copiar.")
                            .foregroundStyle(.tertiary).padding(16).allowsHitTesting(false)
                    }
                }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                Label(model.settings.correctWithPainel ? "Revisão pelo Painel CLI ativada: o texto será enviado ao perfil escolhido." : model.settings.autoPaste ? "Selecione um campo e use \(model.settings.shortcut.displayName). Ao terminar, o ditado é colado ali." : "Ao terminar, o texto é copiado. Use ⌘ V para colar onde quiser.",
                      systemImage: model.settings.correctWithPainel ? "sparkles" : "doc.on.clipboard")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Uma voz. Suas conexões.", subtitle: "Escolha como transcrever e quando usar sua central de modelos.").padding(.horizontal, 32).padding(.top, 32)
            Form {
                Section("Transcrição") {
                    Picker("Reconhecimento de voz", selection: $model.settings.provider) {
                        ForEach(SpeechProvider.allCases) { provider in Text(provider.title).tag(provider) }
                    }
                    Picker("Idioma", selection: $model.settings.language) {
                        Text("Português do Brasil").tag("pt-BR")
                        Text("Inglês").tag("en-US")
                        Text("Espanhol").tag("es-ES")
                    }
                    switch model.settings.provider {
                    case .apple:
                        Text("Usa o reconhecimento do macOS, somente no dispositivo. A disponibilidade depende do idioma e dos recursos de fala instalados no Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .whisper:
                        TextField("Endereço do Whisper", text: $model.settings.whisperEndpoint)
                        Text("Conecte um whisper-server em execução neste Mac. O modelo é carregado pelo servidor; o Ditado envia WAV de 16 kHz.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .api:
                        TextField("Endereço de transcrição", text: $model.settings.apiEndpoint)
                        TextField("Modelo", text: $model.settings.apiModel)
                        SecureField("Nova chave de API", text: $model.apiKey, prompt: Text("Deixe em branco para usar a chave salva"))
                        HStack {
                            Button("Salvar chave no macOS") { model.saveKey() }.disabled(model.apiKey.isEmpty)
                            Button("Remover chave salva", role: .destructive) { model.apiKey = ""; model.saveKey() }
                        }
                        Text("O áudio será enviado ao endereço configurado. Requer uma API compatível com /audio/transcriptions; a chave é salva no Chaves do macOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Painel CLI · revisão opcional") {
                    Toggle("Corrigir pontuação e pequenos erros", isOn: $model.settings.correctWithPainel)
                    Text("Depois da transcrição, envia o texto ao modelo escolhido. Os logins e proxies continuam sendo administrados no Painel CLI.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Perfil da central", selection: $model.settings.painelProfileID) {
                        Text("Selecione um perfil").tag(UUID?.none)
                        ForEach(model.profiles) { profile in Text(profile.title).tag(Optional(profile.id)) }
                    }.onChange(of: model.settings.painelProfileID) { model.models = []; model.settings.painelModel = "" }
                    HStack {
                        Button("Atualizar perfis") { model.reloadProfiles() }
                        Button(model.loadingModels ? "Consultando…" : "Buscar modelos") { model.loadModels() }
                            .disabled(model.settings.painelProfileID == nil || model.loadingModels)
                        Spacer()
                        Button("Abrir central ↗") { model.openPainel() }
                    }
                    if !model.models.isEmpty {
                        Picker("Modelos disponíveis", selection: $model.settings.painelModel) {
                            ForEach(model.models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Modelo de revisão", text: $model.settings.painelModel, prompt: Text("Busque os modelos do perfil"))
                    if model.profiles.isEmpty {
                        Text("Nenhum perfil CLIProxy encontrado. Cadastre e ative um perfil no Painel CLI; depois clique em Atualizar perfis.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Neste Mac") {
                    LabeledContent("Atalho global") {
                        HStack {
                            Text(model.shortcutStatus)
                            Button("Alterar atalho…") { model.isEditingShortcut = true; editingShortcut = true }
                        }
                    }
                    Toggle("Colar automaticamente no campo selecionado", isOn: $model.settings.autoPaste)
                    if model.settings.autoPaste {
                        LabeledContent("Acessibilidade", value: model.accessibilityGranted ? "Permitida" : "Permissão necessária")
                        Button(model.accessibilityGranted ? "Conferir permissão de colagem" : "Permitir colagem automática") { model.allowAutomaticPaste() }
                        Text("Selecione o campo de destino antes de iniciar. Se mudar de aplicativo ou de seleção durante o ditado, o texto permanece copiado para colar manualmente.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Guardar textos no histórico local", isOn: $model.settings.keepHistory)
                    Text("Até 100 ditados. O áudio temporário é removido ao concluir ou cancelar. Desativar o histórico mantém os textos já salvos; apague-os na aba Histórico.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(model.isBusy)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                title("Suas palavras ficam aqui.", subtitle: "\(model.history.count) ditados salvos neste Mac.")
                Button("Apagar histórico", role: .destructive) { confirmClear = true }.disabled(model.history.isEmpty)
            }.padding(.horizontal, 32).padding(.top, 32)
            if model.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble").font(.system(size: 34)).foregroundStyle(.mint.opacity(0.6))
                    Text("Um espaço para suas próximas ideias.").foregroundStyle(.secondary)
                    Text("Seus ditados aparecerão aqui depois da transcrição.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.history) { record in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(record.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text("· \(record.provider)").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Button("Copiar") { model.copy(record.text) }
                        }
                        Text(record.text).textSelection(.enabled)
                        if record.text != record.original {
                            DisclosureGroup("Texto original") { Text(record.original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }.padding(.vertical, 12)
                }.listStyle(.inset)
            }
        }
    }
}
