import CoreAudio
import Foundation

public enum OutputDeviceError: Error, Equatable {
    case coreAudio(OSStatus)
}

/// Switches the system default output device and puts it back afterwards (CoreAudio HAL).
public final class OutputDeviceSwitcher {
    private var previous: AudioDeviceID?

    public init() {}

    /// First device whose name equals `name`, nil if none.
    public func deviceID(named name: String) -> AudioDeviceID? {
        let matches = allDevices().filter { deviceName($0) == name }
        return matches.first { hasOutputStreams($0) } ?? matches.first
    }

    /// The current default output device; `kAudioObjectUnknown` if there is none.
    public func current() -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.defaultOutputAddress
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : AudioDeviceID(kAudioObjectUnknown)
    }

    /// Makes `id` the default output; the device that was default before the first call is remembered for `restore`.
    public func switchTo(_ id: AudioDeviceID) throws {
        if previous == nil { previous = current() }
        try setDefault(id)
    }

    /// Puts the remembered device back if it still exists; otherwise does nothing.
    public func restore() throws {
        guard let previous else { return }
        guard previous != kAudioObjectUnknown, allDevices().contains(previous) else {
            self.previous = nil
            return
        }
        try setDefault(previous)
        self.previous = nil
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func setDefault(_ id: AudioDeviceID) throws {
        var id = id
        var address = Self.defaultOutputAddress
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr { throw OutputDeviceError.coreAudio(status) }
    }

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
