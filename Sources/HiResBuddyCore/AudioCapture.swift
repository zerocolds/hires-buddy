import CoreAudio
import Foundation
import os

/// Reads what the system plays into the "HiRes Buddy" virtual device: the driver mirrors its output to its input,
/// and an IOProc on the input side hands the interleaved stereo Float32 blocks to the sink as the HAL delivers them.
///
/// Volume: the driver applies its own volume control (what the Mac volume keys set, dB taper, mute included) to the
/// mirrored audio, so captured PCM is already at the user's volume — keep the Streamer's gain at 1.0, or the volume
/// is applied twice. `deviceVolume`/`onVolumeChange` are for display only.
///
/// Reading the input side needs Microphone permission for the responsible process (NSMicrophoneUsageDescription);
/// without it the HAL delivers silence, not an error.
///
/// Sample rate: the device runs at all of the driver's rates (44.1–96 kHz, stage 2 needs them), so anything — Audio
/// MIDI Setup, another app — can change it under a running stream. While capturing, a listener on the nominal rate
/// forces it back to the configured one; if that fails, `lastError` is set and the `onFailure` handler is called.
public final class AudioCapture: PCMSource {
    public static let deviceName = "HiRes Buddy"

    private let device: AudioDeviceID
    private let sampleRate: Float64
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var failureHandler: (@MainActor (any Error) -> Void)?
    private var ioProcID: AudioDeviceIOProcID?
    private var sinkBox: Unmanaged<SinkBox>?
    private var volumeListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let log = Logger(subsystem: "HiResBuddy", category: "capture")

    /// Why the last `start` delivered nothing (`PCMSource.start` cannot throw); nil after a successful start.
    public private(set) var lastError: HBError?

    public var startError: (any Error)? { lastError }

    public func onFailure(_ handler: @escaping @MainActor (any Error) -> Void) { failureHandler = handler }

    private static var rateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Finds the device and sets its nominal sample rate.
    public init(deviceName: String = AudioCapture.deviceName, sampleRate: Int) throws {
        guard let id = OutputDeviceSwitcher(directory: CoreAudioDeviceDirectory()).deviceID(named: deviceName) else { throw HBError.deviceNotInstalled }
        device = id
        self.sampleRate = Float64(sampleRate)
        try Self.requireStereoFloatInput(id)
        let status = Self.setNominalRate(id, Float64(sampleRate))
        if status != noErr { throw HBError.coreAudio(status) }
    }

    private static func setNominalRate(_ id: AudioDeviceID, _ rate: Float64) -> OSStatus {
        var rate = rate
        var address = rateAddress
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
    }

    private static func nominalRate(_ id: AudioDeviceID) -> Float64? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = rateAddress
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    /// The rate guard's decision: nil if the rate is (or was put back to) `expected`, else the error to report.
    static func enforceRate(expected: Float64, read: () -> Float64?, write: (Float64) -> OSStatus) -> HBError? {
        guard let actual = read(), actual != expected else { return nil }
        let status = write(expected)
        if status == noErr, read() == expected { return nil }
        return .sampleRateChanged(expected: expected, actual: actual)
    }

    /// Main queue: the device's nominal rate changed.
    private func rateChanged() {
        guard ioProcID != nil else { return }
        let id = device
        let actual = Self.nominalRate(id)
        guard let actual, actual != sampleRate else { return }
        log.error("sample rate changed to \(actual) Hz under the stream: setting \(self.sampleRate) Hz back")
        guard let error = Self.enforceRate(expected: sampleRate, read: { Self.nominalRate(id) },
                                           write: { Self.setNominalRate(id, $0) }) else { return }
        log.error("cannot set the sample rate back: \(String(describing: error), privacy: .public)")
        lastError = error
        if let failureHandler { MainActor.assumeIsolated { failureHandler(error) } }
    }

    deinit {
        stop()
        for (address, block) in volumeListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
    }

