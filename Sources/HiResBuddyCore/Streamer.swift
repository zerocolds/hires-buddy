import BTStream
import Foundation
import LDACEncoder
import os

public struct StreamStats: Sendable {
    public var packets: Int
    public var dropEvents: Int
    public var bitrateKbps: Int
    public var sampleRate: Int
    public var quality: LDACQuality
    public var uptime: TimeInterval
    public var bufferSeconds: Double
    /// Packets lost to failed or short writes.
    public var writeErrors: Int
    /// Send ticks cut short because the transport was full (the packet stays queued).
    public var backpressureTicks: Int
}

/// Delivers interleaved stereo Float32 in blocks of any size, from any thread, until `stop`.
public protocol PCMSource: AnyObject {
    func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void)
    func stop()
}

/// What the stream pipeline needs from an LDAC encoder (lets tests inject a spy).
protocol PacketEncoder: AnyObject {
    var samplesPerFrame: Int { get }
    var quality: LDACQuality { get }
    func setQuality(_ quality: LDACQuality) throws
    func encode(_ pcm: UnsafeBufferPointer<Float>) throws -> LDACPacket?
}

extension LDACEncoder: PacketEncoder {}

/// PCM source → gain → LDAC → RTP → session transport fd, paced in real time.
/// Single-use: the session only starts from Idle, so stream again with a new session and a new Streamer.
@MainActor
public final class Streamer {
    public var quality: LDACQuality {
        didSet {
            let q = quality
            engine?.queue.async { [engine] in engine?.setQuality(q) }
        }
    }

    /// 0…1, applied to the PCM before encoding.
    public var gain: Float = 1 {
        didSet {
            let g = max(0, min(1, gain))
            engine?.queue.async { [engine] in engine?.gain = g }
        }
    }

    public private(set) var stats: StreamStats
    /// Once per second while streaming.
    public var onStats: ((StreamStats) -> Void)?
    /// Every session state change; `error` is set for `.failed`. The pipeline is already stopped for Failed/Closed.
    public var onStateChange: ((HBSessionState, Error?) -> Void)?

    private let session: HBAVDTPSession
    private let sampleRate: LDACSampleRate
    private let makeEncoder: (LDACSampleRate, LDACQuality) throws -> any PacketEncoder
    private var delegateProxy: SessionDelegateProxy?
    private var source: PCMSource?
    private var engine: StreamEngine?
    private var activity: NSObjectProtocol?

    public convenience init(session: HBAVDTPSession, sampleRate: LDACSampleRate, quality: LDACQuality) {
        self.init(session: session, sampleRate: sampleRate, quality: quality,
                  makeEncoder: { try LDACEncoder(sampleRate: $0, quality: $1) })
    }

    init(session: HBAVDTPSession, sampleRate: LDACSampleRate, quality: LDACQuality,
         makeEncoder: @escaping (LDACSampleRate, LDACQuality) throws -> any PacketEncoder) {
        self.session = session
        self.sampleRate = sampleRate
        self.quality = quality
        self.makeEncoder = makeEncoder
        stats = StreamStats(packets: 0, dropEvents: 0, bitrateKbps: 0, sampleRate: sampleRate.rawValue,
                            quality: quality, uptime: 0, bufferSeconds: 0, writeErrors: 0,
                            backpressureTicks: 0)
    }

