import Foundation

final class MockProtocol: URLProtocol {
    static var responseCode = 200
    static var payload = Data()
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main
struct CoreTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DictationError.message("FAIL: \(message)") }
        checks += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch { checks += 1; return }
        throw DictationError.message("FAIL: expected rejection for \(message)")
    }
    static func rejectsAsync(_ message: String, _ action: () async throws -> Void) async throws {
        do { try await action() }
        catch { checks += 1; return }
        throw DictationError.message("FAIL: expected rejection for \(message)")
    }
    static func mock(_ json: String, code: Int = 200) {
        MockProtocol.payload = Data(json.utf8)
        MockProtocol.responseCode = code
    }

    static func main() async throws {
        let legacy = Data("{\"provider\":\"api\",\"language\":\"en-US\",\"apiModel\":\"custom-model\",\"keepHistory\":false}".utf8)
        let migrated = try JSONDecoder().decode(DictationSettings.self, from: legacy)
        try expect(migrated.autoPaste, "existing settings enable automatic paste")
        try expect(migrated.shortcut == .standard, "existing settings retain the original shortcut")
        try expect(migrated.provider == .api && migrated.apiModel == "custom-model" && !migrated.keepHistory,
                   "existing provider and history preferences preserved")
        var disabled = migrated
        disabled.autoPaste = false
        disabled.shortcut = ShortcutConfiguration(keyCode: 2, modifiers: ShortcutConfiguration.control | ShortcutConfiguration.shift)
        let roundTrip = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(disabled))
        try expect(!roundTrip.autoPaste && roundTrip.language == "en-US", "automatic paste preference persists")
        try expect(roundTrip.shortcut == disabled.shortcut, "custom shortcut persists with existing settings")
        for endpoint in ["", "file:///tmp/test", "http://remote.example/v1", "https://user:secret@example.com/v1", "https://example.com/v1#fragment"] {
            try rejects("invalid endpoint") { _ = try APIConnection(endpoint: endpoint) }
        }
        try rejects("remote local endpoint") { _ = try APIConnection(endpoint: "https://example.com/inference", localOnly: true) }
        try rejects("header injection") { _ = try APIConnection(endpoint: "https://example.com", key: "bad\r\nKey: value") }
        _ = try APIConnection(endpoint: "http://127.0.0.1:8080/inference", localOnly: true)
        _ = try APIConnection(endpoint: "http://[::1]:8080/inference", localOnly: true)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let api = DictationAPI(session: URLSession(configuration: config))
        var settings = DictationSettings()
        settings.provider = .api
        settings.apiEndpoint = "https://transcribe.example/v1/audio/transcriptions"
        let audio = Data([82, 73, 70, 70] + Array(repeating: UInt8(0), count: 32000))
        let request = try api.transcriptionRequest(audio: audio, settings: settings, key: "fixture-api-key")
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        try expect(request.httpMethod == "POST", "audio uses POST")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-api-key", "client authorization")
        try expect(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"), "model form field")
        try expect(body.contains("name=\"language\"\r\n\r\npt\r\n"), "ISO language field")
        try expect(body.contains("filename=\"ditado.wav\"\r\nContent-Type: audio/wav"), "audio metadata")
        try expect(request.httpBody!.range(of: audio) != nil, "binary audio preserved")
        try expect(!body.contains("fixture-api-key"), "key excluded from audio body")
        settings.provider = .whisper
        let localRequest = try api.transcriptionRequest(audio: audio, settings: settings, key: "")
        try expect(localRequest.url?.path == "/inference", "Whisper endpoint")
        try expect(localRequest.value(forHTTPHeaderField: "Authorization") == nil, "anonymous local Whisper")
        try expect(!String(decoding: localRequest.httpBody!, as: UTF8.self).contains("name=\"model\""), "Whisper uses the server's loaded model")
        try rejects("empty audio") { _ = try api.transcriptionRequest(audio: Data(), settings: settings, key: "") }
        try rejects("oversized audio") { _ = try api.transcriptionRequest(audio: Data(repeating: 0, count: 24_000_000), settings: settings, key: "") }

        mock("{\"text\":\" Olá, mundo! \"}")
        let text = try await api.transcribe(audio: audio, settings: settings, key: "")
        try expect(text == "Olá, mundo!", "transcription JSON decoded")
        mock("{\"text\":\" \"}")
        try await rejectsAsync("empty transcript") { _ = try await api.transcribe(audio: audio, settings: settings, key: "") }
        mock("invalid-json")
        try await rejectsAsync("malformed transcript") { _ = try await api.transcribe(audio: audio, settings: settings, key: "") }
        mock("{\"error\":\"fixture-secret-must-not-leak\"}", code: 401)
        do { _ = try await api.transcribe(audio: audio, settings: settings, key: ""); throw DictationError.message("Missing HTTP error") }
        catch {
            try expect(error.localizedDescription.contains("401"), "HTTP error classification")
            try expect(!error.localizedDescription.contains("fixture-secret"), "server error details not exposed")
        }
        let connection = try APIConnection(endpoint: "http://127.0.0.1:8317/v1", key: "fixture-client-key", localOnly: true)
        mock("{\"data\":[{\"id\":\"z-model\"},{\"id\":\"a-model\"},{\"id\":\"a-model\"}]}")
        let models = try await api.models(connection: connection)
        try expect(models == ["a-model", "z-model"], "model catalog normalized")
        try expect(MockProtocol.lastRequest?.url?.path == "/v1/models", "Painel model route")
        mock("{\"choices\":[{\"message\":{\"content\":\"Bom dia, João.\"}}]}")
        let corrected = try await api.correct("bom dia joão", model: "a-model", connection: connection)
        try expect(corrected == "Bom dia, João.", "model text response decoded")
        try expect(MockProtocol.lastRequest?.url?.path == "/v1/chat/completions", "Painel completion route")
        mock("{\"choices\":[]}")
        try await rejectsAsync("empty model response") { _ = try await api.correct("bom dia", model: "a-model", connection: connection) }
        try await rejectsAsync("unselected model") { _ = try await api.correct("bom dia", model: "", connection: connection) }
        mock("{}", code: 429)
        try await rejectsAsync("rate limit") { _ = try await api.correct("bom dia", model: "a-model", connection: connection) }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ditado-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("PainelCli/CLIProxy")
        let store = PainelConnectionStore(root: root)
        let absentProfiles = try store.profiles()
        try expect(absentProfiles.isEmpty, "no implicit profile creation")
        let id = UUID()
        let instance = root.appendingPathComponent("instances/\(id.uuidString)")
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in [root, root.appendingPathComponent("instances"), instance] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let fixture = "[{\"id\":\"\(id.uuidString)\",\"provider\":\"codex\",\"ordinal\":2,\"createdAt\":\"2026-10-23T00:00:00Z\"}]"
        try Data(fixture.utf8).write(to: root.appendingPathComponent("profiles.json"))
        let key = String(repeating: "x", count: 64)
        for (name, value) in [("port", "54901"), ("client.key", key)] {
            try Data(value.utf8).write(to: instance.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: instance.appendingPathComponent(name).path)
        }
        let profiles = try store.profiles()
        try expect(profiles.count == 1 && profiles.first?.title == "CodexCLI2", "existing Painel schema")
        let before = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        let selected = try store.connection(id: id)
        try expect(selected.url.absoluteString == "http://127.0.0.1:54901/v1" && selected.key == key, "exact selected profile connection")
        let after = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        try expect(before == after, "profile file preserved")
        try rejects("unknown profile") { _ = try store.connection(id: UUID()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: instance.appendingPathComponent("client.key").path)
        try rejects("public client key") { _ = try store.connection(id: id) }
        try FileManager.default.removeItem(at: instance.appendingPathComponent("client.key"))
        let outside = temporary.appendingPathComponent("outside.key")
        try Data(key.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: instance.appendingPathComponent("client.key"), withDestinationURL: outside)
        try rejects("symlink key") { _ = try store.connection(id: id) }
        try Data("[]".utf8).write(to: root.appendingPathComponent("profiles.json"))
        try rejects("removed profile") { _ = try store.connection(id: id) }
        print("PASS: \(checks) checks. Synthetic audio and profile fixtures only; no microphone, Keychain, real profile keys, or external API calls.")
    }
}
