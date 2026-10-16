import Foundation
import HiResBuddyCore
import LDACEncoder

struct WAVError: Error, CustomStringConvertible {
    let description: String
}

/// A RIFF/WAVE file (16/24/32-bit PCM or 32-bit float, mono or stereo, 44.1/48/88.2/96 kHz) played in real time:
/// `preroll` seconds up front, then 10 ms blocks at wall-clock pace, as interleaved stereo Float32.
final class WAVSource: PCMSource, @unchecked Sendable {
    let sampleRate: LDACSampleRate
    let duration: TimeInterval
    /// Called once on a background queue when the whole file has been delivered.
    var onEnd: (@Sendable () -> Void)?

    private enum Encoding { case int16, int24, int32, float32 }

    private let data: Data
    private let dataStart: Int
    private let channels: Int
    private let encoding: Encoding
    private let bytesPerFrame: Int
    private let totalFrames: Int
    private let preroll: Double
    private let queue = DispatchQueue(label: "hiresbuddy.wav", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var delivered = 0

    init(url: URL, preroll: Double = 0.3) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 12, data.ascii(0, 4) == "RIFF", data.ascii(8, 4) == "WAVE" else {
            throw WAVError(description: "not a RIFF/WAVE file")
        }
        var fmt: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var body: Range<Int>?
        var pos = 12
        while pos + 8 <= data.count {
            let id = data.ascii(pos, 4), size = data.le(pos + 4, 4)
            let start = pos + 8
            if id == "fmt " && size >= 16 {
                var tag = data.le(start, 2)
                if tag == 0xFFFE && size >= 26 { tag = data.le(start + 24, 2) }   // WAVE_FORMAT_EXTENSIBLE subformat
                fmt = (tag, data.le(start + 2, 2), data.le(start + 4, 4), data.le(start + 14, 2))
            } else if id == "data" {
                body = start..<min(start + size, data.count)
            }
            pos = start + size + (size & 1)
        }
        guard let fmt, let body else { throw WAVError(description: "missing fmt or data chunk") }
        switch (fmt.tag, fmt.bits) {
        case (1, 16): encoding = .int16
        case (1, 24): encoding = .int24
        case (1, 32): encoding = .int32
        case (3, 32): encoding = .float32
        default: throw WAVError(description: "unsupported sample format (tag \(fmt.tag), \(fmt.bits) bit)")
        }
        guard fmt.channels == 1 || fmt.channels == 2 else {
            throw WAVError(description: "unsupported channel count \(fmt.channels)")
        }
        guard let rate = LDACSampleRate(rawValue: fmt.rate) else {
            throw WAVError(description: "unsupported sample rate \(fmt.rate) Hz (LDAC: 44100, 48000, 88200, 96000)")
        }
        sampleRate = rate
        channels = fmt.channels
        bytesPerFrame = fmt.channels * fmt.bits / 8
        dataStart = body.lowerBound
        totalFrames = body.count / bytesPerFrame
        duration = Double(totalFrames) / Double(fmt.rate)
        self.preroll = preroll
    }

    func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void) {
        nonisolated(unsafe) let sink = sink
        let rate = Double(sampleRate.rawValue)
        let t0 = ProcessInfo.processInfo.systemUptime
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - t0
            let due = min(totalFrames, Int((elapsed + preroll) * rate))
            if due > delivered {
                let block = stereoFloats(from: delivered, count: due - delivered)
                delivered = due
                block.withUnsafeBufferPointer { sink($0) }
            }
            if delivered == totalFrames {
                timer?.cancel()
                timer = nil
                onEnd?()
            }
        }
        queue.sync { timer = t }
        t.resume()
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func stereoFloats(from frame: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = dataStart + frame * bytesPerFrame
            let bytesPerSample = bytesPerFrame / channels
            for i in 0..<count {
                for ch in 0..<2 {
                    let off = base + i * bytesPerFrame + min(ch, channels - 1) * bytesPerSample
                    out[2 * i + ch] = sample(raw, at: off)
                }
            }
        }
        return out
    }

    private func sample(_ raw: UnsafeRawBufferPointer, at off: Int) -> Float {
        switch encoding {
        case .int16:
            return Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: Int16.self))) / 32768
        case .int24:
            let v = Int32(raw[off]) | Int32(raw[off + 1]) << 8 | Int32(Int8(bitPattern: raw[off + 2])) << 16
            return Float(v) / 8_388_608
        case .int32:
            return Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: Int32.self))) / 2_147_483_648
        case .float32:
            return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
        }
    }
}

private extension Data {
    func ascii(_ offset: Int, _ count: Int) -> String {
        String(decoding: self[startIndex + offset ..< startIndex + offset + count], as: UTF8.self)
    }

    /// Little-endian unsigned integer of `count` bytes.
    func le(_ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
