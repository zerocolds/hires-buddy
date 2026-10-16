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

/// Deterministic device list for the restore/fallback logic.
private final class FakeDirectory: AudioDeviceDirectory {
    var devices: [AudioDeviceInfo]
    var defaultOutput: AudioDeviceID

    init(_ devices: [AudioDeviceInfo], defaultOutput: AudioDeviceID) {
        self.devices = devices
        self.defaultOutput = defaultOutput
    }

    func outputDevices() -> [AudioDeviceInfo] { devices }
    func currentDefaultOutput() -> AudioDeviceID { defaultOutput }
    func setDefaultOutput(_ id: AudioDeviceID) throws { defaultOutput = id }
}

private let speakers = AudioDeviceInfo(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", isBuiltIn: true)
private let headphones = AudioDeviceInfo(id: 2, uid: "94-DB-56-E1-43-75:output", name: "WH-1000XM4", isBuiltIn: false)
private let hiresBuddy = AudioDeviceInfo(id: 3, uid: "HiResBuddy_UID", name: "HiRes Buddy", isBuiltIn: false)
private let monitor = AudioDeviceInfo(id: 4, uid: "display-audio", name: "LG Monitor", isBuiltIn: false)

final class OutputDeviceSwitcherFallbackTests: XCTestCase {
    func testRestoreFallsBackWhenPreviousMissing() throws {
        let dir = FakeDirectory([speakers, headphones, hiresBuddy], defaultOutput: headphones.id)
        let switcher = OutputDeviceSwitcher(directory: dir)
        try switcher.switchTo(hiresBuddy.id)
        XCTAssertEqual(dir.defaultOutput, hiresBuddy.id)

        dir.devices = [speakers, hiresBuddy]                         // takeover: the headphones' device is gone
        XCTAssertEqual(try switcher.restore(), .fallback(speakers.name))
        XCTAssertEqual(dir.defaultOutput, speakers.id)

        let back = AudioDeviceInfo(id: 9, uid: headphones.uid, name: headphones.name, isBuiltIn: false)
        dir.devices = [speakers, hiresBuddy, back]                   // reconnected, with a new object id
        XCTAssertEqual(try switcher.restore(), .restored(headphones.name))
        XCTAssertEqual(dir.defaultOutput, back.id)
        XCTAssertEqual(try switcher.restore(), .nothingToRestore)
    }

    func testFallbackWithoutBuiltInPicksAnotherRealOutput() throws {
        let dir = FakeDirectory([hiresBuddy, monitor, headphones], defaultOutput: headphones.id)
        let switcher = OutputDeviceSwitcher(directory: dir)
        try switcher.switchTo(hiresBuddy.id)
        dir.devices = [hiresBuddy, monitor]
        XCTAssertEqual(try switcher.restore(), .fallback(monitor.name))
        XCTAssertEqual(dir.defaultOutput, monitor.id)
    }

    func testSwitchWhileStuckOnHiResBuddyRemembersFallback() throws {
        let dir = FakeDirectory([speakers, hiresBuddy], defaultOutput: hiresBuddy.id)   // left over from a crash
        let switcher = OutputDeviceSwitcher(directory: dir)
        try switcher.switchTo(hiresBuddy.id)
        XCTAssertEqual(try switcher.restore(), .restored(speakers.name))
        XCTAssertEqual(dir.defaultOutput, speakers.id)
    }
}
