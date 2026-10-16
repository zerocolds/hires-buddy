import AppKit
import BTStream
import Combine
import Foundation
import IOBluetooth
import LDACEncoder
import os

/// The menu bar app's model: headphone list and selection, the LDAC toggle, quality and stream stats.
///
/// Enabling makes "HiRes Buddy" the default output and streams what it captures to the selected headphones
/// (a new session and Streamer each time: they are single-use). Every way out — toggle off, session Failed/Closed,
/// quit — puts the previous output back at once, waits for the headphones to reconnect to macOS (the session's
/// restore hook drops and re-pages the link) and restores the output again, retrying while only the fallback
/// output exists; the same sequence as `hiresbuddy-cli system`.
@MainActor
public final class SessionController: ObservableObject {
    public enum Phase: Equatable { case off, connecting, streaming, stopping, error(String) }

    /// Test seams; the defaults are the real timings.
    struct Timing {
        var reconnectPoll: TimeInterval = 0.25
        /// After Closed, or Failed after a takeover: the restore hook needs the link to drop, then re-pages it.
        var reconnectTimeout: TimeInterval = 80
        /// After Failed without a takeover there is little to wait for.
        var failedWithoutTakeoverTimeout: TimeInterval = 5
        /// The headphones' CoreAudio output appears a moment after the link is back.
        var restoreRetry: TimeInterval = 0.5
        var restoreTries = 10
        /// stop waits for SUSPEND and CLOSE answers, at most 1 s each.
        var closeTimeout: TimeInterval = 5
    }

    private enum Keys {
        static let address = "headphoneAddress"
        static let quality = "defaultQuality"
    }

    @Published public private(set) var phase: Phase = .off
    @Published public var headphones: [Headphones] = []
    @Published public var selected: Headphones? {
        didSet { if let selected { defaults.set(selected.id, forKey: Keys.address) } }
    }
    @Published public var quality: LDACQuality {
        didSet {
            defaults.set(quality.rawValue, forKey: Keys.quality)
            streamer?.quality = quality
        }
    }
    @Published public private(set) var stats: StreamStats?
    /// From the end of a stream until the headphones are back with macOS and the output is restored.
    @Published public private(set) var isReturningHeadphones = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isInstallingDriver = false
    /// Why the last driver install failed; nil otherwise.
    @Published public private(set) var driverInstallError: String?

    /// The "HiRes Buddy" virtual device is present (as of the last `recheckDriver`).
    @Published public private(set) var driverInstalled = false

    /// The selected headphones are connected, not known to lack LDAC, and the driver is installed.
    public var canEnable: Bool {
        guard let selected else { return false }
        return selected.isConnected && selected.ldacSampleRates != 0 && driverInstalled && !isReturningHeadphones
    }

    /// A stream exists or the headphones are still on their way back to macOS: quitting must wait.
    public var hasActiveSession: Bool { streamer != nil || isReturningHeadphones }

    private(set) var streamer: Streamer?
    private let defaults: UserDefaults
    private let listPaired: @MainActor () -> [Headphones]
    private let probe: @MainActor (Headphones) async -> Headphones
    private let makeSession: @MainActor (IOBluetoothDevice) -> HBAVDTPSession
    private let makeCapture: @MainActor () throws -> PCMSource
    private let switcher: OutputDeviceSwitcher
    private let isConnected: @MainActor (String) -> Bool
    private let requestMicrophone: @MainActor (@escaping @MainActor @Sendable (Bool) -> Void) -> Void
    private let timing: Timing
    private let log = Logger(subsystem: "HiResBuddy", category: "app")
    /// Address of the headphones being streamed to; whether the session took the link over from macOS.
    private var address = ""
    private var takeover = false
    private var quitCompletions: [@MainActor () -> Void] = []

