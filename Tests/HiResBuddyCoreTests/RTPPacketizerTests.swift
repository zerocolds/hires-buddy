@testable import LDACEncoder  // LDACPacket's memberwise init is internal
import XCTest
@testable import HiResBuddyCore

final class RTPPacketizerTests: XCTestCase {
    func testRTPHeaderMatchesPrototype() {
        var p = RTPPacketizer()
        let out = p.packet(for: LDACPacket(frames: 2, bytes: [0xAA]), timestamp: 0)
        XCTAssertEqual(Array(out.prefix(12)), [0x80, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(out[12], 2)
        XCTAssertEqual(out[13], 0xAA)
        XCTAssertEqual(out.count, 14)
        XCTAssertEqual(p.sequence, 1)
    }

    func testSequenceTimestampAndSSRCAreBigEndian() {
        var p = RTPPacketizer(ssrc: 0x0102_0304)
        for _ in 0..<0x0123 { _ = p.packet(for: LDACPacket(frames: 1, bytes: []), timestamp: 0) }
        let out = p.packet(for: LDACPacket(frames: 0x13, bytes: [1, 2]), timestamp: 0xA1B2_C3D4)
        XCTAssertEqual(Array(out.prefix(13)), [0x80, 0x60, 0x01, 0x23, 0xA1, 0xB2, 0xC3, 0xD4, 0x01, 0x02, 0x03, 0x04, 0x03])
        XCTAssertEqual(p.sequence, 0x0124)
    }
}
