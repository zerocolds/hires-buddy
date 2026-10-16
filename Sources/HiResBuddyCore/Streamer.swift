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
    /// Source blocks dropped because the input ring was full (the source delivered faster than it is drained).
    public var inputOverflows: Int
    /// PCM frames (per channel) thrown away: drained unencoded while suspended, or trimmed from the head of the
    /// send queue by its cap.
    public var discardedFrames: Int
}

/// Delivers interleaved stereo Float32 in blocks of any size, from any thread (also a real-time one: the
/// Streamer's sink neither allocates nor locks), until `stop`. Blocks larger than 2 s at 96 kHz are dropped.
public protocol PCMSource: AnyObject {
    func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void)
    func stop()
    /// Why the last `start` delivers nothing (`start` cannot throw); nil after a successful start.
    var startError: (any Error)? { get }
    /// `handler` is called on the main queue if the source fails after a successful start (nothing more comes).
    func onFailure(_ handler: @escaping @MainActor (any Error) -> Void)
}

public extension PCMSource {
    var startError: (any Error)? { nil }
    func onFailure(_ handler: @escaping @MainActor (any Error) -> Void) {}
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
    /// When the Streamer ends the stream itself — the source did not start or failed, or the transport died — it
    /// stops the session (giving the headphones back) and reports `.failed` with that cause instead of `.closed`
    /// (`StreamFailure`, or HBErrorDomain/HBErrorSinkDisconnected for a dead transport); a `.streaming` that the
    /// failure cut short is not reported.
    public var onStateChange: ((HBSessionState, Error?) -> Void)?

