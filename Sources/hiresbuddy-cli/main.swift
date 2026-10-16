// hiresbuddy-cli probe — paired A2DP devices and their LDAC support.
// hiresbuddy-cli play <wav> [--addr xx-xx-xx-xx-xx-xx] [--quality hq|sq|mq] — LDAC playback of a WAV file.
// hiresbuddy-cli system [--addr xx-xx-xx-xx-xx-xx] [--quality hq|sq|mq] — system audio via the HiRes Buddy device.
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

let usage = """
    usage: hiresbuddy-cli probe
           hiresbuddy-cli play <wav> [--addr xx-xx-xx-xx-xx-xx] [--quality hq|sq|mq]
           hiresbuddy-cli system [--addr xx-xx-xx-xx-xx-xx] [--quality hq|sq|mq]
    (--addr defaults to $LDAC_ADDR)
    """

var args = Array(CommandLine.arguments.dropFirst())

if args == ["probe"] {
    func rateList(_ mask: UInt8) -> String {
        let rates: [(UInt8, String)] = [(0x20, "44.1"), (0x10, "48"), (0x08, "88.2"), (0x04, "96")]
        return rates.filter { mask & $0.0 != 0 }.map(\.1).joined(separator: "/")
    }
    Task { @MainActor in
        for var h in HeadphoneDiscovery.pairedA2DPDevices() {
            if h.isConnected { h = await HeadphoneDiscovery.probeLDAC(h) }   // one at a time
            let ldac: String
            switch h.ldacSampleRates {
            case nil: ldac = "unknown"
            case 0?: ldac = "no LDAC"
            case let mask?: ldac = "LDAC " + rateList(mask)
            }
            print("\(h.name)  \(h.id)  \(h.isConnected ? "connected" : "disconnected")  \(ldac)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

guard let command = args.first, command == "play" || command == "system" else { die(usage) }
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
        guard command == "play", wavPath == nil, !arg.hasPrefix("-") else { die(usage) }
        wavPath = arg
    }
}
if command == "play" && wavPath == nil { die(usage) }
guard let addr, !addr.isEmpty else { die("no headphones address: pass --addr or set LDAC_ADDR\n" + usage) }
let address = addr.lowercased().replacingOccurrences(of: ":", with: "-")

guard let device = IOBluetoothDevice(addressString: address) else { die("bad address \(address)") }
_ = IOBluetoothDevice.pairedDevices()   // warms up the IOBluetooth/CoreBluetooth bridge

let source: PCMSource
let sampleRate: LDACSampleRate
var wav: WAVSource?
var capture: AudioCapture?
var meter: LevelMeter?
/// Set for `system` only: the default output goes to HiRes Buddy and must be put back on every way out.
var switcher: OutputDeviceSwitcher?
if let wavPath {
    let w: WAVSource
    do { w = try WAVSource(url: URL(fileURLWithPath: wavPath)) } catch { die("\(wavPath): \(error)", code: 65) }
    wav = w
    source = w
    sampleRate = w.sampleRate
    print(String(format: "%@: %d Hz, %.1f s → %@ (%@), LDAC %@",
                 wavPath, w.sampleRate.rawValue, w.duration, device.name ?? "?", address, "\(quality)"))
} else {
    sampleRate = .hz48000
    let c: AudioCapture
    do { c = try AudioCapture(sampleRate: sampleRate.rawValue) } catch {
        die("\(AudioCapture.deviceName): \(error) (install it with driver/build.sh and driver/install.sh)", code: 69)
    }
    let s = OutputDeviceSwitcher()
    guard let hiresBuddy = s.deviceID(named: AudioCapture.deviceName) else { die("\(AudioCapture.deviceName) vanished", code: 69) }
    do { try s.switchTo(hiresBuddy) } catch { die("cannot make \(AudioCapture.deviceName) the default output: \(error)", code: 70) }
    let m = LevelMeter(c)
    capture = c
    meter = m
    switcher = s
    source = m
    print(String(format: "system audio → %@: %d Hz → %@ (%@), LDAC %@",
                 AudioCapture.deviceName, sampleRate.rawValue, device.name ?? "?", address, "\(quality)"))
}

/// Puts the previous default output back (system mode); safe to call more than once.
@MainActor func restoreOutput() {
    guard let s = switcher else { return }
    do { try s.restore() } catch { printError("cannot restore the default output: \(error)") }
}

let session = HBAVDTPSession(device: device, helper: HBTransportHelperClient())
session.logHandler = { printError("session: \($0)") }
let streamer = Streamer(session: session, sampleRate: sampleRate, quality: quality)
// The driver already scales its input by its own volume control (dB taper, mute included), so the captured PCM is
// at the Mac's volume: no extra gain here, or the volume would be applied twice.
capture?.onVolumeChange { v in printError(String(format: "volume %.2f", v)) }

streamer.onStats = { s in
    let level = meter.map { String(format: "  peak %.0f dBFS", $0.takePeakDBFS()) } ?? ""
    print(String(format: "%5.0fs  %@  %d Hz  %4d kbit/s  packets %6d  buffer %.2fs  drops %d  write errors %d  backpressure %d",
                 s.uptime, "\(s.quality)", s.sampleRate, s.bitrateKbps, s.packets, s.bufferSeconds, s.dropEvents,
                 s.writeErrors, s.backpressureTicks) + level)
}

/// Ctrl-C / end of file → stop, then exit once Closed arrives and the restore hook (closeConnection, then
/// openConnection 1.5 s later) has brought the headphones back: an IOBluetooth connect still pending when the
/// process exits is cancelled, which would leave them disconnected.
@MainActor final class Playback {
    private let streamer: Streamer
    private let device: IOBluetoothDevice
    private var stopping = false
    private var ended = false
    /// The session takes the link over (and must give it back) only when the device was connected at start.
    var takeover = false

    init(streamer: Streamer, device: IOBluetoothDevice) {
        self.streamer = streamer
        self.device = device
    }

    func stop(_ reason: String) {
        if stopping { exit(0) }   // a second Ctrl-C: give up waiting
        stopping = true
        printError(reason)
        restoreOutput()
        streamer.stop()
        // stop waits for SUSPEND and CLOSE answers, at most 1 s each
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
            if !ended { die("no Closed within 5 s, exiting", code: 0) }
        }
    }

    /// Closed always runs the restore hook; Failed only after a takeover — otherwise there is little to wait for.
    func sessionEnded(_ code: Int32, failed: Bool) {
        ended = true
        restoreOutput()
        let seconds = failed && !takeover ? 5 : 80
        printError("waiting for the headphones to reconnect to macOS…")
        waitForReconnect(code, sawDisconnect: false, checksLeft: seconds * 4, seconds: seconds)
    }

    /// The restore hook drops the link first, so "reconnected" means connected after having been seen disconnected.
    private func waitForReconnect(_ code: Int32, sawDisconnect: Bool, checksLeft: Int, seconds: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            let connected = device.isConnected()
            if sawDisconnect && connected {
                printError("reconnected")
                exit(code)
            }
            if checksLeft == 0 {
                printError("headphones did not reconnect within \(seconds) s")
                exit(code)
            }
            waitForReconnect(code, sawDisconnect: sawDisconnect || !connected, checksLeft: checksLeft - 1, seconds: seconds)
        }
    }
}
let playback = Playback(streamer: streamer, device: device)

let stateNames: [HBSessionState: String] = [
    .idle: "idle", .connecting: "connecting", .configured: "configured", .streaming: "streaming",
    .suspended: "suspended", .closed: "closed", .failed: "failed",
]
streamer.onStateChange = { state, err in
    printError("state: \(stateNames[state] ?? "\(state.rawValue)")" + (err.map { " — \($0.localizedDescription)" } ?? ""))
    switch state {
    case .closed: playback.sessionEnded(0, failed: false)
    case .failed: playback.sessionEnded(1, failed: true)
    default: break
    }
}

wav?.onEnd = {
    DispatchQueue.main.async { MainActor.assumeIsolated { playback.stop("end of file") } }
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { MainActor.assumeIsolated { playback.stop("interrupted, stopping") } }
sigint.resume()

DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    MainActor.assumeIsolated {
        playback.takeover = device.isConnected()
        do { try streamer.start(source: source) } catch {
            restoreOutput()
            die("cannot start: \(error)", code: 70)
        }
    }
}
// Not dispatchMain(): that exits the main thread, and the L2CAP channels' streams are scheduled on the main run loop.
RunLoop.main.run()