    /// Starts the session; the source is started once the session reports Streaming.
    public func start(source: PCMSource) throws {
        guard self.source == nil else { return }
        let engine = StreamEngine(encoder: try makeEncoder(sampleRate, quality), sampleRate: sampleRate.rawValue)
        engine.gain = max(0, min(1, gain))
        engine.onStats = { [weak self] s in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish(s) } }
        }
        self.engine = engine
        self.source = source
        // keeps App Nap from coalescing the 4 ms send timer while streaming in the background
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "LDAC streaming")
        let proxy = SessionDelegateProxy { [weak self] state, err in self?.sessionChanged(state, err) }
        delegateProxy = proxy
        session.delegate = proxy
        session.start(withSampleRateBit: sampleRate.avdtpBit)
    }

    /// Stops the source and the writer, then hands the headphones back to macOS (Closed arrives via onStateChange).
    public func stop() {
        stopPipeline()
        session.stopAndRestoreSystemAudio()
    }

    private func sessionChanged(_ state: HBSessionState, _ err: Error?) {
        switch state {
        case .streaming:
            guard let engine, let source else { break }
            if engine.isRunning {
                engine.queue.sync { engine.setPaused(false) }   // back from Suspended
            } else {
                engine.queue.sync { engine.start(fd: session.transportFD) }
                source.start { block in
                    let samples = Array(block)
                    engine.queue.async { engine.ingest(samples) }
                }
            }
        case .suspended:
            if let engine { engine.queue.sync { engine.setPaused(true) } }
        case .failed, .closed:
            stopPipeline()   // synchronously: the transport fd is closed right after this callback
        default:
            break
        }
        onStateChange?(state, err)
    }

    private func stopPipeline() {
        source?.stop()
        source = nil
        if let engine { engine.queue.sync { engine.stop() } }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func publish(_ s: StreamStats) {
        stats = s
        onStats?(s)
    }
}

/// HBAVDTPSessionDelegate needs an NSObject; Streamer stays a plain class.
private final class SessionDelegateProxy: NSObject, HBAVDTPSessionDelegate, @unchecked Sendable {
    private let handler: @MainActor (HBSessionState, Error?) -> Void

    init(_ handler: @escaping @MainActor (HBSessionState, Error?) -> Void) {
        self.handler = handler
    }

    func session(_ s: HBAVDTPSession, didChange state: HBSessionState, error err: Error?) {
        MainActor.assumeIsolated { handler(state, err) }
    }
}

