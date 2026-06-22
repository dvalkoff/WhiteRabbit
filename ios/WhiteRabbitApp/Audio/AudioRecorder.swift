import AVFoundation
import Foundation

/// Records a voice message to m4a/AAC while sampling amplitude for a waveform.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published var level: Float = 0          // 0…1, for the live meter
    @Published var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?
    private var samples: [Int] = []
    private var tick = 0

    struct Result { let data: Data; let durationMs: Int; let waveform: [Int] }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        r.record()

        recorder = r; self.url = url; samples = []; elapsed = 0; tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        guard let r = recorder else { return }
        r.updateMeters()
        let power = r.averagePower(forChannel: 0)        // dBFS, ~ -60…0
        let norm = max(0, min(1, (power + 55) / 55))     // normalize to 0…1
        level = norm
        elapsed = r.currentTime
        tick += 1
        if tick % 2 == 0 { samples.append(Int(norm * 100)) } // ~10 bars/sec
    }

    func stop() -> Result? {
        timer?.invalidate(); timer = nil
        guard let r = recorder, let url else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return Result(data: data, durationMs: Int(duration * 1000),
                      waveform: Self.downsample(samples, to: 40))
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Reduce raw samples to `n` bars by averaging buckets.
    static func downsample(_ s: [Int], to n: Int) -> [Int] {
        guard s.count > n, n > 0 else { return s.isEmpty ? Array(repeating: 4, count: n) : s }
        var out: [Int] = []
        let bucket = Double(s.count) / Double(n)
        for i in 0..<n {
            let lo = Int(Double(i) * bucket)
            let hi = min(s.count, Int(Double(i + 1) * bucket))
            let slice = s[lo..<max(lo + 1, hi)]
            out.append(slice.reduce(0, +) / slice.count)
        }
        return out
    }
}
