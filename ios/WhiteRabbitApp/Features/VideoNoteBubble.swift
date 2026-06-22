import AVFoundation
import SwiftUI

/// Circular video note. Autoplays muted + looping when it appears; tap toggles
/// sound. Shows a circular poster frame until the video is ready.
struct VideoNoteBubble: View {
    @EnvironmentObject var app: AppState
    let attachment: Attachment

    @StateObject private var player = LoopingPlayer()
    @State private var poster: UIImage?
    @State private var muted = true
    private let diameter: CGFloat = 200

    var body: some View {
        ZStack {
            if let p = player.player {
                PlayerLayerView(player: p)
            } else if let poster {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                Circle().fill(Color(.systemGray5)).overlay(ProgressView())
            }
            VStack {
                Spacer()
                HStack {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption2).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.4), in: Circle())
                    Spacer()
                    if let ms = attachment.durationMs {
                        Text(timeString(Double(ms) / 1000)).font(.caption2.monospacedDigit())
                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                }
                .padding(8)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .contentShape(Circle())
        .onTapGesture {
            player.toggleMute()
            muted = player.isMuted
        }
        .task(id: attachment.key) {
            poster = await app.videoThumbnail(attachment)
            if let url = await app.attachmentFileURL(attachment) { player.start(url: url) }
        }
        .onDisappear { player.stop() }
    }

    private func timeString(_ s: TimeInterval) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// AVPlayer that loops and starts muted; cleans up its loop observer in deinit.
@MainActor
final class LoopingPlayer: ObservableObject {
    @Published private(set) var player: AVPlayer?
    private(set) var isMuted = true
    private var loopObserver: NSObjectProtocol?

    func start(url: URL) {
        guard player == nil else { return }
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero); p?.play()
        }
        player = p
        p.play()
    }

    func toggleMute() {
        guard let player else { return }
        isMuted.toggle()
        player.isMuted = isMuted
        if player.timeControlStatus != .playing { player.play() }
    }

    func stop() {
        player?.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player = nil
    }

    deinit {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}
