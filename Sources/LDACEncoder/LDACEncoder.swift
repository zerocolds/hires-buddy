import CLDAC

/// Encode quality mode; raw values match `LDACBT_EQMID_*`.
public enum LDACQuality: Int, CaseIterable, Sendable {
    case hq = 0, sq = 1, mq = 2
}

public enum LDACSampleRate: Int, Sendable {
    case hz44100 = 44100, hz48000 = 48000, hz88200 = 88200, hz96000 = 96000

    /// A2DP LDAC codec-information sampling-frequency bit.
    public var avdtpBit: UInt8 {
        switch self {
        case .hz44100: return 0x20
        case .hz48000: return 0x10
        case .hz88200: return 0x08
        case .hz96000: return 0x04
        }
    }
}

public struct LDACPacket: Sendable {
    /// Number of LDAC frames in `bytes`.
    public let frames: Int
    /// Payload after the RTP header, without the 1-byte LDAC media payload header.
    public let bytes: [UInt8]
}

public enum LDACEncoderError: Error, Equatable {
    case handleAllocationFailed
    case initFailed(code: Int)
    case setQualityFailed(code: Int)
    case wrongBlockSize(samples: Int)
    case encodeFailed(code: Int)
}

public final class LDACEncoder {
    /// Stereo frames per `encode` call (`LDACBT_ENC_LSU`).
    public static let framesPerBlock = Int(LDACBT_ENC_LSU)
    private static let channels = 2

    public let sampleRate: LDACSampleRate
    private let handle: HANDLE_LDAC_BT
    private var currentQuality: LDACQuality
    private var out: [UInt8]

    public init(sampleRate: LDACSampleRate, quality: LDACQuality, mtu: Int = 679) throws {
        guard let h = ldacBT_get_handle() else { throw LDACEncoderError.handleAllocationFailed }
        let rc = ldacBT_init_handle_encode(
            h, Int32(mtu), Int32(quality.rawValue), Int32(LDACBT_CHANNEL_MODE_STEREO),
            LDACBT_SMPL_FMT_F32, Int32(sampleRate.rawValue))
        guard rc == 0 else {
            let code = Int(ldacBT_get_error_code(h))
            ldacBT_free_handle(h)
            throw LDACEncoderError.initFailed(code: code)
        }
        handle = h
        self.sampleRate = sampleRate
        currentQuality = quality
        out = [UInt8](repeating: 0, count: max(mtu, 1024) * 2)
    }

    deinit {
        ldacBT_close_handle(handle)
        ldacBT_free_handle(handle)
    }

    /// Best-effort convenience: a failed switch is silently ignored (the getter keeps
    /// reporting the previous quality). Use `setQuality(_:)` when the error matters.
    public var quality: LDACQuality {
        get { currentQuality }
        set { try? setQuality(newValue) }
    }

    /// Switches quality on the fly; throws with libldac's error code on failure.
    public func setQuality(_ newValue: LDACQuality) throws {
        guard newValue != currentQuality else { return }
        guard ldacBT_set_eqmid(handle, Int32(newValue.rawValue)) == 0 else {
            throw LDACEncoderError.setQualityFailed(code: Int(ldacBT_get_error_code(handle)))
        }
        currentQuality = newValue
    }

    /// Samples per channel in one LDAC frame: 128 up to 48 kHz, 256 at 88.2/96 kHz.
    public var samplesPerFrame: Int {
        switch sampleRate {
        case .hz44100, .hz48000: return 128
        case .hz88200, .hz96000: return 256
        }
    }

    /// `pcm`: interleaved stereo Float32, exactly 128 frames (256 samples).
    /// Returns nil until enough blocks have accumulated for a packet.
    public func encode(_ pcm: UnsafeBufferPointer<Float>) throws -> LDACPacket? {
        let expected = Self.framesPerBlock * Self.channels
        guard pcm.count == expected, let base = pcm.baseAddress else {
            throw LDACEncoderError.wrongBlockSize(samples: pcm.count)
        }
        return try run(pcm: UnsafeMutableRawPointer(mutating: base))
    }

    /// Drains the encoder's internal buffer at end of stream.
    public func flush() throws -> LDACPacket? {
        try run(pcm: nil)
    }

    private func run(pcm: UnsafeMutableRawPointer?) throws -> LDACPacket? {
        var used: Int32 = 0, wrote: Int32 = 0, frames: Int32 = 0
        let rc = out.withUnsafeMutableBufferPointer {
            ldacBT_encode(handle, pcm, &used, $0.baseAddress, &wrote, &frames)
        }
        guard rc == 0 else {
            throw LDACEncoderError.encodeFailed(code: Int(ldacBT_get_error_code(handle)))
        }
        guard wrote > 0 else { return nil }
        return LDACPacket(frames: Int(frames), bytes: Array(out[0..<Int(wrote)]))
    }

    /// Nominal bitrate in kbit/s.
    public static func nominalBitrate(quality: LDACQuality, sampleRate: LDACSampleRate) -> Int {
        let highRate = sampleRate == .hz48000 || sampleRate == .hz96000
        switch quality {
        case .hq: return highRate ? 990 : 909
        case .sq: return highRate ? 660 : 606
        case .mq: return highRate ? 330 : 303
        }
    }
}
