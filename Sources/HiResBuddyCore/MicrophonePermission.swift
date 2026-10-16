import AVFoundation
import Foundation

/// Capturing the virtual device's input counts as microphone use; without permission the HAL delivers silence.
enum MicrophonePermission {
    static func request(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        request(status: AVCaptureDevice.authorizationStatus(for: .audio),
                ask: { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) },
                completion: completion)
    }

    /// `ask`'s answer arrives on an arbitrary queue (TCC's reply thread): the handler must not be main-actor
    /// isolated — Swift traps on entry otherwise — and hops to the main queue itself.
    static func request(status: AVAuthorizationStatus,
                        ask: (@escaping @Sendable (Bool) -> Void) -> Void,
                        completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        switch status {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            ask { @Sendable granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }
}
