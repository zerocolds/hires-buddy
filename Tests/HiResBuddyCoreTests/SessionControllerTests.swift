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
        h.controller.refreshHeadphones()
        XCTAssertNil(h.controller.selected)
        XCTAssertFalse(h.controller.canEnable)
        h.controller.setEnabled(true)
        XCTAssertEqual(h.controller.phase, .off)
        XCTAssertTrue(h.recorder.sessions.isEmpty)
        XCTAssertEqual(h.directory.defaultOutput, xm4Output.id, "the output is left alone")
    }

    func testEnableSwitchesOutputAndStartsStream() async {
        let h = Harness()
        h.controller.refreshHeadphones()
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
        h.controller.refreshHeadphones()
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
        h.controller.refreshHeadphones()
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
        h.controller.refreshHeadphones()
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
        h.controller.refreshHeadphones()
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
        h.controller.refreshHeadphones()
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
        h.controller.refreshHeadphones()
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

    // MARK: - Final-review fixes

    func testCaptureThatFailsToStartShowsAnErrorInsteadOfStreaming() async {
        let h = Harness()
        h.controller.refreshHeadphones()
        h.capture.startError = HBError.coreAudio(-50)
        h.link.connected = [false, true]
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        guard case .error(let message) = h.controller.phase else { return XCTFail("phase \(h.controller.phase)") }
        XCTAssertTrue(message.hasPrefix("Не удалось захватить звук: "), message)
        XCTAssertTrue(h.recorder.sessions[0].stopCalled, "the headphones go back to macOS")
        XCTAssertNotEqual(h.directory.defaultOutput, hiresBuddy.id)
        h.directory.devices.append(xm4Output)
        await spin(until: { !h.controller.isReturningHeadphones })
    }

    func testSampleRateLostMidStreamShowsAnError() async {
        let h = Harness()
        h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        XCTAssertEqual(h.controller.phase, .streaming)
        h.link.connected = [false, true]
        h.capture.fail(HBError.sampleRateChanged(expected: 48000, actual: 96000))
        guard case .error(let message) = h.controller.phase else { return XCTFail("phase \(h.controller.phase)") }
        XCTAssertTrue(message.contains("частота") || message.contains("Частота"), message)
        XCTAssertTrue(h.recorder.sessions[0].stopCalled)
        h.directory.devices.append(xm4Output)
        await spin(until: { !h.controller.isReturningHeadphones })
    }

    func testHeadphonesThatLeftEndTheWaitQuicklyWithoutPaging() async {
        var timing = Harness.fastTiming
        timing.headphonesLeftTimeout = 0.3
        timing.reconnectTimeout = 30
        let h = Harness(timing: timing)
        h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        h.link.connected = [false]                     // the link is gone and stays gone

        let failedAt = Date()
        h.recorder.sessions[0].move(to: .failed, error: HBSessionError(.errorSinkDisconnected))
        XCTAssertEqual(h.controller.phase, .error("Наушники отключились"))
        XCTAssertTrue(h.controller.headphonesLeft, "the panel shows the error, not «Возвращаю…»")
        XCTAssertFalse(h.recorder.sessions[0].stopCalled, "nothing drops or pages the link")
        XCTAssertEqual(h.directory.defaultOutput, speakers.id, "output restored at once")
        await spin(until: { !h.controller.isReturningHeadphones })
        XCTAssertFalse(h.controller.isReturningHeadphones)
        XCTAssertLessThan(Date().timeIntervalSince(failedAt), 2, "the short wait, not the 30 s one")
        XCTAssertEqual(h.controller.phase, .error("Наушники отключились"))
        XCTAssertFalse(h.controller.headphonesLeft)
    }

    func testQuitAfterTheHeadphonesLeftIsImmediate() async {
        let h = Harness()                              // default 5 s short wait
        h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        h.link.connected = [false]
        h.recorder.sessions[0].move(to: .failed, error: HBSessionError(.errorSinkDisconnected))
        XCTAssertTrue(h.controller.isReturningHeadphones)

        var terminated = false
        h.controller.quit { terminated = true }
        XCTAssertTrue(terminated, "no wait for headphones that left on their own")
        XCTAssertFalse(h.controller.isReturningHeadphones)
        XCTAssertFalse(h.recorder.sessions[0].stopCalled)
    }

    func testSecondQuitCutsTheWaitShort() async {
        let h = Harness()
        h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].move(to: .streaming)
        h.link.connected = [true]                      // never seen dropping: the wait would run its 80 s
        var terminated = 0
        h.controller.quit { terminated += 1 }
        XCTAssertEqual(terminated, 0)
        XCTAssertTrue(h.controller.isReturningHeadphones)
        h.controller.quit { terminated += 1 }
        XCTAssertEqual(terminated, 2, "both quit requests complete at once")
        XCTAssertFalse(h.controller.isReturningHeadphones)
        XCTAssertNotEqual(h.directory.defaultOutput, hiresBuddy.id)
    }

    // MARK: - No probing; LDAC support learned from sessions

    func testRefreshDoesNotOpenAnyChannel() async {
        var opened: [UInt16] = []
        let real = HeadphoneDiscovery.channelOpener
        HeadphoneDiscovery.channelOpener = { _, psm, done in opened.append(psm); done(nil, -1) }
        defer { HeadphoneDiscovery.channelOpener = real }
        let h = Harness()
        h.controller.refreshHeadphones()
        h.controller.refreshHeadphones()            // panel opened again, «Обновить список»
        await spin(until: { !opened.isEmpty }, timeout: 0.3)
        XCTAssertEqual(opened, [], "no L2CAP channel is opened to connected headphones on refresh")
        XCTAssertTrue(h.recorder.sessions.isEmpty)
        XCTAssertEqual(h.controller.headphones.map(\.id), [xm4.id])
        XCTAssertNil(h.controller.selected?.ldacSampleRates, "unknown until a session streams")
    }

    func testUnknownLDACDeviceCanBeEnabled() {
        let h = Harness()
        h.controller.refreshHeadphones()
        XCTAssertNil(h.controller.selected?.ldacSampleRates)
        XCTAssertTrue(h.controller.canEnable, "unknown LDAC support does not block the toggle")
        h.controller.setEnabled(true)
        XCTAssertEqual(h.controller.phase, .connecting)
        XCTAssertEqual(h.recorder.sessions.count, 1)
        h.controller.setEnabled(false)
    }

    func testLDACRatesAreCachedAfterStreaming() async {
        let h = Harness()
        h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        h.recorder.sessions[0].rates = 0x3C
        h.recorder.sessions[0].move(to: .streaming)
        XCTAssertEqual(h.defaults.object(forKey: "ldacRates.\(xm4.id)") as? Int, 0x3C)
        XCTAssertEqual(h.controller.selected?.ldacSampleRates, 0x3C)
        XCTAssertEqual(h.controller.headphones.first?.ldacSampleRates, 0x3C)

        h.link.connected = [false, true]
        h.controller.setEnabled(false)
        h.directory.devices.append(xm4Output)
        await spin(until: { h.controller.phase == .off })
        let relaunched = h.makeController()
        relaunched.refreshHeadphones()
        XCTAssertEqual(relaunched.headphones.first?.ldacSampleRates, 0x3C, "merged from the cache on refresh")
        XCTAssertTrue(relaunched.canEnable)
    }

    func testNoLDACDeviceIsCachedAsZeroAndDisabled() async {
        let h = Harness()
        h.controller.refreshHeadphones()
        XCTAssertTrue(h.controller.canEnable)
        h.controller.setEnabled(true)
        h.link.connected = [false, true]
        h.recorder.sessions[0].move(to: .failed, error: HBSessionError(.errorNoLDAC))
        XCTAssertEqual(h.controller.phase, .error("Наушники не поддерживают LDAC"))
        XCTAssertEqual(h.defaults.object(forKey: "ldacRates.\(xm4.id)") as? Int, 0)
        XCTAssertEqual(h.controller.selected?.ldacSampleRates, 0)
        h.directory.devices.append(xm4Output)
        await spin(until: { !h.controller.isReturningHeadphones })
        XCTAssertFalse(h.controller.isReturningHeadphones)

        h.controller.refreshHeadphones()
        XCTAssertEqual(h.controller.selected?.ldacSampleRates, 0, "stays known after a refresh")
        XCTAssertFalse(h.controller.canEnable)
        h.controller.setEnabled(true)
        XCTAssertEqual(h.recorder.sessions.count, 1, "no new session for headphones without LDAC")
    }

    func testDriverInstallFailureStopsAtOnce() async {
        let h = Harness(installer: { throw DriverInstaller.Failure.failed("cancelled") })
        h.controller.installDriver()
        await spin(until: { !h.controller.isInstallingDriver }, timeout: 0.5)
        XCTAssertFalse(h.controller.isInstallingDriver, "no 10 s of polling after a failed install")
        XCTAssertNotNil(h.controller.driverInstallError)
    }

    func testLaunchRestoresAnOutputLeftOnHiResBuddy() {
        let h = Harness()
        h.defaults.set(xm4Output.uid, forKey: OutputDeviceSwitcher.Keys.previousUID)   // written by the crashed run
        h.defaults.set(xm4Output.name, forKey: OutputDeviceSwitcher.Keys.previousName)
        h.directory.defaultOutput = hiresBuddy.id
        let relaunched = h.makeController()
        relaunched.restoreStuckOutput()
        XCTAssertEqual(h.directory.defaultOutput, xm4Output.id)
        XCTAssertNil(h.defaults.string(forKey: OutputDeviceSwitcher.Keys.previousUID))
    }

    func testEnablePersistsThePreviousOutput() async {
        let h = Harness()
        h.controller.refreshHeadphones()
        h.controller.setEnabled(true)
        XCTAssertEqual(h.defaults.string(forKey: OutputDeviceSwitcher.Keys.previousUID), xm4Output.uid)
        h.controller.setEnabled(false)
    }

    func testDescribeIncludesTheCodeForOpenFailures() {
        let open = NSError(domain: HBErrorDomain, code: HBSessionError.errorChannelOpenFailed.rawValue,
                           userInfo: [NSLocalizedDescriptionKey: "signaling channel open failed after 10 attempts"])
        let text = SessionController.describe(open)
        XCTAssertTrue(text.contains("код 4") && text.contains("after 10 attempts"), text)
        let api = NSError(domain: HBErrorDomain, code: HBSessionError.errorPrivateAPIUnavailable.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "private Bluetooth API unavailable"])
        XCTAssertTrue(SessionController.describe(api).contains("код 7"), SessionController.describe(api))
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
/// As `pairedA2DPDevices` lists them: LDAC support unknown.
private let xm4 = Headphones(id: "94-db-56-e1-43-75", name: "WH-1000XM4", isConnected: true, ldacSampleRates: nil)

