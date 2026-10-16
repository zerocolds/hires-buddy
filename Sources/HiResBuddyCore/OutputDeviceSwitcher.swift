import CoreAudio
import Foundation
import os

public enum OutputDeviceError: Error, Equatable {
    case coreAudio(OSStatus)
}

/// Switches the system default output device and puts it back afterwards (CoreAudio HAL).
///
/// The previous device is remembered by UID, not object id: Bluetooth headphones disappear from CoreAudio while
/// the stream owns them and come back as a new object. If the previous device is absent at `restore`, a fallback
/// output (built-in first) is made default and the previous one stays remembered, so a later `restore` — once the
/// headphones are back — still puts the real one back. `restore` never overrides a choice the user made meanwhile:
/// it only acts while the default output is still HiRes Buddy (or the fallback it set itself).
///
/// With `persistingIn:` the remembered device also goes to UserDefaults (`previousOutputUID`/`previousOutputName`),
/// so that a relaunch after a crash can still put it back (`restoreIfStuck`).
public final class OutputDeviceSwitcher {
    public enum RestoreResult: Equatable {
        /// The remembered device is default again (its name); nothing is remembered any more.
        case restored(String)
        /// The remembered device is absent; this device (its name) was made default instead.
        case fallback(String)
        /// Nothing remembered, no usable output exists, or the user picked another output meanwhile.
        case nothingToRestore
    }

    public enum Keys {
        public static let previousUID = "previousOutputUID"
        public static let previousName = "previousOutputName"
    }

    private struct Remembered {
        var uid: String
        var name: String
    }

    private let directory: AudioDeviceDirectory
    private let defaults: UserDefaults?
    private var previous: Remembered? {
        didSet {
            guard let defaults else { return }
            if let previous {
                defaults.set(previous.uid, forKey: Keys.previousUID)
                defaults.set(previous.name, forKey: Keys.previousName)
            } else {
                defaults.removeObject(forKey: Keys.previousUID)
                defaults.removeObject(forKey: Keys.previousName)
            }
        }
    }
    /// UID of the fallback output `restore` made default (it may be replaced by the remembered device later).
    private var fellBackTo: String?
    private let log = Logger(subsystem: "HiResBuddy", category: "output")

    /// Remembers in memory only.
    public convenience init() { self.init(directory: CoreAudioDeviceDirectory()) }

    /// Also persists the remembered device in `defaults` and picks up one left there by an earlier run.
    public convenience init(persistingIn defaults: UserDefaults) {
        self.init(directory: CoreAudioDeviceDirectory(), defaults: defaults)
    }

    init(directory: AudioDeviceDirectory, defaults: UserDefaults? = nil) {
        self.directory = directory
        self.defaults = defaults
        if let defaults, let uid = defaults.string(forKey: Keys.previousUID) {
            previous = Remembered(uid: uid, name: defaults.string(forKey: Keys.previousName) ?? uid)
        }
    }

    /// First output device whose name equals `name`, nil if none.
    public func deviceID(named name: String) -> AudioDeviceID? {
        directory.outputDevices().first { $0.name == name }?.id
    }

    /// The current default output device; `kAudioObjectUnknown` if there is none.
    public func current() -> AudioDeviceID { directory.currentDefaultOutput() }

    /// Makes `id` the default output, remembering the current default for `restore` — unless that is HiRes Buddy
    /// itself (left over from a crash) or the fallback `restore` set: then the device remembered before stays, or
    /// the fallback output is remembered if there is none.
    public func switchTo(_ id: AudioDeviceID) throws {
        let devices = directory.outputDevices()
        let cur = devices.first { $0.id == current() }
        if let cur, cur.name != AudioCapture.deviceName, cur.uid != fellBackTo {
            previous = Remembered(uid: cur.uid, name: cur.name)
        } else if previous == nil, let fb = Self.fallback(in: devices) {
            previous = Remembered(uid: fb.uid, name: fb.name)
        }
        fellBackTo = nil
        try directory.setDefaultOutput(id)
    }

    /// Puts the remembered device back, or a fallback output while it is absent (see the type's comment).
    @discardableResult
    public func restore() throws -> RestoreResult {
        guard let previous else { return .nothingToRestore }
        let devices = directory.outputDevices()
        if let cur = devices.first(where: { $0.id == current() }), cur.name != AudioCapture.deviceName,
           cur.uid != fellBackTo {
            // Someone chose an output meanwhile (or macOS put the headphones back on its own): leave it.
            if cur.uid != previous.uid {
                log.info("default output changed to \(cur.name, privacy: .public) meanwhile: not restoring \(previous.name, privacy: .public)")
            }
            self.previous = nil
            fellBackTo = nil
            return cur.uid == previous.uid ? .restored(cur.name) : .nothingToRestore
        }
        if let info = devices.first(where: { $0.uid == previous.uid }) {
            try directory.setDefaultOutput(info.id)
            self.previous = nil
            fellBackTo = nil
            return .restored(info.name)
        }
        guard let fb = Self.fallback(in: devices) else { return .nothingToRestore }
        try directory.setDefaultOutput(fb.id)
        fellBackTo = fb.uid
        log.info("previous output \(previous.name, privacy: .public) absent, fell back to \(fb.name, privacy: .public)")
        return .fallback(fb.name)
    }

    /// For app launch, with no stream running: if the default output is HiRes Buddy (a crash left it there), puts
    /// the remembered device back (persisted by an earlier run), else the fallback output. nil when the output is
    /// not stuck — a remembered device is then stale and forgotten.
    public func restoreIfStuck() throws -> RestoreResult? {
        let devices = directory.outputDevices()
        guard let cur = devices.first(where: { $0.id == current() }), cur.name == AudioCapture.deviceName else {
            if previous != nil { previous = nil }
            return nil
        }
        if previous == nil, let fb = Self.fallback(in: devices) {
            previous = Remembered(uid: fb.uid, name: fb.name)
        }
        return try restore()
    }

    /// Built-in output first, else any output that is not HiRes Buddy.
    private static func fallback(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        let real = devices.filter { $0.name != AudioCapture.deviceName }
        return real.first { $0.isBuiltIn } ?? real.first
    }
}
