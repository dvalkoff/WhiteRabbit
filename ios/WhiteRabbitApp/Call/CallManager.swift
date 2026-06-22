import AVFoundation
import Foundation
import WebRTC

/// One active call's display info.
struct ActiveCall: Equatable {
    let peerID: String
    var peerName: String
    let isVideo: Bool
    let incoming: Bool
    var startedAt: Date?
}

enum CallPhase { case idle, outgoing, incoming, connecting, active, ended }

enum CallEndReason { case localHangUp, remoteHangUp, declineLocal, rejectRemote, busy, failed }

/// Drives a single 1:1 WebRTC call: peer connection, local/remote tracks, the
/// signaling state machine, and the mic/camera controls. Signaling is delegated
/// to AppState (sent E2E); ICE servers come from the backend's /v1/turn.
@MainActor
final class CallManager: NSObject, ObservableObject {
    @Published private(set) var phase: CallPhase = .idle
    @Published private(set) var call: ActiveCall?
    @Published var micOn = true
    @Published var cameraOn = false
    @Published private(set) var remoteCameraOn = false
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var localVideoTrack: RTCVideoTrack?

    // Injected by AppState.
    var onSignal: ((CallSignal, String) -> Void)?
    var fetchICE: (() async -> [RTCIceServer])?
    var nameFor: ((String) -> String)?
    var onCallEnded: ((String, CallLog) -> Void)?

    private var usedVideo = false
    private var ringTimeout: Task<Void, Never>?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private var pc: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var cameraPosition: AVCaptureDevice.Position = .front

    private var callID = ""
    private var pendingRemoteOffer: RTCSessionDescription?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false

    // MARK: - Outgoing

    /// Start a call. Camera starts off (audio call); either side can enable video
    /// mid-call. A video m-line is always negotiated so no renegotiation is needed.
    func startCall(peerID: String) {
        guard phase == .idle else { return }
        callID = UUID().uuidString
        call = ActiveCall(peerID: peerID, peerName: nameFor?(peerID) ?? "", isVideo: false, incoming: false)
        micOn = true; cameraOn = false; usedVideo = false; remoteCameraOn = false
        phase = .outgoing
        startRingTimeout()
        Task {
            await setup()
            guard let pc else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let offer = try? await pc.offer(for: constraints) else { endLocally(reason: .failed); return }
            try? await pc.setLocalDescription(offer)
            send(.init(callID: callID, kind: .offer, sdp: offer.sdp))
        }
    }