    private let session: HBAVDTPSession
    private let sampleRate: LDACSampleRate
    private let makeEncoder: (LDACSampleRate, LDACQuality) throws -> any PacketEncoder
    private var delegateProxy: SessionDelegateProxy?
    private var source: PCMSource?
    private var engine: StreamEngine?
    private var activity: NSObjectProtocol?
    /// Why the Streamer ended the stream itself; nil otherwise.
    private var failure: Error?
    private let log = Logger(subsystem: "HiResBuddy", category: "stream")

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
                            backpressureTicks: 0, inputOverflows: 0, discardedFrames: 0)
    }

    /// Starts the session; the source is started once the session reports Streaming.
    public func start(source: PCMSource) throws {
        guard self.source == nil else { return }
        let engine = StreamEngine(encoder: try makeEncoder(sampleRate, quality), sampleRate: sampleRate.rawValue)
        engine.gain = max(0, min(1, gain))
        engine.onStats = { [weak self] s in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish(s) } }
        }
        engine.onTransportDead = { [weak self] why in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.fail(NSError(domain: HBErrorDomain, code: HBSessionError.errorSinkDisconnected.rawValue,
                                       userInfo: [NSLocalizedDescriptionKey: why]))
                }
            }
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
            guard failure == nil else { return }
            guard let engine, let source else { break }
            if engine.isRunning {
                engine.queue.sync { engine.setPaused(false) }   // back from Suspended
            } else {
                engine.queue.sync { engine.start(fd: session.transportFD) }
                let ring = engine.input
                source.onFailure { [weak self] error in self?.fail(StreamFailure.sourceFailed(error)) }
                source.start { block in ring.write(block) }   // drained by the engine's send timer
                if let error = source.startError {
                    fail(StreamFailure.captureFailed(error))
                    return   // not streaming after all: the session stop above reports the failure
                }
            }
        case .suspended:
            if let engine { engine.queue.sync { engine.setPaused(true) } }
        case .failed, .closed:
            stopPipeline()   // synchronously: the transport fd is closed right after this callback
            if let failure {
                onStateChange?(.failed, failure)
                return
            }
        default:
            if failure != nil { return }
        }
        onStateChange?(state, err)
    }

    /// Ends the stream from this side: stops the pipeline and the session (which gives the headphones back); the
    /// session's Closed is then reported as `.failed` with `error`. Once per stream; ignored after it ended.
    private func fail(_ error: Error) {
        guard failure == nil, source != nil else { return }
        failure = error
        log.error("stream failed: \(String(describing: error), privacy: .public)")
        stopPipeline()
        session.stopAndRestoreSystemAudio()
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
    /// Called on `queue`, once, when writes show the transport is gone; the engine has already stopped.
    var onTransportDead: (@Sendable (String) -> Void)?
    private(set) var isRunning = false

    private static let blockSamples = LDACEncoder.framesPerBlock * 2
    private static let rtpHeaderBytes = 13   // RTP header + LDAC media payload header
    private static let leadSeconds = 0.25
    private static let prerollSeconds = 2 * leadSeconds
    /// Cap on queued audio in every state: the pre-roll target plus 2×lead. (Steady state holds preroll − lead; the
    /// pacer itself drops the backlog once the sender is 2×lead late, but it is not consulted while suspended or
    /// before the first send.)
    private static let maxQueuedSeconds = prerollSeconds + 2 * leadSeconds
    private static let drainSamples = 4096
    /// errno values after which a write can never succeed again.
    private static let deadTransportErrors: Set<Int32> = [EPIPE, ECONNRESET, EBADF, ENOTCONN, ECONNREFUSED]
    /// Back-to-back failed writes for this long also count as a dead transport.
    private static let deadAfterFailingFor = 1.0

    /// Written by the source (any thread, lock-free), drained on `queue` every send tick: 2 s of stereo at 96 kHz.
    let input = PCMRingBuffer(capacity: 2 * 96_000 * 2)
    private var drainBuffer: [Float]

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
    private var discardedFrames = 0
    private var failingSince: Double?   // first of the current run of failed writes
    private var windowBytes = 0
    private var windowStart = 0.0

    init(encoder: any PacketEncoder, sampleRate: Int) {
        self.encoder = encoder
        self.sampleRate = sampleRate
        // Transmission starts 2×lead after the first packet: lead goes out at once (the sink's cushion), and lead
        // stays queued here so that source/scheduling jitter below that is absorbed instead of reaching the sink.
        pacer = StreamPacer(sampleRate: sampleRate, samplesPerFrame: encoder.samplesPerFrame,
                            leadSeconds: Self.leadSeconds, prerollSeconds: Self.prerollSeconds,
                            now: { ProcessInfo.processInfo.systemUptime })
        scratch = [Float](repeating: 0, count: Self.blockSamples)
        drainBuffer = [Float](repeating: 0, count: Self.drainSamples)
    }

    func start(fd: Int32) {
        self.fd = fd
        // Non-blocking: a full transport must not stall this queue (stop() and the session callbacks sync onto it).
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var one: Int32 = 1   // a dead transport must report EPIPE, not kill the process with SIGPIPE
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
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

    /// Suspended: nothing is written or encoded; what the source keeps feeding is drained and discarded. On resume
    /// the backlog is dropped (it is stale) and pacing restarts with a fresh preroll.
    func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        if !p {
            queued.removeAll()
            queuedFrames = 0
            pending.removeAll(keepingCapacity: true)
            pacerStarted = false
        }
    }

    func setQuality(_ q: LDACQuality) {
        do { try encoder.setQuality(q) } catch { log.error("quality switch to \(String(describing: q)) failed: \(error)") }
    }

    /// Cuts the block into 128-frame chunks, applies gain, encodes, and queues RTP packets.
    func ingest(_ samples: UnsafeBufferPointer<Float>) {
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
        trimQueue()
    }

    /// Drops the oldest packets while more than maxQueuedSeconds of audio is queued.
    private func trimQueue() {
        let maxFrames = Int(Self.maxQueuedSeconds * Double(sampleRate)) / encoder.samplesPerFrame
        while queuedFrames > maxFrames, let first = queued.first {
            queued.removeFirst()
            queuedFrames -= first.frames
            discardedFrames += first.frames * encoder.samplesPerFrame
        }
    }

    /// Moves everything the source has delivered so far into the encoder; while paused it is discarded unencoded.
    private func drainInput() {
        while true {
            let n = drainBuffer.withUnsafeMutableBufferPointer { input.read(into: $0) }
            if n == 0 { return }
            if paused {
                discardedFrames += n / 2
                continue
            }
            drainBuffer.withUnsafeBufferPointer { ingest(UnsafeBufferPointer(rebasing: $0[0..<n])) }
        }
    }

    private func pump() {
        guard isRunning else { return }
        drainInput()
        guard !paused, fd >= 0 else { return }
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
            let err = written < 0 ? errno : 0
            if written < 0 && (err == EAGAIN || err == EWOULDBLOCK || err == ENOBUFS) {
                backpressureTicks += 1   // transport full: keep the packet for the next tick
                return
            }
            if written == next.rtp.count {
                packets += 1
                windowBytes += written - Self.rtpHeaderBytes
                failingSince = nil
            } else {
                writeErrors += 1
                if !loggedWriteError {
                    log.error("transport write \(written)/\(next.rtp.count) bytes, errno \(err)")
                    loggedWriteError = true
                }
                let now = ProcessInfo.processInfo.systemUptime
                if failingSince == nil { failingSince = now }
                if Self.deadTransportErrors.contains(err) {
                    return transportDied("transport write failed: \(String(cString: strerror(err))) (errno \(err))")
                }
                if let since = failingSince, now - since >= Self.deadAfterFailingFor {
                    return transportDied("transport writes failing for \(Self.deadAfterFailingFor) s (errno \(err))")
                }
            }
            queued.removeFirst()
            queuedFrames -= next.frames
            framesSent += next.frames
        }
    }

    private func transportDied(_ why: String) {
        log.error("\(why, privacy: .public): stopping the stream")
        stop()
        onTransportDead?(why)
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
            backpressureTicks: backpressureTicks,
            inputOverflows: input.overflows,
            discardedFrames: discardedFrames)
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
