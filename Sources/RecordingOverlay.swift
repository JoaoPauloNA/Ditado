import AppKit
import Combine
import SwiftUI

/// Small floating pill, like Superwhisper, shown while Ditado listens or transcribes.
/// It never takes focus, so the target field keeps the cursor.
@MainActor
final class RecordingOverlay {
    private let panel: NSPanel
    private var subscription: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    init(model: DictationModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingPill(model: model))
        subscription = model.$isRecording.combineLatest(model.$isProcessing)
            .map { $0 || $1 }.removeDuplicates()
            .sink { [weak self] busy in busy ? self?.show() : self?.showResultThenHide() }
    }
    /// Keeps the final status (pasted, copied, or why not) readable for a moment.
    private func showResultThenHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
    private func show() {
        hideTask?.cancel()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 70))
        panel.orderFrontRegardless()
    }
}

private struct RecordingPill: View {
    @ObservedObject var model: DictationModel
    var body: some View {
        HStack(spacing: 12) {
            if model.isRecording {
                PulsingDot()
                HStack(spacing: 2) {
                    ForEach(Array(model.levels.suffix(24).enumerated()), id: \.offset) { _, level in
                        Capsule().fill(.white.opacity(0.9)).frame(width: 3, height: 4 + level * 24)
                    }
                }.frame(height: 28)
                Text(timeText).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                Image(systemName: model.handsFree ? "hand.raised.slash" : "hand.tap.fill")
                    .foregroundStyle(.white.opacity(0.6)).help(model.handsFree ? "Mãos livres" : "Segurando")
            } else {
                if model.isProcessing { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint) }
                Text(model.status).font(.callout).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 18).frame(width: 380, height: 56)
        .background(.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
    private var timeText: String {
        let total = Int(model.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(.red).frame(width: 10, height: 10).opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { on = true } }
    }
}
