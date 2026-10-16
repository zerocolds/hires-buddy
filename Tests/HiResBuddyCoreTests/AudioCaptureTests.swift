import XCTest
@testable import HiResBuddyCore

final class AudioCaptureTests: XCTestCase {
    func testCaptureDeliversSilenceWhenNothingPlays() throws {
        try XCTSkipIf(OutputDeviceSwitcher().deviceID(named: AudioCapture.deviceName) == nil,
                      "\(AudioCapture.deviceName) driver not installed")
        let capture = try AudioCapture(sampleRate: 48000)
        let lock = NSLock()
        var blocks = 0
        var samples = 0
        var nonZero = 0
        let firstBlock = expectation(description: "first block")
        capture.start { block in
            lock.lock()
            blocks += 1
            samples += block.count
            nonZero += block.reduce(0) { $1 == 0 ? $0 : $0 + 1 }
            let isFirst = blocks == 1
            lock.unlock()
            if isFirst { firstBlock.fulfill() }
        }
        wait(for: [firstBlock], timeout: 0.5)
        capture.stop()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertGreaterThan(samples, 0)
        XCTAssertEqual(samples % 2, 0, "interleaved stereo")
        XCTAssertEqual(nonZero, 0)
    }

    func testThrowsWhenDeviceMissing() {
        XCTAssertThrowsError(try AudioCapture(deviceName: "no-such-device-xyz", sampleRate: 48000)) { error in
            XCTAssertEqual(error as? HBError, .deviceNotInstalled)
        }
    }
}
