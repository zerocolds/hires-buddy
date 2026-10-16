import BTStream
import Foundation
import IOBluetooth

public struct Headphones: Identifiable, Hashable, Sendable {
    /// Lowercase address with dashes, e.g. `94-db-56-e1-43-75`.
    public let id: String
    public let name: String
    public let isConnected: Bool
    /// LDAC sample-rate bit mask (0x20 44.1, 0x10 48, 0x08 88.2, 0x04 96 kHz). nil = not probed or unknown
    /// (the sink did not answer); 0 = the sink answered and has no LDAC endpoint.
    public let ldacSampleRates: UInt8?

    public init(id: String, name: String, isConnected: Bool, ldacSampleRates: UInt8?) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.ldacSampleRates = ldacSampleRates
    }
}

public enum HeadphoneDiscovery {
    /// Paired devices that advertise the A2DP sink service (SDP 0x110B).
    public static func pairedA2DPDevices() -> [Headphones] {
        let sink = IOBluetoothSDPUUID.uuid16(0x110B)
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { device in
            guard let sink, device.getServiceRecord(for: sink) != nil else { return nil }
            return Headphones(
                id: (device.addressString ?? "").lowercased().replacingOccurrences(of: ":", with: "-"),
                name: device.name ?? device.addressString ?? "?",
                isConnected: device.isConnected(),
                ldacSampleRates: nil)
        }
    }

    /// Asks a connected sink for its LDAC capabilities over a short-lived signaling channel (DISCOVER, then
    /// GET_CAPABILITIES per sink endpoint; nothing else is sent). The sink may refuse the channel or stay silent
    /// while macOS owns A2DP: then the result is unknown (`ldacSampleRates == nil`), never "no LDAC".
    public static func probeLDAC(_ h: Headphones) async -> Headphones {
        guard h.isConnected else { return h }
        let rates = await LDACProber().run(address: h.id)
        return Headphones(id: h.id, name: h.name, isConnected: h.isConnected, ldacSampleRates: rates)
    }
}

/// One probe: open PSM 0x19, DISCOVER, GET_CAPABILITIES over the sink endpoints, close. Main actor, because the
/// channel delivers its callbacks on the main run loop.
@MainActor
private final class LDACProber: NSObject, HBL2CAPChannelDelegate {
    private static let timeout: TimeInterval = 5
    private var continuation: CheckedContinuation<UInt8?, Never>?
    private var channel: HBL2CAPChannel?
    private var finished = false
    private var sinks: [HBAVDTPEndpoint] = []
    private var next = 0
    private var label: UInt8 = 0
    private var awaiting: HBAVDTPSignal?

    func run(address: String) async -> UInt8? {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt8?, Never>) in
            continuation = cont
            guard let device = IOBluetoothDevice(addressString: address) else { return finish(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) {
                MainActor.assumeIsolated { self.finish(nil) }
            }
            HBL2CAPChannel.openPSM(0x19, on: device) { ch, _ in
                MainActor.assumeIsolated {
                    guard let ch else { return self.finish(nil) }
                    if self.finished { return ch.close() }   // arrived after the deadline
                    self.channel = ch
                    ch.delegate = self
                    self.send(.discover, payload: nil)
                }
            }
        }
    }

    private func send(_ signal: HBAVDTPSignal, payload: Data?) {
        awaiting = signal
        label = (label + 1) & 0x0F
        if !(channel?.write(HBAVDTP.command(signal, label: label, payload: payload)) ?? false) { finish(nil) }
    }

    private func queryNext() {
        guard next < sinks.count else {
            // every sink endpoint answered and none offers LDAC
            return finish(0)
        }
        let ep = sinks[next]
        send(.getCapabilities, payload: Data([ep.seid << 2]))
    }

    private func finish(_ rates: UInt8?) {
        guard !finished else { return }
        finished = true
        channel?.delegate = nil
        channel?.close()
        channel = nil
        continuation?.resume(returning: rates)
        continuation = nil
    }

    nonisolated func channel(_ c: HBL2CAPChannel, didReceive data: Data) {
        MainActor.assumeIsolated { handle(data) }
    }

    nonisolated func channelDidClose(_ c: HBL2CAPChannel) {
        MainActor.assumeIsolated { finish(nil) }
    }

    private func handle(_ data: Data) {
        var rxLabel: UInt8 = 0, type: UInt8 = 0, signal = HBAVDTPSignal.discover
        guard !finished, HBAVDTP.parseHeader(data, label: &rxLabel, messageType: &type, signal: &signal),
              type != 0, signal == awaiting, rxLabel == label else { return }
        switch signal {
        case .discover:
            guard type == 2 else { return finish(nil) }
            sinks = HBAVDTP.parseDiscover(data).filter(\.isSink)
            queryNext()
        case .getCapabilities:
            let ep = sinks[next]
            if type == 2 {
                HBAVDTP.parseCapabilities(data, into: ep)
                if ep.supportsLDAC { return finish(ep.ldacSampleRates) }
            }
            next += 1
            queryNext()
        default:
            break
        }
    }
}
