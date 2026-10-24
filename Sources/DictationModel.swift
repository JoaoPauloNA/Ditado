import AppKit
import AVFoundation
import Combine
import Security
import Darwin

struct DictationStorage {
    let root: URL
    init(root: URL? = nil) {
        let accountHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        self.root = root ?? URL(fileURLWithPath: accountHome).appendingPathComponent("Library/Application Support/Ditado")
    }
    func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
    }
}

enum DictationKeychain {
    private static func query(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.ditado.transcription",
         kSecAttrAccount as String: endpoint]
    }
    static func read(endpoint: String) throws -> String {
        var request = query(endpoint)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw DictationError.message("Não foi possível ler a chave no Chaves do macOS.")
        }
        return key
    }
    static func save(_ key: String, endpoint: String) throws {
        let request = query(endpoint)
        if key.isEmpty {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw DictationError.message("Não foi possível remover a chave salva.")
            }
            return
        }
        let values = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(request as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = request.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw DictationError.message("Não foi possível salvar a chave no Chaves do macOS.")
            }
        } else if status != errSecSuccess { throw DictationError.message("Não foi possível atualizar a chave salva.") }
    }
}

@MainActor
final class DictationModel: ObservableObject {
    @Published var settings = DictationSettings()
    @Published var text = ""
    @Published var original = ""
    @Published var history: [DictationRecord] = []
    @Published var profiles: [PainelProfile] = []
    @Published var models: [String] = []
    @Published var apiKey = ""
    @Published var status = "Pronto para ouvir"
    @Published var error: String?
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var loadingModels = false
    @Published var elapsed: TimeInterval = 0
    @Published var levels = Array(repeating: CGFloat(0.04), count: 42)
    @Published var shortcutStatus = "⌃ ⇧ Espaço"
    @Published var isEditingShortcut = false
    /// True when recording was started by double tap or by the button: a new press stops it.
    @Published var handsFree = false
    private var keyIsDown = false
    private var pressStartedDictation = false
    private var pressedAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    static let tapLimit: TimeInterval = 0.3
    static let doubleTapWindow: TimeInterval = 0.5
    var checkShortcut: ((ShortcutConfiguration) throws -> Void)?
    var changeShortcut: ((ShortcutConfiguration) throws -> Void)?
    @Published var canRetry = false
    @Published var accessibilityGranted = false
    private let storage = DictationStorage()
    private let painel = PainelConnectionStore()
    private let api = DictationAPI()
    private let local = LocalSpeech()
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var audioURL: URL?
    private var activeSettings = DictationSettings()
    private var activeKey = ""
    private let automaticPaste = AutomaticPaste()
    private var pasteTarget: PasteTarget?
    var isBusy: Bool { isRecording || isProcessing }

    init() {
        do {
            settings = try storage.load(DictationSettings.self, name: "settings.json") ?? DictationSettings()
            history = try storage.load([DictationRecord].self, name: "history.json") ?? []
        } catch { self.error = "Não foi possível carregar os dados anteriores. Os arquivos foram preservados." }
        reloadProfiles()
        refreshPastePermission()
    }

    func refreshPastePermission() { accessibilityGranted = automaticPaste.hasPermission }
    func allowAutomaticPaste() { automaticPaste.requestPermission(); refreshPastePermission() }

    func persistShortcut(_ shortcut: ShortcutConfiguration) throws {
        var updated = settings
        updated.shortcut = shortcut
        try storage.save(updated, name: "settings.json")
        settings = updated
    }

