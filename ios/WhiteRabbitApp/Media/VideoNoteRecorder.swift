import AVFoundation
import SwiftUI

/// Records a short front-camera clip for a circular video note. Not available on
/// the Simulator (no camera) — callers fall back to picking from the library.
@MainActor
final class VideoNoteRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var finish: ((URL?) -> Void)?
    private var timer: Timer?
    private var startTime: Date?
    @Published var elapsed: TimeInterval = 0
    private(set) var configured = false

    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    static func requestPermission() async -> Bool {
        let cam = await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .video) { c.resume(returning: $0) }
        }
        let mic = await AudioRecorder.requestPermission()
        return cam && mic
    }

    func configure() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    func startSession() {
        guard !session.isRunning else { return }
        Task.detached { [session] in session.startRunning() }
    }

    func stopSession() {
        guard session.isRunning else { return }
        Task.detached { [session] in session.stopRunning() }
    }

    func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-\(UUID().uuidString).mp4")
        output.startRecording(to: url, recordingDelegate: self)
        startTime = Date(); elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in if let s = self?.startTime { self?.elapsed = Date().timeIntervalSince(s) } }
        }
    }

    func stopRecording() async -> URL? {
        timer?.invalidate(); timer = nil
        return await withCheckedContinuation { cont in
            finish = { cont.resume(returning: $0) }
            output.stopRecording()
        }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        finish = { _ in }
        if output.isRecording { output.stopRecording() }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            let cb = finish; finish = nil
            cb?(error == nil ? outputFileURL : nil)
        }
    }
}

/// Live circular preview of the capture session.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
