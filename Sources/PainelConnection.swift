import Foundation
import Darwin

/// Uses only the Painel CLI client interface. Never reads provider OAuth credentials,
/// management keys, or changes the profile/process configuration.
struct PainelProfile: Decodable, Identifiable, Equatable {
    let id: UUID
    let provider: String
    let ordinal: Int
    var title: String {
        let names = ["codex": "Codex", "claude": "Claude", "antigravity": "Antigravity"]
        return "\(names[provider] ?? provider)CLI\(ordinal)"
    }
}

struct PainelConnectionStore {
    let root: URL
    init(root: URL? = nil) {
        // Resolve the actual macOS account, even when launched from an isolated CLI HOME.
        let accountHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        self.root = root ?? URL(fileURLWithPath: accountHome)
            .appendingPathComponent("Library/Application Support/PainelCli/CLIProxy", isDirectory: true)
    }

    func profiles() throws -> [PainelProfile] {
        let url = root.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let profiles = try JSONDecoder().decode([PainelProfile].self, from: Data(contentsOf: url))
        var seen = Set<UUID>()
        guard profiles.allSatisfy({ $0.ordinal >= 0 && seen.insert($0.id).inserted }) else {
            throw DictationError.message("O cadastro de conexões do Painel CLI é inválido.")
        }
        return profiles.sorted { ($0.provider, $0.ordinal) < ($1.provider, $1.ordinal) }
    }

    func connection(id: UUID) throws -> APIConnection {
        guard try profiles().contains(where: { $0.id == id }) else {
            throw DictationError.message("O perfil foi removido do Painel CLI. Escolha outra conexão.")
        }
        var descriptors: [Int32] = []
        defer { descriptors.reversed().forEach { _ = close($0) } }
        let first = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard first >= 0 else { throw unavailable() }
        descriptors.append(first)
        for component in ["instances", id.uuidString] {
            let next = openat(descriptors.last!, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw unavailable() }
            descriptors.append(next)
        }
        for descriptor in descriptors {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw unavailable()
            }
        }
        func read(_ name: String, max: Int) throws -> String {
            let descriptor = openat(descriptors.last!, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw unavailable() }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
                  info.st_size > 0, info.st_size <= max,
                  let data = try file.read(upToCount: max + 1), data.count <= max,
                  let value = String(data: data, encoding: .utf8) else { throw unavailable() }
            return value
        }
        guard let port = Int(try read("port", max: 5)), (1...65535).contains(port) else { throw unavailable() }
        let key = try read("client.key", max: 4096)
        guard key.count >= 32, !key.contains(where: { $0.isWhitespace }) else { throw unavailable() }
        return try APIConnection(endpoint: "http://127.0.0.1:\(port)/v1", key: key, localOnly: true)
    }

    private func unavailable() -> DictationError {
        .message("A conexão do Painel CLI não está preparada. Confira o perfil na central e ative o proxy.")
    }
}
