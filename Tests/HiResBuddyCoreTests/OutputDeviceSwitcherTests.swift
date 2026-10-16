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

final class OutputDeviceSwitcherManualChangeTests: XCTestCase {
    func testRestoreLeavesAManualChoiceAlone() throws {
        let dir = FakeDirectory([speakers, headphones, hiresBuddy, monitor], defaultOutput: headphones.id)
        let switcher = OutputDeviceSwitcher(directory: dir)
        try switcher.switchTo(hiresBuddy.id)
        dir.defaultOutput = monitor.id                               // the user picked the monitor meanwhile
        XCTAssertEqual(try switcher.restore(), .nothingToRestore)
        XCTAssertEqual(dir.defaultOutput, monitor.id, "a manual change is not overridden")
        XCTAssertEqual(try switcher.restore(), .nothingToRestore, "and nothing stays remembered")
    }

    func testRestoreAfterFallbackLeavesAManualChoiceAlone() throws {
        let dir = FakeDirectory([speakers, headphones, hiresBuddy, monitor], defaultOutput: headphones.id)
        let switcher = OutputDeviceSwitcher(directory: dir)
        try switcher.switchTo(hiresBuddy.id)
        dir.devices = [speakers, hiresBuddy, monitor]
        XCTAssertEqual(try switcher.restore(), .fallback(speakers.name))
        dir.defaultOutput = monitor.id                               // chosen by hand while on the fallback
        dir.devices.append(headphones)
        XCTAssertEqual(try switcher.restore(), .nothingToRestore)
        XCTAssertEqual(dir.defaultOutput, monitor.id)
    }
}

final class OutputDeviceSwitcherPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "OutputDeviceSwitcherPersistenceTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testSwitchPersistsAndRestoreClears() throws {
        let dir = FakeDirectory([speakers, headphones, hiresBuddy], defaultOutput: headphones.id)
        let switcher = OutputDeviceSwitcher(directory: dir, defaults: defaults)
        try switcher.switchTo(hiresBuddy.id)
        XCTAssertEqual(defaults.string(forKey: OutputDeviceSwitcher.Keys.previousUID), headphones.uid)
        XCTAssertEqual(defaults.string(forKey: OutputDeviceSwitcher.Keys.previousName), headphones.name)
        XCTAssertEqual(try switcher.restore(), .restored(headphones.name))
        XCTAssertNil(defaults.string(forKey: OutputDeviceSwitcher.Keys.previousUID))
    }

    func testRelaunchAfterCrashRestoresThePersistedDevice() throws {
        let dir = FakeDirectory([speakers, headphones, hiresBuddy], defaultOutput: headphones.id)
        try OutputDeviceSwitcher(directory: dir, defaults: defaults).switchTo(hiresBuddy.id)   // then the app dies

        let relaunched = OutputDeviceSwitcher(directory: dir, defaults: defaults)
        XCTAssertEqual(try relaunched.restoreIfStuck(), .restored(headphones.name))
        XCTAssertEqual(dir.defaultOutput, headphones.id)
        XCTAssertNil(defaults.string(forKey: OutputDeviceSwitcher.Keys.previousUID), "cleared once restored")
    }

    func testRelaunchWhileThePersistedDeviceIsAbsentFallsBackAndKeepsIt() throws {
        let dir = FakeDirectory([speakers, headphones, hiresBuddy], defaultOutput: headphones.id)
        try OutputDeviceSwitcher(directory: dir, defaults: defaults).switchTo(hiresBuddy.id)
        dir.devices = [speakers, hiresBuddy]

        let relaunched = OutputDeviceSwitcher(directory: dir, defaults: defaults)
        XCTAssertEqual(try relaunched.restoreIfStuck(), .fallback(speakers.name))
        XCTAssertEqual(dir.defaultOutput, speakers.id)
        XCTAssertEqual(defaults.string(forKey: OutputDeviceSwitcher.Keys.previousUID), headphones.uid)
    }

    func testRelaunchStuckWithoutPersistedDeviceUsesTheFallback() throws {
        let dir = FakeDirectory([speakers, hiresBuddy], defaultOutput: hiresBuddy.id)
        XCTAssertEqual(try OutputDeviceSwitcher(directory: dir, defaults: defaults).restoreIfStuck(), .restored(speakers.name))
        XCTAssertEqual(dir.defaultOutput, speakers.id)
    }

    func testRelaunchNotStuckLeavesTheOutputAndForgetsAStaleDevice() throws {
        defaults.set(headphones.uid, forKey: OutputDeviceSwitcher.Keys.previousUID)
        let dir = FakeDirectory([speakers, headphones, hiresBuddy], defaultOutput: speakers.id)
        XCTAssertNil(try OutputDeviceSwitcher(directory: dir, defaults: defaults).restoreIfStuck())
        XCTAssertEqual(dir.defaultOutput, speakers.id)
        XCTAssertNil(defaults.string(forKey: OutputDeviceSwitcher.Keys.previousUID))
    }
}