/// Everything below runs on `queue` only (state is not locked).
private final class StreamEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "hiresbuddy.stream", qos: .userInteractive)
    var gain: Float = 1
    var onStats: (@Sendable (StreamStats) -> Void)?
    private(set) var isRunning = false

    private static let blockSamples = LDACEncoder.framesPerBlock * 2
    private static let rtpHeaderBytes = 13   // RTP header + LDAC media payload header
    private static let leadSeconds = 0.25

    private let log = Logger(subsystem: "HiResBuddy", category: "stream")
    private let encoder: any PacketEncoder
    private let sampleRate: Int
    private let pacer: StreamPacer
    private var packetizer = RTPPacketizer()
    private var fd: Int32 = -1
    private var pending: [Float] = []
    private var scratch: [Float]
    private var queued: [(rtp: [UInt8], frames: Int)] = []
    private var queuedFrames = 0
    private var framesPacketized = 0
    private var framesSent = 0
    private var pacerStarted = false
    private var framesAtPacerStart = 0
    private var paused = false
    private var sendTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var startTime = 0.0
    private var packets = 0
    private var writeErrors = 0
    private var backpressureTicks = 0
    private var loggedWriteError = false
    private var loggedEncodeError = false
    private var windowBytes = 0
    private var windowStart = 0.0

    init(encoder: any PacketEncoder, sampleRate: Int) {
        self.encoder = encoder
        self.sampleRate = sampleRate
        // Transmission starts 2×lead after the first packet: lead goes out at once (the sink's cushion), and lead
        // stays queued here so that source/scheduling jitter below that is absorbed instead of reaching the sink.
        pacer = StreamPacer(sampleRate: sampleRate, samplesPerFrame: encoder.samplesPerFrame,
                            leadSeconds: Self.leadSeconds, prerollSeconds: 2 * Self.leadSeconds,
                            now: { ProcessInfo.processInfo.systemUptime })
        scratch = [Float](repeating: 0, count: Self.blockSamples)
    }

    func start(fd: Int32) {
        self.fd = fd
        // Non-blocking: a full transport must not stall this queue (stop() and the session callbacks sync onto it).
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        isRunning = true
        startTime = ProcessInfo.processInfo.systemUptime
        windowStart = startTime
        sendTimer = makeTimer(every: .milliseconds(4)) { $0.pump() }
        statsTimer = makeTimer(every: .seconds(1), firstAfter: .seconds(1)) { $0.reportStats() }
    }

    func stop() {
        isRunning = false
        sendTimer?.cancel()
        statsTimer?.cancel()
        sendTimer = nil
        statsTimer = nil
        fd = -1
        queued.removeAll()
        queuedFrames = 0
    }

    /// Suspended: nothing is written; the source keeps feeding. On resume the backlog is dropped (it is stale) and
    /// pacing restarts with a fresh preroll.
    func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        if !p {
            queued.removeAll()
            queuedFrames = 0
            pacerStarted = false
        }
    }

    func setQuality(_ q: LDACQuality) {
        do { try encoder.setQuality(q) } catch { log.error("quality switch to \(String(describing: q)) failed: \(error)") }
    }

    /// Cuts the block into 128-frame chunks, applies gain, encodes, and queues RTP packets.
    func ingest(_ samples: [Float]) {
        guard isRunning else { return }
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= Self.blockSamples {
            for i in 0..<Self.blockSamples { scratch[i] = pending[offset + i] * gain }
            offset += Self.blockSamples
            let packet: LDACPacket?
            do {
                packet = try scratch.withUnsafeBufferPointer { try encoder.encode($0) }
            } catch {
                if !loggedEncodeError { log.error("encode failed: \(error)") }
                loggedEncodeError = true
                continue
            }
            guard let packet else { continue }
            let rtp = packetizer.packet(for: packet, timestamp: UInt32(truncatingIfNeeded: framesPacketized * encoder.samplesPerFrame))
            framesPacketized += packet.frames
            queued.append((rtp, packet.frames))
            queuedFrames += packet.frames
        }
        pending.removeFirst(offset)
    }

    private func pump() {
        guard isRunning, !paused, fd >= 0 else { return }
        while let next = queued.first {
            if !pacerStarted {
                pacer.start()
                pacerStarted = true
                framesAtPacerStart = framesSent
            }
            let drops = pacer.dropEvents
            let due = pacer.shouldSend(framesAlreadySent: framesSent - framesAtPacerStart)
            if pacer.dropEvents != drops {
                // the sender stalled: drop the backlog instead of bursting it (latency must not accumulate)
                queued.removeAll()
                queuedFrames = 0
                return
            }
            guard due else { return }
            let written = next.rtp.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS) {
                backpressureTicks += 1   // transport full: keep the packet for the next tick
                return
            }
            if written == next.rtp.count {
                packets += 1
                windowBytes += written - Self.rtpHeaderBytes
            } else {
                writeErrors += 1
                if !loggedWriteError {
                    log.error("transport write \(written)/\(next.rtp.count) bytes, errno \(errno)")
                    loggedWriteError = true
                }
            }
            queued.removeFirst()
            queuedFrames -= next.frames
            framesSent += next.frames
        }
    }

    private func reportStats() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(now - windowStart, 0.001)
        let s = StreamStats(
            packets: packets,
            dropEvents: pacer.dropEvents,
            bitrateKbps: Int((Double(windowBytes) * 8 / 1000 / elapsed).rounded()),
            sampleRate: sampleRate,
            quality: encoder.quality,
            uptime: now - startTime,
            bufferSeconds: Double(queuedFrames * encoder.samplesPerFrame) / Double(sampleRate),
            writeErrors: writeErrors,
            backpressureTicks: backpressureTicks)
        windowBytes = 0
        windowStart = now
        onStats?(s)
    }

    private func makeTimer(every interval: DispatchTimeInterval, firstAfter delay: DispatchTimeInterval = .never,
                           _ tick: @escaping (StreamEngine) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let first: DispatchTime = delay == .never ? .now() : .now() + delay
        t.schedule(deadline: first, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in if let self { tick(self) } }
        t.resume()
        return t
    }
}
