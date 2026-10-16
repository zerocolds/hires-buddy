import XCTest
@testable import HiResBuddyCore

final class StreamPacerTests: XCTestCase {
    func testPacerKeepsLead() {
        var clock = 0.0
        let pacer = StreamPacer(sampleRate: 48000, samplesPerFrame: 256, now: { clock })
        pacer.start()
        // 0.25 s lead = 46.875 frames of 256 samples at 48 kHz
        var sent = 0
        while pacer.shouldSend(framesAlreadySent: sent) { sent += 1; XCTAssertLessThan(sent, 1000) }
        XCTAssertEqual(sent, 47)
        clock = 0.1                                   // 0.1 s later another 18.75 frames are due
        while pacer.shouldSend(framesAlreadySent: sent) { sent += 1 }
        XCTAssertEqual(sent, 66)
        XCTAssertEqual(pacer.dropEvents, 0)
    }

    func testPacerDropsWhenBehind() {
        var clock = 0.0
        let pacer = StreamPacer(sampleRate: 48000, samplesPerFrame: 256, now: { clock })
        pacer.start()
        clock = 1.0
        XCTAssertTrue(pacer.shouldSend(framesAlreadySent: 0))
        XCTAssertEqual(pacer.dropEvents, 1)
        // the backlog is gone: only the normal lead is due from here
        var sent = 0
        while pacer.shouldSend(framesAlreadySent: sent) { sent += 1 }
        XCTAssertEqual(sent, 47)
        XCTAssertEqual(pacer.dropEvents, 1)
    }
}
