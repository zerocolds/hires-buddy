import CoreAudio

/// Errors of the HiRes Buddy core (the Bluetooth session's errors are `HBSessionError` in BTStream).
public enum HBError: Error, Equatable {
    /// The "HiRes Buddy" virtual audio device is not present (driver not installed or coreaudiod not restarted).
    case deviceNotInstalled
    /// The device's input stream is not interleaved stereo Float32.
    case unsupportedFormat
    case coreAudio(OSStatus)
}
