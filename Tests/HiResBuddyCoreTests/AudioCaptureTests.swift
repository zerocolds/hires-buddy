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

    func testRateGuardSetsTheRateBack() {
        var rate = 44100.0
        var writes: [Double] = []
        let error = AudioCapture.enforceRate(expected: 48000, read: { rate },
                                             write: { writes.append($0); rate = $0; return noErr })
        XCTAssertNil(error)
        XCTAssertEqual(writes, [48000])
        XCTAssertEqual(rate, 48000)
    }

    func testRateGuardLeavesTheConfiguredRateAlone() {
        var writes = 0
        XCTAssertNil(AudioCapture.enforceRate(expected: 48000, read: { 48000 }, write: { _ in writes += 1; return noErr }))
        XCTAssertEqual(writes, 0)
    }

    func testRateGuardReportsWhenTheRateWillNotGoBack() {
        let refused = AudioCapture.enforceRate(expected: 48000, read: { 96000 }, write: { _ in -1 })
        XCTAssertEqual(refused, .sampleRateChanged(expected: 48000, actual: 96000))
        let ignored = AudioCapture.enforceRate(expected: 48000, read: { 96000 }, write: { _ in noErr })
        XCTAssertEqual(ignored, .sampleRateChanged(expected: 48000, actual: 96000), "set, but did not stick")
    }

    func testThrowsWhenDeviceMissing() {
        XCTAssertThrowsError(try AudioCapture(deviceName: "no-such-device-xyz", sampleRate: 48000)) { error in
            XCTAssertEqual(error as? HBError, .deviceNotInstalled)
        }
    }
}
