import CoreAudio

/// An output-capable CoreAudio device as the switcher sees it.
struct AudioDeviceInfo: Equatable {
    var id: AudioDeviceID
    /// Stable across reconnects (`kAudioDevicePropertyDeviceUID`); the object id is not.
    var uid: String
    var name: String
    var isBuiltIn: Bool
}

/// The HAL calls the switcher needs; a seam so the restore/fallback logic can be tested without real devices.
protocol AudioDeviceDirectory {
    /// Devices with output streams, in HAL order.
    func outputDevices() -> [AudioDeviceInfo]
    /// `kAudioObjectUnknown` if there is none.
    func currentDefaultOutput() -> AudioDeviceID
    func setDefaultOutput(_ id: AudioDeviceID) throws
}

struct CoreAudioDeviceDirectory: AudioDeviceDirectory {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    func outputDevices() -> [AudioDeviceInfo] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutputStreams(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddr = Self.address(kAudioDevicePropertyTransportType)
            _ = AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport)
            return AudioDeviceInfo(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "",
                                   isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    func currentDefaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &id)
        return status == noErr ? id : AudioDeviceID(kAudioObjectUnknown)
    }

    func setDefaultOutput(_ id: AudioDeviceID) throws {
        var id = id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(Self.system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr { throw OutputDeviceError.coreAudio(status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
