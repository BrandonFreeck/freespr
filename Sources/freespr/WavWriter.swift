import Foundation

/// Streams little-endian Int16 PCM to a WAV file. Writes a 44-byte placeholder header, appends
/// samples as they arrive (no whole-recording buffer), then seeks back and patches the two size
/// fields on finalize. Int16 is already little-endian on arm64 — no byte-swap.
final class WavWriter {
    let url: URL
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    private var dataBytes = 0

    init(url: URL, sampleRate: Int = 16000, channels: Int = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw FreesprError.audio("cannot open WAV for writing at \(url.path)")
        }
        handle = h
        try? handle.write(contentsOf: Data(count: 44))   // placeholder, patched on finalize
    }

    func append(_ data: Data) {
        try? handle.write(contentsOf: data)
        dataBytes += data.count
    }

    /// Patch RIFF/data sizes and close. Returns the finished file URL.
    @discardableResult
    func finalize() -> URL {
        let header = Self.header(dataBytes: dataBytes, sampleRate: sampleRate, channels: channels)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: header)
        try? handle.close()
        return url
    }

    static func header(dataBytes: Int, sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataBytes)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))         // PCM, channels
        u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        str("data"); u32(UInt32(dataBytes))
        return d
    }
}
