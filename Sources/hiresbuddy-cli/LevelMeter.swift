import Foundation
import HiResBuddyCore
import Synchronization

/// Passes a source through and remembers the peak sample since the last `takePeakDBFS()` — shows whether
/// captured audio is actually flowing (a source that delivers only zeros streams just as happily).
final class LevelMeter: PCMSource {
    private let source: PCMSource
    private let peakBits = Atomic<UInt32>(0)   // Float bit pattern; non-negative floats order like their bits

    init(_ source: PCMSource) { self.source = source }

    func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void) {
        source.start { [self] block in
            var peak: Float = 0
            for s in block { peak = max(peak, abs(s)) }
            peakBits.max(peak.bitPattern, ordering: .relaxed)
            sink(block)
        }
    }

    func stop() { source.stop() }

    func takePeakDBFS() -> Double {
        let peak = Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
        return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    }
}
