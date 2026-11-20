import Foundation
import AVFoundation

/// Captures mic audio, downsamples to 16 kHz mono Int16 via AVAudioConverter (anti-aliased
/// resample, no third-party lib), streams it to a WAV, and watches per-buffer RMS for the
/// silence auto-stop. The tap block runs on a real-time audio thread — kept lean.
///
/// Threading: `process()` runs on the audio render thread; `stop()` and the silence timer run on
/// main. A lock + `stopped` flag serialize all access to `writer`/`converter`/`lastVoiceTime` so a
/// buffer in flight at stop() can't write to (or race) a finalized WAV. stop() flips `stopped`
/// under the lock, so any later process() bails before touching the writer; only then does it
/// flush + finalize off the (now-quiescent) writer.
final class AudioRecorder {
    /// Recordings are `freespr-<UUID>.wav` in the per-user temp folder and are deleted once sent.
    /// One left behind by a stop mid-recording or mid-transcription is removed at the agent's next
    /// start and by `uninstall --purge`. Only regular files last written more than `age` seconds ago
    /// go: a recording in progress is written every few milliseconds and read right after it stops,
    /// so the agent passes an age longer than the 10-minute recording cap. Symlinks and folders are
    /// skipped, never followed. Returns how many it removed.
    static func removeLeftoverRecordings(in dir: URL = FileManager.default.temporaryDirectory,
                                         olderThan age: TimeInterval) -> Int {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where isRecordingName(name) {
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),     // lstat: doesn't follow a link
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let modified = attrs[.modificationDate] as? Date, modified <= cutoff else { continue }
            if unlink(path) == 0 { removed += 1 }
        }
        return removed
    }

    static func isRecordingName(_ name: String) -> Bool {
        guard name.hasPrefix("freespr-"), name.hasSuffix(".wav") else { return false }
        return UUID(uuidString: String(name.dropFirst("freespr-".count).dropLast(".wav".count))) != nil
    }

    var onAutoStop: (String) -> Void = { _ in }   // reason: "silence" or "max recording length"

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                             channels: 1, interleaved: true)!
    private let silenceThreshold: Float = 0.015     // normalized RMS; tunable
    private let silenceTimeout: TimeInterval
    private let maxDuration: TimeInterval           // 0 = uncapped

    private let lock = NSLock()                      // guards stopped / writer / converter / lastVoiceTime
    private var stopped = false
    private var converter: AVAudioConverter?
    private var writer: WavWriter?
    private var silenceTimer: DispatchSourceTimer?
    private var lastVoiceTime: CFAbsoluteTime = 0
    private var recordingStart: CFAbsoluteTime = 0
    private var started = false

    init(silenceTimeout: TimeInterval, maxDuration: TimeInterval) {
        self.silenceTimeout = silenceTimeout
        self.maxDuration = maxDuration
    }

    /// Begin capturing to a temp WAV. Returns the file URL. Throws if there's no usable input.
    func start() throws -> URL {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw FreesprError.audio("no input device available (mic permission?)")
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw FreesprError.audio("cannot create 16 kHz converter")
        }
        converter = conv

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freespr-\(UUID().uuidString).wav")
        writer = try WavWriter(url: url)

        lastVoiceTime = CFAbsoluteTimeGetCurrent()
        recordingStart = lastVoiceTime
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        started = true
        armSilenceTimer()
        return url
    }

    /// Stop and finalize. Returns the WAV URL (nil if not recording).
    @discardableResult
    func stop() -> URL? {
        lock.lock()
        guard started, !stopped else { lock.unlock(); return nil }
        stopped = true
        let conv = converter
        let w = writer
        converter = nil
        writer = nil
        lock.unlock()

        // Past this point `stopped` is true, so any in-flight process() bails before touching the
        // writer — the flush + finalize below run with no concurrent access.
        started = false
        silenceTimer?.cancel(); silenceTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if let conv { flushConverterTail(conv, into: w) }   // emit the resampler's buffered tail
        return w?.finalize()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let conv = converter, let writer = writer else { return }
        guard buffer.format.sampleRate > 0 else { return }   // avoid div-by-zero → inf → trap on the cast

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024 // slack → full input consume
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var fed = false
        var err: NSError?
        let status = conv.convert(to: outBuffer, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error { return }
        guard outBuffer.frameLength > 0, let ch = outBuffer.int16ChannelData else { return }

        let frames = Int(outBuffer.frameLength)
        let samples = ch[0]
        var sumSq = 0.0
        for i in 0..<frames {
            let v = Double(samples[i]) / 32768.0
            sumSq += v * v
        }
        if Float((sumSq / Double(max(1, frames))).squareRoot()) > silenceThreshold {
            lastVoiceTime = CFAbsoluteTimeGetCurrent()
        }
        writer.append(Data(bytes: samples, count: frames * 2))
    }

    /// One final convert signalling end-of-stream so the resampler emits its buffered tail frames
    /// (otherwise the last few ms of audio are dropped). Runs on main after the audio thread is quiet.
    private func flushConverterTail(_ conv: AVAudioConverter, into writer: WavWriter?) {
        guard let writer, let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
        var err: NSError?
        let status = conv.convert(to: outBuffer, error: &err) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, outBuffer.frameLength > 0, let ch = outBuffer.int16ChannelData else { return }
        writer.append(Data(bytes: ch[0], count: Int(outBuffer.frameLength) * 2))
    }

    private func armSilenceTimer() {
        var ticks = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stopped = self.stopped
            let last = self.lastVoiceTime
            let start = self.recordingStart
            self.lock.unlock()
            guard !stopped else { return }
            let now = CFAbsoluteTimeGetCurrent()
            ticks += 1
            if ticks % 30 == 0 {   // once per 30s: discriminates "still talking" vs a starved timer on stuck sessions
                log("rec: \(Int(now - start))s elapsed, \(Int(now - last))s since voice")
            }
            // onAutoStop is called OUTSIDE the lock — it re-enters stop(), which takes the lock.
            if self.maxDuration > 0, now - start >= self.maxDuration {
                self.onAutoStop("max recording length (\(Int(self.maxDuration / 60))m)")
            } else if now - last >= self.silenceTimeout {
                self.onAutoStop("silence")
            }
        }
        timer.resume()
        silenceTimer = timer
    }
}
