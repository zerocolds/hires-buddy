import BTStream
import Foundation
import XCTest
@testable import HiResBuddyCore

/// A fake sink on the far end of a socketpair; `reply` maps each received command to an answer (nil = silence).
private final class FakeSink: @unchecked Sendable {
    let channel: HBL2CAPChannel
    private let fd: Int32
    private let lock = NSLock()
    private var _received: [Data] = []
    var received: [Data] { lock.withLock { _received } }

    init(reply: @escaping @Sendable (Data) -> Data?) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        channel = HBL2CAPChannel(socketFD: fds[0], name: "probe-test")!
        fd = fds[1]
        let fd = fd
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                let cmd = Data(buf[0..<n])
                lock.withLock { _received.append(cmd) }
                if let rsp = reply(cmd) { _ = write(fd, [UInt8](rsp), rsp.count) }
            }
            close(fd)
        }
    }
}

private let discoverPayload: [UInt8] = [0x04, 0x08, 0x08, 0x08, 0x0c, 0x08, 0x10, 0x08, 0x14, 0x08, 0x18, 0x08]
private let ldacCaps: [UInt8] = [0x01, 0x00, 0x07, 0x0a, 0x00, 0xff, 0x2d, 0x01, 0x00, 0x00, 0xaa, 0x00, 0x3c, 0x07, 0x04, 0x02, 0x02, 0x00]
private let sbcCaps: [UInt8] = [0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0xff, 0xff, 0x02, 0x35]

private func accept(_ cmd: Data, _ payload: [UInt8]) -> Data { Data([(cmd[0] & 0xF0) | 2, cmd[1]] + payload) }

@MainActor
final class HeadphoneDiscoveryTests: XCTestCase {
    private let xm4 = Headphones(id: "94-db-56-e1-43-75", name: "WH-1000XM4", isConnected: true, ldacSampleRates: nil)

    private func probe(_ sink: FakeSink, timeout: TimeInterval = 3) async -> Headphones {
        await HeadphoneDiscovery.probeLDAC(xm4, opener: { _, psm, done in
            XCTAssertEqual(psm, 0x19)
            done(sink.channel, 0)
        }, timeout: timeout)
    }

    func testFindsLDACAfterRejectAndSBC() async {
        let sink = FakeSink { cmd in
            switch cmd[1] {
            case 1: return accept(cmd, discoverPayload)
            case 2:
                switch cmd[2] >> 2 {
                case 1: return Data([(cmd[0] & 0xF0) | 3, 2, 0x12])
                case 2: return accept(cmd, sbcCaps)
                default: return accept(cmd, ldacCaps)
                }
            default: return nil
            }
        }
        let result = await probe(sink)
        XCTAssertEqual(result.ldacSampleRates, 0x3c)
        let signals = sink.received.map { $0[1] }
        XCTAssertEqual(signals, [1, 2, 2, 2])   // only DISCOVER and GET_CAPABILITIES, stops at LDAC
    }

    func testNoLDACWhenSinksAnswerWithoutIt() async {
        let sink = FakeSink { cmd in
            cmd[1] == 1 ? accept(cmd, [0x04, 0x08]) : accept(cmd, sbcCaps)
        }
        let result = await probe(sink)
        XCTAssertEqual(result.ldacSampleRates, 0)
    }

    func testAllCapabilitiesRejectedIsUnknown() async {
        let sink = FakeSink { cmd in
            cmd[1] == 1 ? accept(cmd, [0x04, 0x08]) : Data([(cmd[0] & 0xF0) | 3, 2, 0x12])
        }
        let result = await probe(sink)
        XCTAssertNil(result.ldacSampleRates)
    }

    func testZeroSinksIsUnknown() async {
        let sink = FakeSink { cmd in accept(cmd, [0x04, 0x00]) }   // one source endpoint only
        let result = await probe(sink)
        XCTAssertNil(result.ldacSampleRates)
    }

    func testSilentSinkTimesOutAsUnknown() async {
        let sink = FakeSink { _ in nil }
        let result = await probe(sink, timeout: 0.3)
        XCTAssertNil(result.ldacSampleRates)
        XCTAssertEqual(sink.received.map { $0[1] }, [1])
    }

    func testRefusedChannelIsUnknown() async {
        let result = await HeadphoneDiscovery.probeLDAC(xm4, opener: { _, _, done in done(nil, 454) }, timeout: 3)
        XCTAssertNil(result.ldacSampleRates)
    }

    func testDisconnectedDeviceIsNotProbed() async {
        let off = Headphones(id: xm4.id, name: xm4.name, isConnected: false, ldacSampleRates: nil)
        let result = await HeadphoneDiscovery.probeLDAC(off, opener: { _, _, _ in XCTFail("opened") }, timeout: 1)
        XCTAssertEqual(result, off)
    }
}