    /// `sink` is called on the HAL's real-time IO thread; the buffer is only valid during the call.
    public func start(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void) {
        guard ioProcID == nil else { return }
        let id = device
        // the rate may have moved since init
        if let error = Self.enforceRate(expected: sampleRate, read: { Self.nominalRate(id) },
                                        write: { Self.setNominalRate(id, $0) }) {
            lastError = error
            log.error("sample rate: \(String(describing: error), privacy: .public)")
            return
        }
        let box = Unmanaged.passRetained(SinkBox(sink))
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(device, captureIOProc, box.toOpaque(), &procID)
        guard status == noErr, let procID else {
            box.release()
            fail("AudioDeviceCreateIOProcID", status)
            return
        }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            box.release()
            fail("AudioDeviceStart", status)
            return
        }
        ioProcID = procID
        sinkBox = box
        lastError = nil
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rateChanged() }
        var address = Self.rateAddress
        if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, listener) == noErr {
            rateListener = listener
        } else {
            log.error("cannot watch the sample rate")
        }
    }

    private func fail(_ call: String, _ status: OSStatus) {
        lastError = .coreAudio(status)
        log.error("\(call, privacy: .public) failed: \(status)")
    }

    /// Returns once the IOProc has stopped; the sink is not called afterwards.
    public func stop() {
        if let listener = rateListener {
            var address = Self.rateAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, listener)
            rateListener = nil
        }
        guard let procID = ioProcID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        ioProcID = nil
        sinkBox?.release()
        sinkBox = nil
    }

    /// The device's output volume scalar (0…1, what the Mac volume keys set); 1.0 if it has no volume control.
    /// Already applied to the captured PCM by the driver.
    public var deviceVolume: Float {
        guard var address = volumeAddress() else { return 1 }
        var volume: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return 1 }
        return volume
    }

    /// Calls `f` with the new `deviceVolume` on the main queue whenever the volume changes.
    public func onVolumeChange(_ f: @escaping (Float) -> Void) {
        guard var address = volumeAddress() else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            f(self.deviceVolume)
        }
        guard AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr else { return }
        volumeListeners.append((address, block))
    }

    /// Master element if the device has one, else channel 1.
    private func volumeAddress() -> AudioObjectPropertyAddress? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            if AudioObjectHasProperty(device, &address) { return address }
        }
        return nil
    }

    private static func requireStereoFloatInput(_ id: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var stream = AudioStreamID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioStreamID>.size)   // the first input stream is enough
        var status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &stream)
        guard status == noErr, size > 0 else { throw HBError.unsupportedFormat }
        address.mSelector = kAudioStreamPropertyVirtualFormat
        address.mScope = kAudioObjectPropertyScopeGlobal
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format)
        if status != noErr { throw HBError.coreAudio(status) }
        let flags = format.mFormatFlags
        guard format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame == 2, format.mBitsPerChannel == 32,
              flags & kAudioFormatFlagIsFloat != 0, flags & kAudioFormatFlagIsNonInterleaved == 0
        else { throw HBError.unsupportedFormat }
    }
}

private final class SinkBox {
    let sink: (UnsafeBufferPointer<Float>) -> Void
    init(_ sink: @escaping (UnsafeBufferPointer<Float>) -> Void) { self.sink = sink }
}

/// Real-time thread: no allocation, no locks — hand the input buffer straight to the sink.
private func captureIOProc(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                           _ input: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>,
                           _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: UnsafePointer<AudioTimeStamp>,
                           _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context, input.pointee.mNumberBuffers > 0 else { return noErr }
    let buffer = input.pointee.mBuffers   // stereo interleaved: one buffer
    guard let data = buffer.mData else { return noErr }
    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    let pcm = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
    Unmanaged<SinkBox>.fromOpaque(context)._withUnsafeGuaranteedRef { $0.sink(pcm) }   // no retain/release
    return noErr
}
