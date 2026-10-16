import LDACEncoder

/// Wraps LDAC packets in RTP for the A2DP transport channel, byte-for-byte like the prototype:
/// 12-byte RTP header (V=2, no marker), then the 1-byte LDAC media header (frame count), then the payload.
public struct RTPPacketizer {
    public private(set) var sequence: UInt16 = 0
    private let ssrc: UInt32
    private let payloadType: UInt8

    public init(ssrc: UInt32 = 1, payloadType: UInt8 = 0x60) {
        self.ssrc = ssrc
        self.payloadType = payloadType & 0x7f
    }

    public mutating func packet(for p: LDACPacket, timestamp: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(13 + p.bytes.count)
        out.append(0x80)
        out.append(payloadType)
        out.append(UInt8(sequence >> 8)); out.append(UInt8(sequence & 0xff))
        for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((timestamp >> UInt32(shift)) & 0xff)) }
        for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((ssrc >> UInt32(shift)) & 0xff)) }
        out.append(UInt8(p.frames & 0x0f))
        out.append(contentsOf: p.bytes)
        sequence &+= 1
        return out
    }
}
