import BTStream
import Foundation
import XCTest
@testable import HiResBuddyCore
import LDACEncoder

@MainActor
final class StreamerTests: XCTestCase {
    func testStreamsPacketsToTransportFD() throws {
        let h = try Harness()
        let streamer = Streamer(session: h.session, sampleRate: .hz48000, quality: .hq)
        var states: [HBSessionState] = []
        streamer.onStateChange = { state, _ in states.append(state) }
        try streamer.start(source: SineSource(rate: 48000, seconds: 1, preroll: 1))
        spin(1.5)
        streamer.stop()
        let packets = h.reader.finish()
        XCTAssertGreaterThanOrEqual(packets.count, 150)
        XCTAssertTrue(packets.allSatisfy { $0.count > 13 && $0[0] == 0x80 && $0[1] == 0x60 })
        XCTAssertEqual(states, [.streaming, .closed])
        XCTAssertEqual(h.session.startedBit, LDACSampleRate.hz48000.avdtpBit)
    }

    func testSetQualityMidStreamKeepsFrameContinuity() throws {
        let h = try Harness()
        let streamer = Streamer(session: h.session, sampleRate: .hz48000, quality: .hq)
        var reports: [StreamStats] = []
        streamer.onStats = { reports.append($0) }
        try streamer.start(source: SineSource(rate: 48000, seconds: 4, preroll: 0.3))
        spin(0.5)
        streamer.quality = .mq
        spin(2.7)
        streamer.stop()
        let packets = h.reader.finish()

        XCTAssertGreaterThan(packets.count, 100)
        let seqs = packets.map { UInt16($0[2]) << 8 | UInt16($0[3]) }
        XCTAssertEqual(seqs, (0..<seqs.count).map { UInt16($0) }, "RTP sequence must have no gaps")
        assertTimestampsFollowFrames(packets)
        XCTAssertGreaterThanOrEqual(reports.count, 2)
        guard reports.count >= 2 else { return }
        XCTAssertEqual(reports[0].quality, .mq)
        XCTAssertLessThan(reports.last!.bitrateKbps, 400)       // window 2–3 s: all mq
        XCTAssertLessThan(reports.last!.bitrateKbps, reports[0].bitrateKbps)
        XCTAssertEqual(streamer.stats.quality, .mq)
    }

    func testGainIsAppliedBeforeEncode() throws {
        XCTAssertEqual(try peakSeenByEncoder(gain: 0), 0)
        XCTAssertEqual(try peakSeenByEncoder(gain: 0.5), 0.25, accuracy: 0.01)   // the sine peaks at 0.5
    }

    func testStatsReportBitrateWithinTolerance() throws {
        let h = try Harness()
        let streamer = Streamer(session: h.session, sampleRate: .hz48000, quality: .hq)
        var reports: [StreamStats] = []
        streamer.onStats = { reports.append($0) }
        try streamer.start(source: SineSource(rate: 48000, seconds: 3, preroll: 0.3))
        spin(2.2)
        streamer.stop()
        _ = h.reader.finish()
        XCTAssertGreaterThanOrEqual(reports.count, 2)
        guard reports.count >= 2 else { return }
        XCTAssertTrue((900...1000).contains(reports[1].bitrateKbps), "bitrate \(reports[1].bitrateKbps) kbit/s")
        XCTAssertEqual(reports[1].sampleRate, 48000)
        XCTAssertEqual(reports[1].quality, .hq)
        XCTAssertGreaterThan(reports[1].packets, 300)
        XCTAssertEqual(reports[1].dropEvents, 0)
        XCTAssertGreaterThanOrEqual(reports[1].bufferSeconds, 0.2, "about lead (0.25 s) stays queued behind the sender")
    }

    func testRingBufferOverflowCountsDrops() throws {
        let h = try Harness()
        let streamer = Streamer(session: h.session, sampleRate: .hz48000, quality: .hq)
        var reports: [StreamStats] = []
        streamer.onStats = { reports.append($0) }
        try streamer.start(source: FloodSource())   // 10 s of audio handed over at once, faster than any drain
        spin(1.2)
        streamer.stop()
        _ = h.reader.finish()
        guard let last = reports.last else { return XCTFail("no stats") }
        XCTAssertGreaterThan(last.inputOverflows, 0)
        XCTAssertGreaterThan(last.packets, 0, "what fitted is still streamed")
    }

