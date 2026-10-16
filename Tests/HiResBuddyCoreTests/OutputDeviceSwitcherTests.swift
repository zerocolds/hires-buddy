import CoreAudio
import XCTest
@testable import HiResBuddyCore

final class OutputDeviceSwitcherTests: XCTestCase {
    func testSwitchToCurrentAndRestoreIsNoop() throws {
        let switcher = OutputDeviceSwitcher()
        let before = switcher.current()
        try XCTSkipIf(before == kAudioObjectUnknown, "no default output device")
        try switcher.switchTo(before)
        try switcher.restore()
        XCTAssertEqual(switcher.current(), before)
    }

    func testUnknownNameReturnsNil() {
        XCTAssertNil(OutputDeviceSwitcher().deviceID(named: "no such device \(UUID())"))
    }

    func testPairedA2DPDevicesDoesNotThrow() {
        let devices = HeadphoneDiscovery.pairedA2DPDevices()
        for d in devices { XCTAssertEqual(d.id, d.id.lowercased()); XCTAssertFalse(d.id.contains(":")) }
    }
}
