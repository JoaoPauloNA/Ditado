import Foundation
import Speech
import AVFoundation

@MainActor
final class LocalSpeech {
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    func prepare(language: String) async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw DictationError.message("Autorize o reconhecimento de fala para BlabberType em Ajustes do Sistema → Privacidade e Segurança.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition else {
            throw DictationError.message("O reconhecimento local de \(language) não está disponível neste Mac. Ative o Ditado desse idioma nos Ajustes do Sistema ou escolha Whisper local/API nas conexões.")
        }
    }

    func transcribe(url: URL, language: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition else {
            throw DictationError.message("O modelo local deste idioma não está disponível.")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let token = UUID()
        generation = token
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard self?.generation == token else { return }
                        if let result, result.isFinal {
                            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                            self?.finish(text.isEmpty ? .failure(DictationError.message("Nenhuma fala foi reconhecida.")) : .success(text))
                        } else if let error { self?.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                    self?.finish(.failure(DictationError.message("O reconhecimento local demorou demais. Tente novamente ou escolha outra conexão.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == token else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { generation = UUID(); finish(.failure(CancellationError())) }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result)
    }
}
