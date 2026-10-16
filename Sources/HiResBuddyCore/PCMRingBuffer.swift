import Synchronization

/// Single-producer/single-consumer ring of Float samples. `write` (the producer, e.g. a CoreAudio real-time thread)
/// neither allocates nor locks; a block that does not fit is dropped whole and counted in `overflows`.
final class PCMRingBuffer: @unchecked Sendable {   // the storage is only touched as the indices allow
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let written = Atomic<Int>(0)   // total samples written; only the producer stores
    private let consumed = Atomic<Int>(0)  // total samples read; only the consumer stores
    private let overflowCount = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Blocks dropped because the ring was full.
    var overflows: Int { overflowCount.load(ordering: .relaxed) }

    /// Producer side.
    func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        let w = written.load(ordering: .relaxed)
        let free = capacity - (w - consumed.load(ordering: .acquiring))
        guard samples.count <= free else {
            overflowCount.add(1, ordering: .relaxed)
            return
        }
        let start = w % capacity
        let first = min(samples.count, capacity - start)
        (storage + start).update(from: base, count: first)
        if first < samples.count { storage.update(from: base + first, count: samples.count - first) }
        written.store(w + samples.count, ordering: .releasing)
    }

    /// Consumer side: copies up to `out.count` samples, returns how many.
    func read(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let dst = out.baseAddress else { return 0 }
        let r = consumed.load(ordering: .relaxed)
        let n = min(out.count, written.load(ordering: .acquiring) - r)
        guard n > 0 else { return 0 }
        let start = r % capacity
        let first = min(n, capacity - start)
        dst.update(from: storage + start, count: first)
        if first < n { (dst + first).update(from: storage, count: n - first) }
        consumed.store(r + n, ordering: .releasing)
        return n
    }
}
