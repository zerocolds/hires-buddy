import BTStream
import CoreAudio
import Foundation
import IOBluetooth
import XCTest
@testable import HiResBuddyCore
import LDACEncoder

@MainActor
final class SessionControllerTests: XCTestCase {
    func testNoDeviceDisablesToggle() async {
        let h = Harness(paired: [])
        await h.controller.refreshHeadphones()
        XCTAssertNil(h.controller.selected)
        XCTAssertFalse(h.controller.canEnable)
        h.controller.setEnabled(true)
        XCTAssertEqual(h.controller.phase, .off)
        XCTAssertTrue(h.recorder.sessions.isEmpty)
        XCTAssertEqual(h.directory.defaultOutput, xm4Output.id, "the output is left alone")
    }

    func testEnableSwitchesOutputAndStartsStream() async {
        let h = Harness()
        await h.controller.refreshHeadphones()
        XCTAssertEqual(h.controller.selected?.id, xm4.id)
        XCTAssertTrue(h.controller.driverInstalled)
        XCTAssertTrue(h.controller.canEnable)

        h.controller.setEnabled(true)
        XCTAssertEqual(h.controller.phase, .connecting)
        XCTAssertEqual(h.directory.defaultOutput, hiresBuddy.id, "default output is HiRes Buddy")
        XCTAssertEqual(h.recorder.sessions.count, 1)
        XCTAssertEqual(h.recorder.sessions.first?.startedBit, LDACSampleRate.hz48000.avdtpBit)
        XCTAssertEqual(h.recorder.addresses, [xm4.id])

        h.recorder.sessions[0].move(to: .streaming)
        XCTAssertEqual(h.controller.phase, .streaming)
        XCTAssertTrue(h.capture.started, "capture starts once the session streams")
    }

    func testDisableRestoresOutputAndSystemAudio() async {
        let h = Harness()
        await h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        h.link.connected = [false, false, true]   // the restore hook drops the link, then macOS reconnects

        h.controller.setEnabled(false)
        XCTAssertTrue(h.recorder.sessions[0].stopCalled, "stopAndRestoreSystemAudio")
        XCTAssertTrue(h.capture.stopped)
        XCTAssertEqual(h.directory.defaultOutput, speakers.id, "output restored at once (headphones absent: fallback)")

        h.directory.devices.append(xm4Output)       // the headphones' output device is back
        await spin(until: { h.controller.phase == .off })
        XCTAssertEqual(h.controller.phase, .off)
        XCTAssertFalse(h.controller.isReturningHeadphones)
        XCTAssertEqual(h.directory.defaultOutput, xm4Output.id, "the previous output wins once it is back")
        XCTAssertNil(h.controller.stats)
    }

    func testSessionFailureGoesToErrorAndRestores() async {
        let h = Harness()
        await h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)

