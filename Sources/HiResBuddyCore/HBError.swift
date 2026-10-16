import CoreAudio

/// Errors of the HiRes Buddy core (the Bluetooth session's errors are `HBSessionError` in BTStream).
public enum HBError: Error, Equatable {
    /// The "HiRes Buddy" virtual audio device is not present (driver not installed or coreaudiod not restarted).
    case deviceNotInstalled
    /// The device's input stream is not interleaved stereo Float32.
    case unsupportedFormat
    case coreAudio(OSStatus)
    /// The device's nominal sample rate moved away from the stream's (Hz) to `actual` and could not be set back.
    case sampleRateChanged(expected: Double, actual: Double)
}

/// Why a Streamer ended a stream on its own (reported as `.failed` through `onStateChange`).
public enum StreamFailure: Error, CustomStringConvertible {
    /// The PCM source did not start (e.g. AudioDeviceStart failed).
    case captureFailed(any Error)
    /// The PCM source stopped delivering mid-stream (e.g. the capture sample rate changed).
    case sourceFailed(any Error)

    public var description: String {
        switch self {
        case .captureFailed(let why): return "capture failed to start: \(why)"
        case .sourceFailed(let why): return "capture failed: \(why)"
        }
    }
}
