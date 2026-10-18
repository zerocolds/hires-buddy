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
/// output exists; the same sequence as `hiresbuddy-cli system`. When the headphones left on their own (the session
/// failed with HBErrorSinkDisconnected and the link is down) nothing pages them back: the wait is short and the
/// error stays on screen. Quitting never waits for that, and a second quit cuts any wait short.
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
        /// After the headphones left on their own (link down): nothing pages them back; only a quick return counts.
        var headphonesLeftTimeout: TimeInterval = 5
        /// The headphones' CoreAudio output appears a moment after the link is back.
        var restoreRetry: TimeInterval = 0.5
        var restoreTries = 10
        /// stop waits for SUSPEND and CLOSE answers, at most 1 s each.
        var closeTimeout: TimeInterval = 5
    }

    private enum Keys {
        static let address = "headphoneAddress"
        static let quality = "defaultQuality"
        /// LDAC sample-rate mask learned from a session, per address; 0 = the session found no LDAC.
        static func ldacRates(_ address: String) -> String { "ldacRates.\(address)" }
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
    /// The stream ended because the headphones went away (link down): shown as the error, not as "returning".
    @Published public private(set) var headphonesLeft = false
    @Published public private(set) var isInstallingDriver = false
    /// Why the last driver install failed; nil otherwise.
    @Published public private(set) var driverInstallError: String?

    /// The "HiRes Buddy" virtual device is present (as of the last `recheckDriver`).
    @Published public private(set) var driverInstalled = false

    /// The selected headphones are connected, not known to lack LDAC (unknown is fine: a session without LDAC
    /// fails fast with HBErrorNoLDAC), and the driver is installed.
    public var canEnable: Bool {
        guard let selected else { return false }
        return selected.isConnected && selected.ldacSampleRates != 0 && driverInstalled && !isReturningHeadphones
    }

    /// A stream exists or the headphones are still on their way back to macOS: quitting must wait.
    public var hasActiveSession: Bool { streamer != nil || isReturningHeadphones }

    private(set) var streamer: Streamer?
    /// The current stream's session: its discovered LDAC rates are cached once it streams.
    private var session: HBAVDTPSession?
    private let defaults: UserDefaults
    private let listPaired: @MainActor () -> [Headphones]
    private let makeSession: @MainActor (IOBluetoothDevice) -> HBAVDTPSession
    private let makeCapture: @MainActor () throws -> PCMSource
    private let switcher: OutputDeviceSwitcher
    private let isConnected: @MainActor (String) -> Bool
    private let requestMicrophone: @MainActor (@escaping @MainActor @Sendable (Bool) -> Void) -> Void
    private let installer: @MainActor () async throws -> Void
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
         makeSession: @escaping @MainActor (IOBluetoothDevice) -> HBAVDTPSession = {
             HBAVDTPSession(device: $0, helper: HBTransportHelperClient())
         },
         makeCapture: @escaping @MainActor () throws -> PCMSource = {
             try AudioCapture(sampleRate: LDACSampleRate.hz48000.rawValue)
         },
         switcher: OutputDeviceSwitcher = OutputDeviceSwitcher(persistingIn: .standard),
         isConnected: @escaping @MainActor (String) -> Bool = { IOBluetoothDevice(addressString: $0)?.isConnected() ?? false },
         requestMicrophone: @escaping @MainActor (@escaping @MainActor @Sendable (Bool) -> Void) -> Void = MicrophonePermission.request,
         installer: @escaping @MainActor () async throws -> Void = { try await DriverInstaller.install() },
         timing: Timing = Timing()) {
        self.defaults = defaults
        self.listPaired = listPaired
        self.makeSession = makeSession
        self.makeCapture = makeCapture
        self.switcher = switcher
        self.isConnected = isConnected
        self.requestMicrophone = requestMicrophone
        self.installer = installer
        self.timing = timing
        driverInstalled = switcher.deviceID(named: AudioCapture.deviceName) != nil
        quality = defaults.object(forKey: Keys.quality).flatMap { $0 as? Int }.flatMap(LDACQuality.init) ?? .sq
    }

    // MARK: - Launch

    /// At launch, with no stream: a crash can leave "HiRes Buddy" as the default output (nothing feeds it any more).
    /// Puts back the output remembered by the crashed run, else the fallback output.
    public func restoreStuckOutput() {
        guard streamer == nil, !isReturningHeadphones else { return }
        do {
            switch try switcher.restoreIfStuck() {
            case .restored(let name)?: log.info("launch: output was stuck on HiRes Buddy, restored to \(name, privacy: .public)")
            case .fallback(let name)?: log.info("launch: output was stuck on HiRes Buddy, previous one absent, on \(name, privacy: .public)")
            case .nothingToRestore?: log.error("launch: output stuck on HiRes Buddy and no other output exists")
            case nil: break
            }
        } catch {
            log.error("launch: cannot restore the default output: \(error)")
        }
    }

    // MARK: - Headphones

    /// Lists paired A2DP headphones with the LDAC rates cached from earlier sessions (unknown until the first one).
    /// Keeps the selection, else the saved address, else the first connected pair. Not while streaming.
    ///
    /// Never probes: opening the AVDTP signaling channel while macOS owns A2DP makes the sink drop the link.
    public func refreshHeadphones() {
        guard streamer == nil, !isReturningHeadphones else { return }
        let found = listPaired().map { h in
            Headphones(id: h.id, name: h.name, isConnected: h.isConnected, ldacSampleRates: cachedLDACRates(h.id))
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
        let session = makeSession(device)
        self.session = session
        let streamer = Streamer(session: session, sampleRate: .hz48000, quality: quality)
        streamer.onStats = { [weak self] in self?.stats = $0 }
        streamer.onStateChange = { [weak self] state, err in self?.sessionChanged(state, err) }
        self.streamer = streamer
        log.info("enable: \(target.name, privacy: .public) \(target.id, privacy: .public), \(String(describing: self.quality), privacy: .public), takeover \(self.takeover)")
        do { try streamer.start(source: capture) } catch {
            self.streamer = nil
            self.session = nil
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
    /// `terminate`. Immediately when nothing is streaming. Cuts the wait short — output restored now, terminate
    /// at once — when the headphones left on their own (nothing is paging them), or when quit is asked again while
    /// an earlier quit is still waiting.
    public func quit(_ terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        guard hasActiveSession else {
            if phase == .connecting { phase = .off }
            return terminate()
        }
        let again = !quitCompletions.isEmpty
        quitCompletions.append(terminate)
        if phase == .connecting || phase == .streaming { return disable() }
        if isReturningHeadphones && (headphonesLeft || again) {
            log.info("quit: not waiting for the headphones any longer")
            restoreOutput()
            finishReturn()
        }
    }

    // MARK: - Session end and the way back to macOS

    private func sessionChanged(_ state: HBSessionState, _ err: Error?) {
        switch state {
        case .streaming:
            if phase == .connecting { phase = .streaming }
            if let rates = session?.discoveredLDACRates, rates != 0 { rememberLDACRates(rates, for: address) }
        case .closed:
            log.info("session closed")
            if phase != .stopping { phase = .error("Наушники закрыли поток") }   // not asked for: say so
            sessionEnded(failed: false)
        case .failed:
            log.error("session failed: \(err.map { "\($0)" } ?? "?", privacy: .public)")
            if phase != .stopping { phase = .error(Self.describe(err)) }
            if Self.isNoLDAC(err) { rememberLDACRates(0, for: address) }
            let left = Self.isSinkDisconnected(err) && !isConnected(address)
            if left { log.info("the headphones left (link down): not waiting for a reconnect") }
            sessionEnded(failed: true, headphonesLeft: left)
        default:
            break
        }
    }

    /// Restores the output at once (usually onto the fallback: the headphones' output is gone during the stream),
    /// then waits for the restore hook's reconnect before restoring again.
    /// `headphonesLeft`: the link is already down and nothing pages it: a short wait for them to come back by
    /// themselves (already "seen disconnected").
    private func sessionEnded(failed: Bool, headphonesLeft left: Bool = false) {
        guard streamer != nil, !isReturningHeadphones else { return }
        stats = nil
        restoreOutput()
        isReturningHeadphones = true
        headphonesLeft = left
        let seconds = left ? timing.headphonesLeftTimeout
            : failed && !takeover ? timing.failedWithoutTakeoverTimeout : timing.reconnectTimeout
        let checks = Int((seconds / timing.reconnectPoll).rounded())
        if left && !quitCompletions.isEmpty { return finishReturn() }   // a quit is waiting: nothing to wait for
        waitForReconnect(sawDisconnect: left, checksLeft: checks, streamer: streamer)
    }

    /// The restore hook drops the link first, so "reconnected" means connected after having been seen disconnected.
    private func waitForReconnect(sawDisconnect: Bool, checksLeft: Int, streamer: Streamer?) {
        after(timing.reconnectPoll) { [self] in
            guard isReturningHeadphones, self.streamer === streamer else { return }   // cut short by quit
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
            waitForReconnect(sawDisconnect: sawDisconnect || !connected, checksLeft: checksLeft - 1, streamer: streamer)
        }
    }

    /// Retries while only the fallback is available or the restore throws, up to `restoreTries` attempts.
    private func restoreAfterReconnect(triesLeft: Int) {
        guard isReturningHeadphones else { return }   // cut short by quit
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
        session = nil
        stats = nil
        isReturningHeadphones = false
        headphonesLeft = false
        if phase == .stopping { phase = .off }
        if !quitCompletions.isEmpty {
            let completions = quitCompletions
            quitCompletions = []
            completions.forEach { $0() }
            return
        }
        refreshHeadphones()
    }

    // MARK: - LDAC capability cache

    private func cachedLDACRates(_ address: String) -> UInt8? {
        (defaults.object(forKey: Keys.ldacRates(address)) as? Int).flatMap { UInt8(exactly: $0) }
    }

    /// Caches what a session learned about the headphones' LDAC support and shows it in the list and selection.
    private func rememberLDACRates(_ rates: UInt8, for address: String) {
        guard !address.isEmpty, cachedLDACRates(address) != rates else { return }
        defaults.set(Int(rates), forKey: Keys.ldacRates(address))
        log.info("LDAC rates for \(address, privacy: .public): \(rates)")
        func update(_ h: Headphones) -> Headphones {
            h.id == address ? Headphones(id: h.id, name: h.name, isConnected: h.isConnected, ldacSampleRates: rates) : h
        }
        headphones = headphones.map(update)
        if let selected, selected.id == address { self.selected = update(selected) }
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
            do { try await installer() } catch {
                driverInstallError = "\(error)"
                isInstallingDriver = false   // nothing was installed: nothing to wait for
                return
            }
            // coreaudiod restarts and publishes the device a moment later
            for _ in 0..<10 where !driverInstalled {
                try? await Task.sleep(for: .seconds(1))
                recheckDriver()
            }
            isInstallingDriver = false
        }
    }

    // MARK: - Helpers

    static func isSinkDisconnected(_ err: Error?) -> Bool {
        guard let e = err as NSError? else { return false }
        return e.domain == HBErrorDomain && e.code == HBSessionError.errorSinkDisconnected.rawValue
    }

    static func isNoLDAC(_ err: Error?) -> Bool {
        guard let e = err as NSError? else { return false }
        return e.domain == HBErrorDomain && e.code == HBSessionError.errorNoLDAC.rawValue
    }

    static func describe(_ err: Error?) -> String {
        if let failure = err as? StreamFailure {
            switch failure {
            case .captureFailed(let e): return "Не удалось захватить звук: \(e)"
            case .sourceFailed(HBError.sampleRateChanged(let expected, let actual)):
                return "Частота дискретизации HiRes Buddy сменилась на \(Self.khz(actual)) кГц и не вернулась "
                    + "к \(Self.khz(expected)) кГц — поток остановлен"
            case .sourceFailed(let e): return "Захват звука прервался: \(e)"
            }
        }
        guard let e = err as NSError?, e.domain == HBErrorDomain else {
            return "Поток прервался" + (err.map { ": \($0.localizedDescription)" } ?? "")
        }
        let detail = " (код \(e.code): \(e.localizedDescription))"
        switch HBSessionError.Code(rawValue: e.code) {
        case .errorSinkRejected?: return "Наушники отклонили LDAC-поток"
        case .errorNoLDAC?: return "Наушники не поддерживают LDAC"
        case .errorSinkDisconnected?: return "Наушники отключились"
        case .errorChannelOpenFailed?: return "Не удалось подключиться к наушникам" + detail
        case .errorTransportFailed?: return "Не удалось открыть аудиоканал (hiresbuddy-transport)"
        case .errorTimeout?: return "Наушники не отвечают"
        case .errorPrivateAPIUnavailable?:
            return "Эта версия macOS не поддерживает нужный HiRes Buddy Bluetooth-интерфейс" + detail
        default: return "Ошибка сессии" + detail
        }
    }

    private static func khz(_ hz: Double) -> String {
        hz.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(hz / 1000)) : String(format: "%.1f", hz / 1000)
    }
}
