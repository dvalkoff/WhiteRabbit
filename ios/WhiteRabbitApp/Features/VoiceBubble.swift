import AVFoundation
import SwiftUI

/// Plays a voice message: play/pause, a waveform that fills with progress, and
/// the duration.
struct VoiceBubble: View {
    @EnvironmentObject var app: AppState
    let attachment: Attachment
    let isMine: Bool

    @StateObject private var player = VoiceMessagePlayer()
    @State private var loading = false

    private var bars: [Int] { attachment.waveform ?? Array(repeating: 18, count: 40) }
    private var duration: TimeInterval { Double(attachment.durationMs ?? 0) / 1000 }

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await toggle() } } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(isMine ? .white : Color.accentColor)
            }
            .disabled(loading)
            WaveformView(bars: bars, progress: player.progress,
                         tint: isMine ? .white : Color.accentColor)
                .frame(width: 130, height: 28)
            Text(timeString(player.isPlaying || player.progress > 0 ? player.current : duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isMine ? .white.opacity(0.85) : .secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isMine ? Color.accentColor : Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onDisappear { player.stop() }
    }

    private func toggle() async {
        if player.isPlaying { player.pause(); return }
        if !player.isLoaded {
            loading = true
            let url = await app.attachmentFileURL(attachment)
            loading = false
            guard let url else { return }
            player.load(url: url, duration: duration)
        }
        player.play()
    }

    private func timeString(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Owns an AVAudioPlayer for one voice message, publishing play state/progress.
@MainActor
final class VoiceMessagePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var progress: Double = 0   // 0…1
    @Published var current: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    var isLoaded: Bool { player != nil }

    func load(url: URL, duration: TimeInterval) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        player?.pause(); isPlaying = false
        timer?.invalidate(); timer = nil
    }

    func stop() {
        player?.stop(); isPlaying = false; progress = 0; current = 0
        timer?.invalidate(); timer = nil
    }

    private func tick() {
        guard let player else { return }
        current = player.currentTime
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false; progress = 0; current = 0
            timer?.invalidate(); timer = nil
        }
    }
}

/// Static-amplitude waveform; bars before `progress` are tinted.
struct WaveformView: View {
    let bars: [Int]
    let progress: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let count = max(bars.count, 1)
            let spacing: CGFloat = 2
            let w = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { i, v in
                    let h = max(3, CGFloat(v) / 100 * geo.size.height)
                    Capsule()
                        .fill(Double(i) / Double(count) <= progress ? tint : tint.opacity(0.35))
                        .frame(width: max(1, w), height: h)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }
}
