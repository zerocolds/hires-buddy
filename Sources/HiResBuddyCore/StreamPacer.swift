/// Real-time pacing for the transport channel: keeps `leadSeconds` of audio in flight ahead of the wall clock.
/// With `prerollSeconds` > 0 the clock starts that much after `start()`, so audio accumulates first: a real-time
/// source then always has (preroll − lead) of audio queued behind the transmitter to absorb its jitter.
public final class StreamPacer {
    public private(set) var dropEvents = 0
    private let sampleRate: Double
    private let samplesPerFrame: Double
    private let lead: Double
    private let preroll: Double
    private let now: () -> Double
    private var origin = 0.0

    public init(sampleRate: Int, samplesPerFrame: Int, leadSeconds: Double = 0.25, prerollSeconds: Double = 0,
                now: @escaping () -> Double) {
        self.sampleRate = Double(sampleRate)
        self.samplesPerFrame = Double(samplesPerFrame)
        self.lead = leadSeconds
        self.preroll = prerollSeconds
        self.now = now
    }

    public func start() {
        origin = now() + preroll
    }

    /// True while the audio already sent is less than `elapsed + lead`. When the sender has fallen more than
    /// 2×lead behind (e.g. the app stalled), the clock origin is moved so that the backlog is dropped instead
    /// of being burst out, and `dropEvents` is incremented.
    public func shouldSend(framesAlreadySent: Int) -> Bool {
        let t = now()
        let audioSent = Double(framesAlreadySent) * samplesPerFrame / sampleRate
        if (t - origin) - audioSent > 2 * lead {
            origin = t - audioSent
            dropEvents += 1
        }
        return audioSent < (t - origin) + lead
    }
}