    func testBackpressureKeepsPacketsUntilTheReaderCatchesUp() throws {
        // a receive buffer of ~11 packets and a reader that starts late: writes fail with ENOBUFS (EAGAIN on a
        // stream socket) for a while, and those packets must stay queued rather than be lost
        let h = try Harness(receiveBuffer: 8192, readerDelay: 0.8)
        let streamer = Streamer(session: h.session, sampleRate: .hz48000, quality: .hq)
        var reports: [StreamStats] = []
        streamer.onStats = { reports.append($0) }
        try streamer.start(source: SineSource(rate: 48000, seconds: 3, preroll: 0.3))
        spin(2.2)
        streamer.stop()
        let packets = h.reader.finish()

        let seqs = packets.map { UInt16($0[2]) << 8 | UInt16($0[3]) }
        XCTAssertGreaterThan(seqs.count, 300)
        XCTAssertEqual(seqs, (0..<seqs.count).map { UInt16($0) }, "no packet lost to backpressure")
        assertTimestampsFollowFrames(packets)
        guard let last = reports.last else { return XCTFail("no stats") }
        XCTAssertGreaterThan(last.backpressureTicks, 0)
        XCTAssertEqual(last.writeErrors, 0)
        XCTAssertEqual(last.dropEvents, 0)
        XCTAssertLessThan(last.bufferSeconds, 0.7, "the queue drained back to its normal depth")
    }

    func testSuspendPausesSendingAndStreamingResumes() throws {
        let h = try Harness()
        let streamer = Streamer(session: h.session, sampleRate: .hz48000, quality: .hq)
        try streamer.start(source: SineSource(rate: 48000, seconds: 4, preroll: 0.3))
        spin(1.0)
        h.session.move(to: .suspended)
        spin(0.1)                                     // let a send tick that was already running finish
        let atSuspend = h.reader.count
        spin(0.5)
        XCTAssertEqual(h.reader.count, atSuspend, "nothing is written while suspended")
        h.session.move(to: .streaming)
        spin(1.0)
        XCTAssertGreaterThan(h.reader.count, atSuspend + 100, "sending resumes")
        streamer.stop()
        let seqs = h.reader.finish().map { UInt16($0[2]) << 8 | UInt16($0[3]) }
        XCTAssertEqual(seqs, seqs.sorted())
    }

    /// Each RTP timestamp advances by the previous packet's LDAC frames × 128 samples (48 kHz).
    private func assertTimestampsFollowFrames(_ packets: [[UInt8]], file: StaticString = #filePath, line: UInt = #line) {
        let stamps = packets.map { $0[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        for i in packets.indices.dropFirst() {
            let expected = stamps[i - 1] &+ UInt32(packets[i - 1][12] & 0x0f) * 128
            if stamps[i] != expected {
                XCTFail("packet \(i): timestamp \(stamps[i]), expected \(expected)", file: file, line: line)
                return
            }
        }
    }

    private func peakSeenByEncoder(gain: Float) throws -> Float {
        let h = try Harness()
        let spy = SpyEncoder()
        let streamer = Streamer(session: h.session, sampleRate: .hz48000, quality: .hq, makeEncoder: { _, _ in spy })
        streamer.gain = gain
        try streamer.start(source: SineSource(rate: 48000, seconds: 0.2, preroll: 0.2))
        spin(0.3)
        streamer.stop()
        _ = h.reader.finish()
        XCTAssertGreaterThan(spy.blocks, 50)
        return spy.peak
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

/// A socketpair standing in for the transport channel, a fake session handing out one end, a reader on the other.
@MainActor
private struct Harness {
    let session: FakeSession
    let reader: PacketReader

    init(receiveBuffer: Int32 = 4 << 20, readerDelay: TimeInterval = 0) throws {
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &sv) == 0 else { throw POSIXError(.EIO) }
        var size = receiveBuffer
        setsockopt(sv[1], SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        session = FakeSession(transportFD: sv[0])
        reader = PacketReader(fd: sv[1], startDelay: readerDelay)
    }
}

/// Goes straight to Streaming on start and to Closed on stop; owns the transport fd.
private final class FakeSession: HBAVDTPSession {
    private let fd: Int32
    private let signalingPeer: Int32
    private var fakeState = HBSessionState.idle
    private(set) var startedBit: UInt8 = 0

    init(transportFD: Int32) {
        fd = transportFD
        var sv: [Int32] = [-1, -1]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &sv)
        signalingPeer = sv[1]   // kept open: EOF on the signaling channel would fail the session
        super.init(signaling: HBL2CAPChannel(socketFD: sv[0], name: "fake-signaling")!, transportProvider: { _ in })
    }

    deinit {
        close(fd)
        close(signalingPeer)
    }

    override var state: HBSessionState { fakeState }
    override var transportFD: Int32 { fakeState == .streaming || fakeState == .suspended ? fd : -1 }

    override func start(withSampleRateBit sfBit: UInt8) {
        startedBit = sfBit
        move(to: .streaming)
    }

    override func stopAndRestoreSystemAudio() {
        move(to: .closed)
    }

    func move(to state: HBSessionState) {
        fakeState = state
        delegate?.session(self, didChange: state, error: nil)
    }
}

/// Collects every datagram from the far end of the transport socketpair on a background thread.
private final class PacketReader: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var packets: [[UInt8]] = []
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    init(fd: Int32, startDelay: TimeInterval = 0) {
        self.fd = fd
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: startDelay)
            loop()
        }
    }

