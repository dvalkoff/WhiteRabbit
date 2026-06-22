import SwiftUI
import WebRTC

/// Full-screen call UI: remote video (or avatar for audio), a local preview, and
/// the call controls. Presented over everything via a fullScreenCover.
struct CallView: View {
    @EnvironmentObject var callManager: CallManager

    private var call: ActiveCall? { callManager.call }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if callManager.remoteCameraOn, let remote = callManager.remoteVideoTrack {
                RTCVideoView(track: remote).ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Circle().fill(Color.accentColor.opacity(0.3)).frame(width: 120, height: 120)
                        .overlay(Text((call?.peerName.prefix(1) ?? "?").uppercased()).font(.system(size: 48)))
                    Text(call?.peerName ?? "").font(.title2.bold()).foregroundStyle(.white)
                }
            }

            VStack {
                header
                Spacer()
                controls
            }
            .padding()

            if callManager.cameraOn, let local = callManager.localVideoTrack {
                VStack {
                    HStack {
                        Spacer()
                        RTCVideoView(track: local)
                            .frame(width: 100, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding()
                    }
                    Spacer()
                }
            }
        }
        .statusBarHidden()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(call?.peerName ?? "").font(.title3.bold()).foregroundStyle(.white)
            statusText
        }
        .padding(.top, 8)
        .shadow(radius: 4)
    }

    @ViewBuilder private var statusText: some View {
        switch callManager.phase {
        case .outgoing: Text("Calling…").font(.subheadline).foregroundStyle(.white.opacity(0.85))
        case .incoming: Text("Incoming call").font(.subheadline).foregroundStyle(.white.opacity(0.85))
        case .connecting: Text("Connecting…").font(.subheadline).foregroundStyle(.white.opacity(0.85))
        case .active:
            if let start = call?.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed(since: start)).font(.title3.monospacedDigit()).foregroundStyle(.green)
                }
            } else { Text("Connected").font(.subheadline).foregroundStyle(.white.opacity(0.85)) }
        case .ended, .idle: Text("Call ended").font(.subheadline).foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder private var controls: some View {
        if callManager.phase == .incoming {
            HStack(spacing: 60) {
                CallButton(icon: "phone.down.fill", tint: .red) { callManager.decline() }
                CallButton(icon: "phone.fill", tint: .green) { callManager.accept() }
            }
        } else {
            HStack(spacing: 24) {
                CallButton(icon: callManager.micOn ? "mic.fill" : "mic.slash.fill",
                           tint: callManager.micOn ? .white : .gray, dark: true) { callManager.toggleMic() }
                CallButton(icon: callManager.cameraOn ? "video.fill" : "video.slash.fill",
                           tint: callManager.cameraOn ? .white : .gray, dark: true) { callManager.toggleCamera() }
                if callManager.cameraOn {
                    CallButton(icon: "arrow.triangle.2.circlepath.camera.fill", tint: .white, dark: true) { callManager.switchCamera() }
                }
                CallButton(icon: "phone.down.fill", tint: .red) { callManager.hangUp() }
            }
        }
    }

    private func elapsed(since start: Date) -> String {
        let t = Int(Date().timeIntervalSince(start))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

private struct CallButton: View {
    let icon: String
    var tint: Color
    var dark: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2).foregroundStyle(dark ? tint : .white)
                .frame(width: 64, height: 64)
                .background(dark ? Color.white.opacity(0.2) : tint, in: Circle())
        }
    }
}

/// Renders an RTCVideoTrack via Metal.
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = .scaleAspectFill
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(uiView)
            track?.add(uiView)
            context.coordinator.track = track
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var track: RTCVideoTrack? }
}