        h.recorder.sessions[0].move(to: .failed, error: HBSessionError(.errorSinkDisconnected))
        guard case .error(let message) = h.controller.phase else { return XCTFail("phase \(h.controller.phase)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotEqual(h.directory.defaultOutput, hiresBuddy.id, "output restored")
        XCTAssertTrue(h.controller.isReturningHeadphones)

        h.link.connected = [false, true]
        h.directory.devices.append(xm4Output)
        await spin(until: { !h.controller.isReturningHeadphones })
        XCTAssertFalse(h.controller.isReturningHeadphones)
        XCTAssertEqual(h.directory.defaultOutput, xm4Output.id)
        if case .error = h.controller.phase {} else { XCTFail("the error stays visible, phase \(h.controller.phase)") }
    }

    func testUnrequestedCloseShowsAnErrorAndRestores() async {
        let h = Harness()
        await h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        h.link.connected = [false, true]

        h.recorder.sessions[0].move(to: .closed)
        if case .error = h.controller.phase {} else { XCTFail("phase \(h.controller.phase)") }
        h.directory.devices.append(xm4Output)
        await spin(until: { !h.controller.isReturningHeadphones })
        XCTAssertEqual(h.directory.defaultOutput, xm4Output.id)
        h.controller.setEnabled(false)
        XCTAssertEqual(h.controller.phase, .off, "switching off clears the error")
    }

    func testRestoreThatThrowsIsRetried() async {
        let h = Harness()
        await h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        h.link.connected = [false, true]
        h.directory.devices.append(xm4Output)   // back already, but the HAL refuses the first switches
        h.directory.failingSets = 3

        h.controller.setEnabled(false)
        await spin(until: { h.controller.phase == .off })
        XCTAssertEqual(h.controller.phase, .off)
        XCTAssertEqual(h.directory.defaultOutput, xm4Output.id, "a throwing restore does not end the retries")
    }

    func testMicrophoneAnswerFromABackgroundQueueIsDeliveredOnMain() async {
        var answer: Bool?
        MicrophonePermission.request(
            status: .notDetermined,
            ask: { reply in DispatchQueue.global().async { reply(true) } },   // like TCC's reply thread
            completion: { granted in
                MainActor.assertIsolated()
                answer = granted
            })
        await spin(until: { answer != nil })
        XCTAssertEqual(answer, true)
    }

    func testQualityChangePropagatesWhileStreaming() async {
        let h = Harness()
        await h.controller.refreshHeadphones()
        h.controller.quality = .hq
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        XCTAssertEqual(h.controller.streamer?.quality, .hq)

        h.controller.quality = .mq
        XCTAssertEqual(h.controller.streamer?.quality, .mq)
        XCTAssertEqual(h.defaults.integer(forKey: "defaultQuality"), LDACQuality.mq.rawValue, "persisted")
        h.controller.setEnabled(false)
    }

    func testQuitWaitsForTheHeadphonesBeforeTerminating() async {
        let h = Harness()
        await h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        h.link.connected = [false, true]
        var terminated = false

        h.controller.quit { terminated = true }
        XCTAssertFalse(terminated, "not before the headphones are back")
        XCTAssertTrue(h.recorder.sessions[0].stopCalled)
        h.directory.devices.append(xm4Output)
        await spin(until: { terminated })
        XCTAssertTrue(terminated)
        XCTAssertEqual(h.directory.defaultOutput, xm4Output.id)
    }

    /// Yields the main actor (the controller's timers run on the main queue) until `done` or the timeout.
    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date(timeIntervalSinceNow: timeout)
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

private let speakers = AudioDeviceInfo(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", isBuiltIn: true)
private let xm4Output = AudioDeviceInfo(id: 2, uid: "94-DB-56-E1-43-75:output", name: "WH-1000XM4", isBuiltIn: false)
private let hiresBuddy = AudioDeviceInfo(id: 3, uid: "HiResBuddy_UID", name: "HiRes Buddy", isBuiltIn: false)
private let xm4 = Headphones(id: "94-db-56-e1-43-75", name: "WH-1000XM4", isConnected: true, ldacSampleRates: 0x3C)

/// A controller wired to fakes: the headphones' output is default at start and vanishes during the stream.
@MainActor
private final class Harness {
    let directory: FakeDirectory
    let capture = FakeCapture()
    let link = FakeLink()
    let defaults: UserDefaults
    let recorder = SessionRecorder()
    var controller: SessionController!

    init(paired: [Headphones] = [xm4]) {
        directory = FakeDirectory([speakers, xm4Output, hiresBuddy], defaultOutput: xm4Output.id)
        let suite = "SessionControllerTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        controller = SessionController(
            defaults: defaults,
            listPaired: { paired },
            probe: { $0 },
            makeSession: { [directory, recorder] device in
                recorder.addresses.append(device.addressString.lowercased().replacingOccurrences(of: ":", with: "-"))
                directory.devices.removeAll { $0.uid == xm4Output.uid }   // takeover: the headphones' output goes
                let s = FakeSession()
                recorder.sessions.append(s)
                return s
            },
            makeCapture: { [capture] in capture },
            switcher: OutputDeviceSwitcher(directory: directory),
            isConnected: { [link] _ in link.next() },
            requestMicrophone: { $0(true) },   // synchronous: the tests drive the phases step by step
            timing: .init(reconnectPoll: 0.01, restoreRetry: 0.01, closeTimeout: 0.5))
    }
}

@MainActor
private final class SessionRecorder {
    var sessions: [FakeSession] = []
    var addresses: [String] = []
}

/// Answers isConnected from a script; the last value repeats.
@MainActor
private final class FakeLink {
    var connected: [Bool] = [true]
    func next() -> Bool { connected.count > 1 ? connected.removeFirst() : connected[0] }
}

private final class FakeDirectory: AudioDeviceDirectory {
    var devices: [AudioDeviceInfo]
    var defaultOutput: AudioDeviceID
    /// This many setDefaultOutput calls throw before they work again.
    var failingSets = 0

    init(_ devices: [AudioDeviceInfo], defaultOutput: AudioDeviceID) {
        self.devices = devices
        self.defaultOutput = defaultOutput
    }

    func outputDevices() -> [AudioDeviceInfo] { devices }
    func currentDefaultOutput() -> AudioDeviceID { defaultOutput }
    func setDefaultOutput(_ id: AudioDeviceID) throws {
        if failingSets > 0 {
            failingSets -= 1
            throw OutputDeviceError.coreAudio(-1)
        }
        defaultOutput = id
    }
}

private final class FakeCapture: PCMSource {
    private(set) var started = false
    private(set) var stopped = false
    func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void) { started = true }
    func stop() { stopped = true }
}

/// Moves only when told to (start stays in Idle); stop goes to Closed. Owns a socketpair as the transport.
private final class FakeSession: HBAVDTPSession {
    private let fds: [Int32]
    private var fakeState = HBSessionState.idle
    private(set) var startedBit: UInt8 = 0
    private(set) var stopCalled = false

    init() {
        var sig: [Int32] = [-1, -1], transport: [Int32] = [-1, -1]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &sig)
        socketpair(AF_UNIX, SOCK_DGRAM, 0, &transport)
        fds = [sig[1], transport[0], transport[1]]   // the signaling peer stays open: EOF would fail the session
        super.init(signaling: HBL2CAPChannel(socketFD: sig[0], name: "fake-signaling")!, transportProvider: { _ in })
    }

    deinit { fds.forEach { close($0) } }

    override var state: HBSessionState { fakeState }
    override var transportFD: Int32 { fakeState == .streaming || fakeState == .suspended ? fds[1] : -1 }

    override func start(withSampleRateBit sfBit: UInt8) {
        startedBit = sfBit
        move(to: .connecting)
    }

    override func stopAndRestoreSystemAudio() {
        stopCalled = true
        move(to: .closed)
    }

    func move(to state: HBSessionState, error: Error? = nil) {
        fakeState = state
        delegate?.session(self, didChange: state, error: error)
    }
}