    var count: Int { lock.withLock { packets.count } }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopped }) {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { lock.withLock { packets.append(Array(buf[0..<n])) } }
        }
        close(fd)
        done.signal()
    }

    /// Stops reading (after draining what is buffered) and returns all packets in arrival order.
    func finish() -> [[UInt8]] {
        Thread.sleep(forTimeInterval: 0.1)
        lock.withLock { stopped = true }
        done.wait()
        return lock.withLock { packets }
    }
}

/// 1 kHz stereo sine at amplitude 0.5: `preroll` seconds at once, then wall-clock pace, `seconds` in total.
private final class SineSource: PCMSource, @unchecked Sendable {
    private let rate: Double
    private let total: Int
    private let preroll: Double
    private let queue = DispatchQueue(label: "test.sine")
    private var timer: DispatchSourceTimer?
    private var delivered = 0

    init(rate: Double, seconds: Double, preroll: Double) {
        self.rate = rate
        total = Int(seconds * rate)
        self.preroll = preroll
    }

    func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void) {
        nonisolated(unsafe) let sink = sink
        let t0 = Date()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [self] in
            let due = min(total, Int((Date().timeIntervalSince(t0) + preroll) * rate))
            guard due > delivered else { return }
            var block = [Float](repeating: 0, count: (due - delivered) * 2)
            for i in 0..<(due - delivered) {
                let v = Float(0.5 * sin(2 * Double.pi * 1000 * Double(delivered + i) / rate))
                block[2 * i] = v
                block[2 * i + 1] = v
            }
            delivered = due
            block.withUnsafeBufferPointer { sink($0) }
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
}

/// Calls the sink back to back from its own thread with 10 s of silence in 10 ms blocks.
private final class FloodSource: PCMSource, @unchecked Sendable {
    func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void) {
        nonisolated(unsafe) let sink = sink
        Thread.detachNewThread {
            let block = [Float](repeating: 0, count: 960)
            block.withUnsafeBufferPointer { for _ in 0..<1000 { sink($0) } }
        }
    }

    func stop() {}
}

/// Records the loudest sample it was given; never produces a packet.
private final class SpyEncoder: PacketEncoder, @unchecked Sendable {
    let samplesPerFrame = 128
    private(set) var quality = LDACQuality.hq
    private let lock = NSLock()
    private var blockCount = 0
    private var maxSample: Float = 0

    var blocks: Int { lock.withLock { blockCount } }
    var peak: Float { lock.withLock { maxSample } }

    func setQuality(_ q: LDACQuality) throws { quality = q }

    func encode(_ pcm: UnsafeBufferPointer<Float>) throws -> LDACPacket? {
        lock.withLock {
            blockCount += 1
            maxSample = max(maxSample, pcm.map(abs).max() ?? 0)
        }
        return nil
    }
}
