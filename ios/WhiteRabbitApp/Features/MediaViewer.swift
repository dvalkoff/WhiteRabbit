import AVKit
import SwiftUI

/// Context for presenting the full-screen media gallery.
struct MediaViewerContext: Identifiable {
    let id = UUID()
    let items: [Attachment]
    let startIndex: Int
}

/// In-app, swipeable photo/video viewer. Pages through all media in the chat;
/// images are zoomable, videos play inline. Replaces the OS QuickLook viewer.
struct MediaViewer: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let context: MediaViewerContext

    @State private var index: Int
    @State private var shareURL: URL?

    init(context: MediaViewerContext) {
        self.context = context
        _index = State(initialValue: context.startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(context.items.enumerated()), id: \.element.id) { i, att in
                    MediaPage(attachment: att).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: context.items.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            HStack(spacing: 16) {
                Button { Task { shareURL = await app.attachmentFileURL(context.items[index]) } } label: {
                    Image(systemName: "square.and.arrow.up").font(.title3)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3)
                }
            }
            .padding(12)
            .foregroundStyle(.white)
        }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
    }
}

private struct MediaPage: View {
    @EnvironmentObject var app: AppState
    let attachment: Attachment

    @State private var image: UIImage?
    @State private var videoURL: URL?
    @State private var loading = true

    var body: some View {
        Group {
            if attachment.isVideo {
                if let videoURL {
                    CustomVideoPlayer(url: videoURL)
                } else {
                    loader
                }
            } else if let image {
                ZoomableImage(image: image)
            } else {
                loader
            }
        }
        .task(id: attachment.key) {
            loading = true
            if attachment.isVideo {
                videoURL = await app.attachmentFileURL(attachment)
            } else if let data = await app.attachmentData(attachment) {
                image = UIImage(data: data)
            }
            loading = false
        }
    }

    private var loader: some View {
        Color.clear.overlay { if loading { ProgressView().tint(.white) } }
    }
}

/// Pinch-to-zoom image view. Panning is only enabled while zoomed in, so at
/// fit-scale the horizontal swipe passes through to the paging TabView.
private struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        image_
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnification)
            // Pan gesture exists only when zoomed, so it doesn't block paging.
            .modifier(PanWhenZoomed(scale: scale, offset: $offset, baseOffset: $baseOffset))
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1 { scale = 1; offset = .zero; baseOffset = .zero }
                    else { scale = 2.5 }
                }
            }
    }

    private var image_: some View { Image(uiImage: image).resizable().scaledToFit() }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { scale = max(1, $0) }
            .onEnded { _ in
                if scale < 1.1 { withAnimation { scale = 1; offset = .zero; baseOffset = .zero } }
            }
    }
}

private struct PanWhenZoomed: ViewModifier {
    let scale: CGFloat
    @Binding var offset: CGSize
    @Binding var baseOffset: CGSize

    func body(content: Content) -> some View {
        if scale > 1 {
            content.gesture(
                DragGesture()
                    .onChanged { offset = CGSize(width: baseOffset.width + $0.translation.width,
                                                 height: baseOffset.height + $0.translation.height) }
                    .onEnded { _ in baseOffset = offset }
            )
        } else {
            content
        }
    }
}

/// A lightweight YouTube-style player: the video fills the screen, tapping
/// toggles a controls overlay with a center play/pause, ±10s skips, a scrubber
/// and timecodes.
private struct CustomVideoPlayer: View {
    @StateObject private var model: VideoPlayerModel
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    init(url: URL) {
        _model = StateObject(wrappedValue: VideoPlayerModel(url: url))
    }

    var body: some View {
        ZStack {
            PlayerLayerView(player: model.player)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showControls.toggle() }
                    if showControls { scheduleHide() }
                }

            if showControls {
                controls.transition(.opacity)
            }
        }
        .onAppear { model.play(); bump() }
        .onDisappear { hideTask?.cancel() }
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 48) {
                skipButton(system: "gobackward.10") { model.seek(by: -10); bump() }
                Button { model.togglePlay(); bump() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 48))
                }
                skipButton(system: "goforward.10") { model.seek(by: 10); bump() }
            }
            .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 10) {
                Text(timeString(model.current)).font(.caption).monospacedDigit()
                SeekBar(value: $model.current, total: model.duration,
                        onScrubChanged: { editing in
                            model.scrubbing = editing
                            if editing { hideTask?.cancel() } else { bump() }
                        },
                        onSeek: { model.seek(to: $0) })
                    .frame(height: 20)
                Text(timeString(model.duration)).font(.caption).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal).padding(.bottom, 24)
        }
        .background(
            // Tapping the dimmed background (anywhere but the buttons/scrubber)
            // hides the controls, like a normal player.
            LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom)
                .contentShape(Rectangle())
                .onTapGesture { hideControls() }
        )
    }

    private func skipButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system).font(.title) }
    }

    /// Keep controls visible and (re)start the 2-second auto-hide timer.
    private func bump() {
        showControls = true
        scheduleHide()
    }

    private func hideControls() {
        hideTask?.cancel()
        withAnimation { showControls = false }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !model.scrubbing else { return }
            withAnimation { showControls = false }
        }
    }

    private func timeString(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// A progress bar that supports both dragging the knob and tapping anywhere to
/// jump to that point (minimumDistance 0 makes a tap a zero-length drag).
private struct SeekBar: View {
    @Binding var value: Double
    let total: Double
    var onScrubChanged: (Bool) -> Void
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = total > 0 ? min(max(value / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                Capsule().fill(.white).frame(width: w * frac, height: 4)
                Circle().fill(.white).frame(width: 14, height: 14)
                    .offset(x: max(0, w * frac - 7))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onScrubChanged(true)
                        guard total > 0, w > 0 else { return }
                        value = min(max(g.location.x / w, 0), 1) * total
                    }
                    .onEnded { g in
                        guard total > 0, w > 0 else { onScrubChanged(false); return }
                        let target = min(max(g.location.x / w, 0), 1) * total
                        value = target
                        onSeek(target)
                        onScrubChanged(false)
                    }
            )
        }
    }
}

/// Owns the AVPlayer and its periodic time observer. The observer is removed in
/// deinit — exactly once, after the view is gone — which avoids the AVPlayer
/// teardown crash that happened when removal was tied to onDisappear during
/// TabView cell reuse.
@MainActor
private final class VideoPlayerModel: ObservableObject {
    let player: AVPlayer
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    var scrubbing = false

    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            if !self.scrubbing { self.current = time.seconds }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        player.pause()
    }

    func play() { player.play(); isPlaying = true }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: Double) {
        guard duration.isFinite, duration > 0 else { return }
        let target = min(max(current + delta, 0), duration)
        current = target
        seek(to: target)
    }
}

/// Hosts an AVPlayerLayer so we can overlay our own controls on top.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// UIActivityViewController wrapper for sharing/saving a file (download).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// Allow URL to drive a .sheet(item:).
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
