// hiresbuddy-cli play <wav> [--addr xx-xx-xx-xx-xx-xx] [--quality hq|sq|mq] — LDAC playback of a WAV file.
import BTStream
import Foundation
import HiResBuddyCore
import IOBluetooth
import LDACEncoder

setvbuf(stdout, nil, _IOLBF, 0)

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func die(_ message: String, code: Int32 = 64) -> Never {
    printError(message)
    exit(code)
}

let usage = "usage: hiresbuddy-cli play <wav> [--addr xx-xx-xx-xx-xx-xx] [--quality hq|sq|mq]  (--addr defaults to $LDAC_ADDR)"

var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "play", args.count >= 2 else { die(usage) }
args.removeFirst()
var wavPath: String?
var addr = ProcessInfo.processInfo.environment["LDAC_ADDR"]
var quality = LDACQuality.sq
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--addr":
        guard !args.isEmpty else { die(usage) }
        addr = args.removeFirst()
    case "--quality":
        guard !args.isEmpty else { die(usage) }
        switch args.removeFirst() {
        case "hq": quality = .hq
        case "sq": quality = .sq
        case "mq": quality = .mq
        default: die(usage)
        }
    default:
        guard wavPath == nil, !arg.hasPrefix("-") else { die(usage) }
        wavPath = arg
    }
}
guard let wavPath else { die(usage) }
guard let addr, !addr.isEmpty else { die("no headphones address: pass --addr or set LDAC_ADDR\n" + usage) }
let address = addr.lowercased().replacingOccurrences(of: ":", with: "-")

let wav: WAVSource
do { wav = try WAVSource(url: URL(fileURLWithPath: wavPath)) } catch { die("\(wavPath): \(error)", code: 65) }
guard let device = IOBluetoothDevice(addressString: address) else { die("bad address \(address)") }
_ = IOBluetoothDevice.pairedDevices()   // warms up the IOBluetooth/CoreBluetooth bridge

let session = HBAVDTPSession(device: device, helper: HBTransportHelperClient())
let streamer = Streamer(session: session, sampleRate: wav.sampleRate, quality: quality)
print(String(format: "%@: %d Hz, %.1f s → %@ (%@), LDAC %@",
             wavPath, wav.sampleRate.rawValue, wav.duration, device.name ?? "?", address, "\(quality)"))

streamer.onStats = { s in
    print(String(format: "%5.0fs  %@  %d Hz  %4d kbit/s  packets %6d  buffer %.2fs  drops %d  write errors %d",
                 s.uptime, "\(s.quality)", s.sampleRate, s.bitrateKbps, s.packets, s.bufferSeconds, s.dropEvents,
                 s.writeErrors))
}

/// Ctrl-C / end of file → stop, then exit once Closed arrives and the restore hook (closeConnection, then
/// openConnection 1.5 s later) has had time to give A2DP back to macOS.
@MainActor final class Playback {
    private let streamer: Streamer
    private var stopping = false

    init(streamer: Streamer) {
        self.streamer = streamer
    }

    func stop(_ reason: String) {
        if stopping { exit(0) }   // a second Ctrl-C: give up waiting
        stopping = true
        printError(reason)
        streamer.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { die("no Closed within 3 s, exiting", code: 0) }
    }

    func sessionEnded(_ code: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { exit(code) }
    }
}
let playback = Playback(streamer: streamer)

let stateNames: [HBSessionState: String] = [
    .idle: "idle", .connecting: "connecting", .configured: "configured", .streaming: "streaming",
    .suspended: "suspended", .closed: "closed", .failed: "failed",
]
streamer.onStateChange = { state, err in
    printError("state: \(stateNames[state] ?? "\(state.rawValue)")" + (err.map { " — \($0.localizedDescription)" } ?? ""))
    switch state {
    case .closed: playback.sessionEnded(0)
    case .failed: playback.sessionEnded(1)
    default: break
    }
}

wav.onEnd = {
    DispatchQueue.main.async { MainActor.assumeIsolated { playback.stop("end of file") } }
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { MainActor.assumeIsolated { playback.stop("interrupted, stopping") } }
sigint.resume()

DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    MainActor.assumeIsolated {
        do { try streamer.start(source: wav) } catch { die("cannot start: \(error)", code: 70) }
    }
}
dispatchMain()
