import XCTest
@testable import HiResBuddyCore

final class PCMRingBufferTests: XCTestCase {
    func testReadsBackInOrderAcrossTheWrap() {
        let ring = PCMRingBuffer(capacity: 8)
        var out = [Float](repeating: -1, count: 8)
        var got: [Float] = []
        for chunk in [[1, 2, 3, 4, 5], [6, 7, 8, 9], [10, 11, 12]] as [[Float]] {
            chunk.withUnsafeBufferPointer { ring.write($0) }
            let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            got += out[0..<n]
        }
        XCTAssertEqual(got, (1...12).map(Float.init))
        XCTAssertEqual(ring.overflows, 0)
    }

    func testBlockThatDoesNotFitIsDroppedWholeAndCounted() {
        let ring = PCMRingBuffer(capacity: 8)
        [Float](repeating: 1, count: 6).withUnsafeBufferPointer { ring.write($0) }
        [Float](repeating: 2, count: 4).withUnsafeBufferPointer { ring.write($0) }   // only 2 free
        XCTAssertEqual(ring.overflows, 1)
        var out = [Float](repeating: 0, count: 16)
        let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        XCTAssertEqual(Array(out[0..<n]), [Float](repeating: 1, count: 6))
    }
}