/// A controller wired to fakes: the headphones' output is default at start and vanishes during the stream.
@MainActor
private final class Harness {
    let directory: FakeDirectory
    let capture = FakeCapture()
    let link = FakeLink()
    let defaults: UserDefaults
    let recorder = SessionRecorder()
    var controller: SessionController!
    private let paired: [Headphones]
    private let installer: @MainActor () async throws -> Void
    private let timing: SessionController.Timing

    static let fastTiming = SessionController.Timing(reconnectPoll: 0.01, restoreRetry: 0.01, closeTimeout: 0.5)

    init(paired: [Headphones] = [xm4],
         installer: @escaping @MainActor () async throws -> Void = {}, timing: SessionController.Timing = fastTiming) {
        directory = FakeDirectory([speakers, xm4Output, hiresBuddy], defaultOutput: xm4Output.id)
        let suite = "SessionControllerTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        self.paired = paired
        self.installer = installer
        self.timing = timing
        controller = makeController()
    }

    /// A controller over the same fakes and defaults (e.g. a relaunch).
    func makeController() -> SessionController {
        SessionController(
            defaults: defaults,
            listPaired: { [paired] in paired },
            makeSession: { [directory, recorder] device in
                recorder.addresses.append(device.addressString.lowercased().replacingOccurrences(of: ":", with: "-"))
                directory.devices.removeAll { $0.uid == xm4Output.uid }   // takeover: the headphones' output goes
                let s = FakeSession()
                recorder.sessions.append(s)
                return s
            },
            makeCapture: { [capture] in capture },
            switcher: OutputDeviceSwitcher(directory: directory, defaults: defaults),
            isConnected: { [link] _ in link.next() },
            requestMicrophone: { $0(true) },   // synchronous: the tests drive the phases step by step
            installer: installer,
            timing: timing)
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
    var startError: (any Error)?
    private var failureHandler: (@MainActor (any Error) -> Void)?
    func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void) { started = true }
    func stop() { stopped = true }
    func onFailure(_ handler: @escaping @MainActor (any Error) -> Void) { failureHandler = handler }
    @MainActor func fail(_ error: Error) { failureHandler?(error) }
}

/// Moves only when told to (start stays in Idle); stop goes to Closed. Owns a socketpair as the transport.
private final class FakeSession: HBAVDTPSession {
    private let fds: [Int32]
    private var fakeState = HBSessionState.idle
    private(set) var startedBit: UInt8 = 0
    private(set) var stopCalled = false
    var rates: UInt8 = 0

    init() {
        var sig: [Int32] = [-1, -1], transport: [Int32] = [-1, -1]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &sig)
        socketpair(AF_UNIX, SOCK_DGRAM, 0, &transport)
        fds = [sig[1], transport[0], transport[1]]   // the signaling peer stays open: EOF would fail the session
        super.init(signaling: HBL2CAPChannel(socketFD: sig[0], name: "fake-signaling")!, transportProvider: { _ in })
    }

    deinit { fds.forEach { close($0) } }

    override var state: HBSessionState { fakeState }
    override var discoveredLDACRates: UInt8 { rates }
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
