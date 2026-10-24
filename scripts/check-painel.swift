import Foundation

/// Read-only connection check. Does not start proxies or call an inference model.
@main
struct CheckPainel {
    static func main() async {
        do {
            let store = PainelConnectionStore()
            let profiles = try store.profiles()
            let api = DictationAPI()
            let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
            for profile in profiles {
                guard let connection = try? store.connection(id: profile.id) else { continue }
                var health = URLRequest(url: connection.url.deletingLastPathComponent().appendingPathComponent("healthz"))
                health.timeoutInterval = 1
                guard let (_, response) = try? await session.data(for: health),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let models = try await api.models(connection: connection)
                print("PASS: \(profile.title) · \(models.count) models received from the existing local proxy.")
                print("Read-only GET /healthz and GET /v1/models. No inference, proxy changes, or keys printed.")
                return
            }
            print("No active prepared Painel CLI proxy found. Activate a profile in the central app and check again.")
            exit(2)
        } catch {
            print("Connection check failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