    private func startRingTimeout() {
        ringTimeout?.cancel()
        ringTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self else { return }
            if phase == .outgoing || phase == .incoming { hangUp() }
        }
    }

    // MARK: - Incoming signaling

    func handle(signal: CallSignal, from peerID: String) {
        switch signal.kind {
        case .offer:
            // Busy if already in a different call.
            guard phase == .idle else {
                onSignal?(CallSignal(callID: signal.callID, kind: .busy), peerID); return
            }
            callID = signal.callID
            call = ActiveCall(peerID: peerID, peerName: nameFor?(peerID) ?? "", isVideo: false, incoming: true)
            micOn = true; cameraOn = false; usedVideo = false; remoteCameraOn = false
            pendingRemoteOffer = signal.sdp.map { RTCSessionDescription(type: .offer, sdp: $0) }
            phase = .incoming
            startRingTimeout()

        case .answer where signal.callID == callID:
            guard let sdp = signal.sdp, let pc else { return }
            Task {
                try? await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                hasRemoteDescription = true
                flushCandidates()
            }

        case .candidate where signal.callID == callID:
            let cand = RTCIceCandidate(sdp: signal.candidate ?? "", sdpMLineIndex: signal.sdpMLineIndex ?? 0,
                                       sdpMid: signal.sdpMid)
            if hasRemoteDescription { pc?.add(cand) { _ in } } else { pendingCandidates.append(cand) }

        case .camera where signal.callID == callID:
            remoteCameraOn = signal.cameraOn ?? false
            if remoteCameraOn { usedVideo = true }

        case .hangup where signal.callID == callID:
            endLocally(reason: .remoteHangUp)
        case .reject where signal.callID == callID:
            endLocally(reason: .rejectRemote)
        case .busy where signal.callID == callID:
            endLocally(reason: .busy)

        default:
            break
        }
    }

    // MARK: - Accept / decline / hang up

    func accept() {
        guard phase == .incoming, let offer = pendingRemoteOffer else { return }
        ringTimeout?.cancel()
        phase = .connecting
        Task {
            await setup()
            guard let pc else { return }
            try? await pc.setRemoteDescription(offer)
            hasRemoteDescription = true
            flushCandidates()
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let answer = try? await pc.answer(for: constraints) else { endLocally(reason: .failed); return }
            try? await pc.setLocalDescription(answer)
            send(.init(callID: callID, kind: .answer, sdp: answer.sdp))
        }
    }

    func decline() {
        send(.init(callID: callID, kind: .reject))
        endLocally(reason: .declineLocal)
    }

    func hangUp() {
        if phase == .incoming { decline(); return }
        send(.init(callID: callID, kind: .hangup))
        endLocally(reason: .localHangUp)
    }

    // MARK: - Controls

    func toggleMic() { micOn.toggle(); localAudioTrack?.isEnabled = micOn }

    func toggleCamera() {
        cameraOn.toggle()
        localVideoTrack?.isEnabled = cameraOn
        if cameraOn { usedVideo = true; startCapture() } else { videoCapturer?.stopCapture() }
        send(.init(callID: callID, kind: .camera, cameraOn: cameraOn))
    }

    func switchCamera() {
        cameraPosition = cameraPosition == .front ? .back : .front
        startCapture()
    }

    // MARK: - Setup / teardown

    /// Always sets up audio + a (disabled) video track so either side can enable
    /// the camera mid-call without renegotiating.
    private func setup() async {
        configureAudioSession()
        let ice = await fetchICE?() ?? []
        let config = RTCConfiguration()
        config.iceServers = ice
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let audioTrack = Self.factory.audioTrack(withTrackId: "audio0")
        pc?.add(audioTrack, streamIds: ["stream0"])
        localAudioTrack = audioTrack

        let source = Self.factory.videoSource()
        let track = Self.factory.videoTrack(with: source, trackId: "video0")
        track.isEnabled = false // camera off by default
        pc?.add(track, streamIds: ["stream0"])
        videoSource = source
        localVideoTrack = track
        videoCapturer = RTCCameraVideoCapturer(delegate: source)
    }

    private func startCapture() {
        guard let capturer = videoCapturer,
              let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == cameraPosition })
                ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // Pick a moderate resolution (~640 wide) for a responsive call.
        let format = formats.min(by: { f1, f2 in
            let d1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
            return abs(Int(d1.width) - 640) < abs(Int(d2.width) - 640)
        }) ?? formats.first
        guard let format else { return }
        let fps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        try? session.setActive(true)
        session.unlockForConfiguration()
    }

    private func flushCandidates() {
        for c in pendingCandidates { pc?.add(c) { _ in } }
        pendingCandidates.removeAll()
    }

    private func send(_ signal: CallSignal) {
        guard let peerID = call?.peerID else { return }
        var s = signal
        s.sentAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        onSignal?(s, peerID)
    }

    /// Tear down. Computes the call outcome, logs it to the chat, and signaling
    /// to the peer (if any) is sent by the caller.
    func endLocally(reason: CallEndReason = .localHangUp) {
        guard phase != .idle, let c = call else { return } // idempotent — avoids dismiss loops
        ringTimeout?.cancel(); ringTimeout = nil
        let wasActive = (phase == .active)

        let outcome: CallLog.Outcome
        switch reason {
        case .busy:
            outcome = .busy
        case .failed:
            outcome = wasActive ? .answered : .failed
        default:
            if wasActive { outcome = .answered }
            else if c.incoming { outcome = (reason == .declineLocal) ? .declined : .missed }
            else { outcome = (reason == .rejectRemote) ? .declined : .cancelled }
        }
        let duration = wasActive ? max(0, Int(Date().timeIntervalSince(c.startedAt ?? Date()))) : 0
        onCallEnded?(c.peerID, CallLog(incoming: c.incoming, video: usedVideo, outcome: outcome, durationSec: duration))

        videoCapturer?.stopCapture()
        pc?.close()
        pc = nil
        localAudioTrack = nil; localVideoTrack = nil; remoteVideoTrack = nil
        videoCapturer = nil; videoSource = nil
        pendingCandidates.removeAll(); pendingRemoteOffer = nil; hasRemoteDescription = false
        callID = ""; remoteCameraOn = false
        phase = .ended
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration(); try? session.setActive(false); session.unlockForConfiguration()
        // Briefly show "ended", then return to idle.
        Task { try? await Task.sleep(for: .milliseconds(500)); if phase == .ended { phase = .idle; call = nil } }
    }
}

// MARK: - RTCPeerConnectionDelegate (callbacks arrive off the main actor)

extension CallManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            send(.init(callID: callID, kind: .candidate, candidate: candidate.sdp,
                       sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected, .completed:
                if phase != .active { phase = .active; call?.startedAt = Date() }
            case .failed, .disconnected, .closed:
                if phase != .idle && phase != .ended { endLocally(reason: .failed) }
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                                    streams: [RTCMediaStream]) {
        Task { @MainActor in
            if let track = rtpReceiver.track as? RTCVideoTrack { remoteVideoTrack = track }
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
