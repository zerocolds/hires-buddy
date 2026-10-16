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
/// headphones are back — still puts the real one back.
public final class OutputDeviceSwitcher {
    public enum RestoreResult: Equatable {
        /// The remembered device is default again (its name); nothing is remembered any more.
        case restored(String)
        /// The remembered device is absent; this device (its name) was made default instead.
        case fallback(String)
        /// Nothing remembered, or no usable output exists.
        case nothingToRestore
    }

    private struct Remembered {
        var uid: String
        var name: String
    }

    private let directory: AudioDeviceDirectory
    private var previous: Remembered?
    private let log = Logger(subsystem: "HiResBuddy", category: "output")

    public convenience init() { self.init(directory: CoreAudioDeviceDirectory()) }

    init(directory: AudioDeviceDirectory) { self.directory = directory }

    /// First output device whose name equals `name`, nil if none.
    public func deviceID(named name: String) -> AudioDeviceID? {
        directory.outputDevices().first { $0.name == name }?.id
    }

    /// The current default output device; `kAudioObjectUnknown` if there is none.
    public func current() -> AudioDeviceID { directory.currentDefaultOutput() }

    /// Makes `id` the default output. The device that was default before the first call is remembered for
    /// `restore` — unless that was HiRes Buddy itself (left over from a crash): then the fallback output is.
    public func switchTo(_ id: AudioDeviceID) throws {
        if previous == nil {
            let devices = directory.outputDevices()
            let cur = current()
            if let info = devices.first(where: { $0.id == cur }), info.name != AudioCapture.deviceName {
                previous = Remembered(uid: info.uid, name: info.name)
            } else if let fb = Self.fallback(in: devices) {
                previous = Remembered(uid: fb.uid, name: fb.name)
            }
        }
        try directory.setDefaultOutput(id)
    }

    /// Puts the remembered device back, or a fallback output while it is absent (see the type's comment).
    @discardableResult
    public func restore() throws -> RestoreResult {
        guard let previous else { return .nothingToRestore }
        let devices = directory.outputDevices()
        if let info = devices.first(where: { $0.uid == previous.uid }) {
            try directory.setDefaultOutput(info.id)
            self.previous = nil
            return .restored(info.name)
        }
        guard let fb = Self.fallback(in: devices) else { return .nothingToRestore }
        try directory.setDefaultOutput(fb.id)
        log.info("previous output \(previous.name, privacy: .public) absent, fell back to \(fb.name, privacy: .public)")
        return .fallback(fb.name)
    }

    /// Built-in output first, else any output that is not HiRes Buddy.
    private static func fallback(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        let real = devices.filter { $0.name != AudioCapture.deviceName }
        return real.first { $0.isBuiltIn } ?? real.first
    }
}