    func saveSettings() {
        do { try storage.save(settings, name: "settings.json") }
        catch { self.error = "Não foi possível salvar as configurações: \(error.localizedDescription)" }
    }
    func saveKey() {
        do {
            _ = try APIConnection(endpoint: settings.apiEndpoint, key: apiKey)
            try DictationKeychain.save(apiKey, endpoint: settings.apiEndpoint)
            apiKey = ""
            status = "Chave atualizada no Chaves do macOS"
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func reloadProfiles() {
        do { profiles = try painel.profiles() }
        catch { self.error = "Não foi possível ler as conexões do Painel CLI." }
    }
    func loadModels() {
        guard !loadingModels, let id = settings.painelProfileID else { return }
        loadingModels = true
        error = nil
        Task {
            defer { loadingModels = false }
            do {
                let connection = try painel.connection(id: id)
                let result = try await api.models(connection: connection)
                guard settings.painelProfileID == id else { return }
                models = result
                if !result.contains(settings.painelModel) { settings.painelModel = result.first ?? "" }
                if result.isEmpty { throw DictationError.message("Este perfil não anunciou modelos. Confira o login no Painel CLI.") }
                status = "\(result.count) modelos disponíveis no Painel CLI"
                saveSettings()
            } catch { self.error = "Não foi possível consultar o perfil. Verifique se o proxy está ativo no Painel CLI. \(error.localizedDescription)" }
        }
    }

    func toggle() {
        guard !isEditingShortcut else { return }
        if isRecording { stop() } else if !isProcessing { handsFree = true; start() }
    }
    /// Hold to talk: recording lasts while the shortcut is held. Double tap starts hands-free
    /// recording; the next press stops and pastes.
    func shortcutPressed() {
        guard !isEditingShortcut, !keyIsDown else { return }
        keyIsDown = true
        pressedAt = Date()
        pressStartedDictation = false
        if isRecording { stop(); return }
        guard !isProcessing else { return }
        pressStartedDictation = true
        handsFree = pressedAt.timeIntervalSince(lastTapAt) <= Self.doubleTapWindow
        if handsFree { lastTapAt = .distantPast }
        start()
    }
    func shortcutReleased() {
        guard keyIsDown else { return }
        keyIsDown = false
        guard pressStartedDictation, !handsFree, isBusy else { return }
        if Date().timeIntervalSince(pressedAt) < Self.tapLimit {
            lastTapAt = Date()
            cancel()
            status = "Toque de novo e segure para ditar sem segurar"
        } else if isRecording { stop() }
        // Still preparing the microphone: start() stops as soon as recording begins.
    }
    private func start() {
        isProcessing = true
        error = nil
        status = "Preparando microfone…"
        let token = UUID()
        generation = token
        activeSettings = settings
        refreshPastePermission()
        pasteTarget = settings.autoPaste ? automaticPaste.captureTarget() : nil
        job = Task { [self] in
            do {
                if activeSettings.provider == .apple { try await local.prepare(language: activeSettings.language) }
                else {
                    _ = try APIConnection(endpoint: activeSettings.endpoint, localOnly: activeSettings.provider == .whisper)
                    activeKey = activeSettings.provider == .api
                        ? (apiKey.isEmpty ? try DictationKeychain.read(endpoint: activeSettings.apiEndpoint) : apiKey) : ""
                    _ = try api.transcriptionRequest(audio: Data(repeating: 0, count: 45), settings: activeSettings, key: activeKey)
                }
                try Task.checkCancellation()
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard generation == token else { return }
                guard allowed else { throw DictationError.message("Autorize o microfone para Ditado em Ajustes do Sistema → Privacidade e Segurança → Microfone.") }
                discardAudio()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ditado-\(UUID().uuidString).wav")
                audioURL = url
                recorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                ])
                recorder?.isMeteringEnabled = true
                guard recorder?.record() == true else { throw DictationError.message("Não foi possível iniciar o microfone.") }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                elapsed = 0
                isRecording = true
                isProcessing = false
                canRetry = false
                status = handsFree ? "Ouvindo · toque no atalho para parar" : "Ouvindo · solte para colar"
                timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateMeter() }
                }
                RunLoop.main.add(timer!, forMode: .common)
                if !keyIsDown && !handsFree { stop() }
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                recorder?.stop()
                recorder = nil
                discardAudio()
                isProcessing = false
                isRecording = false
                self.error = error.localizedDescription
                status = "Confira a conexão"
            }
        }
    }

    private func updateMeter() {
        guard isRecording, let recorder else { return }
        guard recorder.isRecording else {
            cancel()
            error = "O microfone foi interrompido. Inicie um novo ditado."
            return
        }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        let level = CGFloat(pow(10, recorder.averagePower(forChannel: 0) / 25))
        levels.removeFirst()
        levels.append(max(0.04, min(1, level)))
        if elapsed >= 300 { stop() }
    }
    func stop() {
        guard isRecording else { return }
        elapsed = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        handsFree = false
        if elapsed < 0.4 {
            discardAudio()
            status = "Ditado muito curto. Tente falar por mais tempo."
            return
        }
        process()
    }
    func retry() { guard canRetry, !isBusy else { return }; process() }
    private func process() {
        guard let audioURL else { return }
        isProcessing = true
        canRetry = false
        error = nil
        status = "Transcrevendo…"
        let token = generation
        let snapshot = activeSettings
        let key = activeKey
        let duration = elapsed
        let target = pasteTarget
        job = Task {
            do {
                let raw: String
                if snapshot.provider == .apple { raw = try await local.transcribe(url: audioURL, language: snapshot.language) }
                else { raw = try await api.transcribe(audio: Data(contentsOf: audioURL), settings: snapshot, key: key) }
                try Task.checkCancellation()
                guard generation == token else { return }
                original = raw
                text = raw
                var output = raw
                if snapshot.correctWithPainel {
                    status = "Revisando pelo Painel CLI…"
                    do {
                        guard let id = snapshot.painelProfileID else { throw DictationError.message("Escolha um perfil do Painel CLI nas conexões.") }
                        output = try await api.correct(raw, model: snapshot.painelModel, connection: painel.connection(id: id))
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        self.error = "A revisão não foi concluída; seu ditado original foi preservado. \(error.localizedDescription)"
                    }
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                text = output
                copy()
                if snapshot.autoPaste {
                    let result = try await automaticPaste.insert(output, into: target)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    status = result.status
                    refreshPastePermission()
                } else { status = "Texto copiado · cole com ⌘ V" }
                if snapshot.keepHistory {
                    history.insert(DictationRecord(original: raw, text: output, provider: snapshot.provider.title, duration: duration), at: 0)
                    history = Array(history.prefix(100))
                    do { try storage.save(history, name: "history.json") }
                    catch { self.error = "Texto copiado, mas o histórico não pôde ser salvo." }
                }
                discardAudio()
                activeKey = ""
                pasteTarget = nil
                isProcessing = false
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                isProcessing = false
                canRetry = true
                self.error = error.localizedDescription
                status = "Não foi possível transcrever · você pode tentar novamente"
            }
        }
    }
    func cancel() {
        generation = UUID()
        job?.cancel()
        local.cancel()
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        isProcessing = false
        handsFree = false
        canRetry = false
        activeKey = ""
        pasteTarget = nil
        discardAudio()
        status = "Ditado cancelado"
    }
    func copy(_ value: String? = nil) {
        let output = value ?? text
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }
    func clearHistory() {
        do { try storage.save([DictationRecord](), name: "history.json"); history = [] }
        catch { self.error = "Não foi possível apagar o histórico." }
    }
    func openPainel() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.painelcli.desktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else { error = "Abra o Painel CLI pela pasta em que ele está instalado." }
    }
    private func discardAudio() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }
}