    public convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults,
         listPaired: @escaping @MainActor () -> [Headphones] = { HeadphoneDiscovery.pairedA2DPDevices() },
         probe: @escaping @MainActor (Headphones) async -> Headphones = { await HeadphoneDiscovery.probeLDAC($0) },
         makeSession: @escaping @MainActor (IOBluetoothDevice) -> HBAVDTPSession = {
             HBAVDTPSession(device: $0, helper: HBTransportHelperClient())
         },
         makeCapture: @escaping @MainActor () throws -> PCMSource = {
             try AudioCapture(sampleRate: LDACSampleRate.hz48000.rawValue)
         },
         switcher: OutputDeviceSwitcher = OutputDeviceSwitcher(),
         isConnected: @escaping @MainActor (String) -> Bool = { IOBluetoothDevice(addressString: $0)?.isConnected() ?? false },
         requestMicrophone: @escaping @MainActor (@escaping @MainActor @Sendable (Bool) -> Void) -> Void = MicrophonePermission.request,
         timing: Timing = Timing()) {
        self.defaults = defaults
        self.listPaired = listPaired
        self.probe = probe
        self.makeSession = makeSession
        self.makeCapture = makeCapture
        self.switcher = switcher
        self.isConnected = isConnected
        self.requestMicrophone = requestMicrophone
        self.timing = timing
        driverInstalled = switcher.deviceID(named: AudioCapture.deviceName) != nil
        quality = defaults.object(forKey: Keys.quality).flatMap { $0 as? Int }.flatMap(LDACQuality.init) ?? .sq
    }

    // MARK: - Headphones

    /// Lists paired A2DP headphones and probes the connected ones for LDAC (a known answer is kept while they stay
    /// connected). Keeps the selection, else the saved address, else the first connected pair. Not while streaming.
    public func refreshHeadphones() async {
        guard streamer == nil, !isReturningHeadphones, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var found = listPaired()
        for i in found.indices where found[i].isConnected {
            if let known = headphones.first(where: { $0.id == found[i].id && $0.isConnected }), known.ldacSampleRates != nil {
                found[i] = known
            } else {
                found[i] = await probe(found[i])
            }
        }
        headphones = found
        let wanted = selected?.id ?? defaults.string(forKey: Keys.address)
        selected = found.first { $0.id == wanted } ?? found.first { $0.isConnected } ?? found.first
    }

    // MARK: - Toggle

    public func setEnabled(_ on: Bool) {
        on ? enable() : disable()
    }

    private func enable() {
        guard canEnable, streamer == nil, let target = selected else { return }
        switch phase {
        case .off, .error: break
        default: return
        }
        phase = .connecting
        requestMicrophone { [weak self] granted in self?.microphoneAnswered(granted, target) }
    }

    private func microphoneAnswered(_ granted: Bool, _ target: Headphones) {
        guard phase == .connecting, streamer == nil else { return }   // switched off while the prompt was up
        guard granted else {
            return fail("Нет доступа к микрофону: разрешите HiRes Buddy в Системных настройках → "
                        + "Конфиденциальность и безопасность → Микрофон (иначе звук не захватывается)")
        }
        start(target)
    }

    private func start(_ target: Headphones) {
        let capture: PCMSource
        do { capture = try makeCapture() } catch {
            return fail("Устройство HiRes Buddy недоступно — переустановите драйвер (\(error))")
        }
        guard let device = IOBluetoothDevice(addressString: target.id) else { return fail("Неверный адрес \(target.id)") }
        guard let output = switcher.deviceID(named: AudioCapture.deviceName) else {
            return fail("Устройство HiRes Buddy пропало — переустановите драйвер")
        }
        do { try switcher.switchTo(output) } catch {
            return fail("Не удалось сделать HiRes Buddy выходом по умолчанию (\(error))")
        }
        address = target.id
        takeover = isConnected(target.id)
        // The driver applies the Mac's volume itself: the Streamer's gain stays 1.
        let streamer = Streamer(session: makeSession(device), sampleRate: .hz48000, quality: quality)
        streamer.onStats = { [weak self] in self?.stats = $0 }
        streamer.onStateChange = { [weak self] state, err in self?.sessionChanged(state, err) }
        self.streamer = streamer
        log.info("enable: \(target.name, privacy: .public) \(target.id, privacy: .public), \(String(describing: self.quality), privacy: .public), takeover \(self.takeover)")
        do { try streamer.start(source: capture) } catch {
            self.streamer = nil
            restoreOutput()
            fail("Не удалось запустить LDAC-кодер (\(error))")
        }
    }

    private func disable() {
        switch phase {
        case .connecting where streamer == nil:
            phase = .off   // the microphone prompt is still up; its answer is ignored
        case .connecting, .streaming:
            guard let streamer else { return }
            phase = .stopping
            log.info("disable")
            restoreOutput()
            streamer.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + timing.closeTimeout) { [weak self, weak streamer] in
                MainActor.assumeIsolated {
                    guard let self, let streamer, self.streamer === streamer, !self.isReturningHeadphones else { return }
                    self.log.error("no Closed within \(self.timing.closeTimeout) s")
                    self.restoreOutput()
                    self.finishReturn()
                }
            }
        case .error:
            if !isReturningHeadphones { phase = .off }
        case .off, .stopping:
            break
        }
    }

    // MARK: - Quit

    /// Stops the stream and waits until the headphones are back with macOS and the output is restored, then calls
    /// `terminate`. Immediately when nothing is streaming.
    public func quit(_ terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        guard hasActiveSession else {
            if phase == .connecting { phase = .off }
            return terminate()
        }
        quitCompletions.append(terminate)
        if phase == .connecting || phase == .streaming { disable() }
    }

    // MARK: - Session end and the way back to macOS

    private func sessionChanged(_ state: HBSessionState, _ err: Error?) {
        switch state {
        case .streaming:
            if phase == .connecting { phase = .streaming }
        case .closed:
            log.info("session closed")
            if phase != .stopping { phase = .error("Наушники закрыли поток") }   // not asked for: say so
            sessionEnded(failed: false)
        case .failed:
            log.error("session failed: \(err.map { "\($0)" } ?? "?", privacy: .public)")
            if phase != .stopping { phase = .error(Self.describe(err)) }
            sessionEnded(failed: true)
        default:
            break
        }
    }

    /// Restores the output at once (usually onto the fallback: the headphones' output is gone during the stream),
    /// then waits for the restore hook's reconnect before restoring again.
    private func sessionEnded(failed: Bool) {
        guard streamer != nil, !isReturningHeadphones else { return }
        stats = nil
        restoreOutput()
        isReturningHeadphones = true
        let seconds = failed && !takeover ? timing.failedWithoutTakeoverTimeout : timing.reconnectTimeout
        let checks = Int((seconds / timing.reconnectPoll).rounded())
        waitForReconnect(sawDisconnect: false, checksLeft: checks)
    }

    /// The restore hook drops the link first, so "reconnected" means connected after having been seen disconnected.
    private func waitForReconnect(sawDisconnect: Bool, checksLeft: Int) {
        after(timing.reconnectPoll) { [self] in
            let connected = isConnected(address)
            if sawDisconnect && connected {
                log.info("headphones reconnected")
                return restoreAfterReconnect(triesLeft: timing.restoreTries)
            }
            if checksLeft <= 0 {
                log.error("headphones did not reconnect in time")
                restoreOutput()
                return finishReturn()
            }
            waitForReconnect(sawDisconnect: sawDisconnect || !connected, checksLeft: checksLeft - 1)
        }
    }

    /// Retries while only the fallback is available or the restore throws, up to `restoreTries` attempts.
    private func restoreAfterReconnect(triesLeft: Int) {
        switch restoreOutput() {
        case .restored?, .nothingToRestore?:
            finishReturn()
        case .fallback?, nil:
            guard triesLeft > 1 else {
                log.error("previous output not restored after \(self.timing.restoreTries) tries")
                return finishReturn()
            }
            after(timing.restoreRetry) { [self] in restoreAfterReconnect(triesLeft: triesLeft - 1) }
        }
    }

    private func finishReturn() {
        streamer = nil   // kept until now: the session's restore hook runs on in the background
        stats = nil
        isReturningHeadphones = false
        if phase == .stopping { phase = .off }
        if !quitCompletions.isEmpty {
            let completions = quitCompletions
            quitCompletions = []
            completions.forEach { $0() }
            return
        }
        Task { await refreshHeadphones() }
    }

    @discardableResult
    private func restoreOutput() -> OutputDeviceSwitcher.RestoreResult? {
        do {
            let result = try switcher.restore()
            switch result {
            case .restored(let name): log.info("output restored to \(name, privacy: .public)")
            case .fallback(let name): log.info("previous output absent for now, output on \(name, privacy: .public)")
            case .nothingToRestore: break
            }
            return result
        } catch {
            log.error("cannot restore the default output: \(error)")
            return nil
        }
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        phase = .error(message)
    }

    private func after(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
    }

    // MARK: - Driver

    /// Looks for the "HiRes Buddy" device again (the panel calls this when it opens).
    public func recheckDriver() {
        let present = switcher.deviceID(named: AudioCapture.deviceName) != nil
        if present != driverInstalled { driverInstalled = present }
    }

    /// Installs the bundled driver (administrator password prompt), then re-checks for the device.
    public func installDriver() {
        guard !isInstallingDriver else { return }
        isInstallingDriver = true
        driverInstallError = nil
        Task {
            do { try await DriverInstaller.install() } catch { driverInstallError = "\(error)" }
            // coreaudiod restarts and publishes the device a moment later
            for _ in 0..<10 where !driverInstalled {
                try? await Task.sleep(for: .seconds(1))
                recheckDriver()
            }
            isInstallingDriver = false
        }
    }

    // MARK: - Helpers

    static func describe(_ err: Error?) -> String {
        guard let e = err as NSError?, e.domain == HBErrorDomain else {
            return "Поток прервался" + (err.map { ": \($0.localizedDescription)" } ?? "")
        }
        switch HBSessionError.Code(rawValue: e.code) {
        case .errorSinkRejected?: return "Наушники отклонили LDAC-поток"
        case .errorNoLDAC?: return "Наушники не поддерживают LDAC 48 кГц"
        case .errorSinkDisconnected?: return "Наушники отключились"
        case .errorChannelOpenFailed?: return "Не удалось подключиться к наушникам"
        case .errorTransportFailed?: return "Не удалось открыть аудиоканал (hiresbuddy-transport)"
        case .errorTimeout?: return "Наушники не отвечают"
        default: return "Ошибка сессии (\(e.code))"
        }
    }
}
