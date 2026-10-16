import Foundation
import IOBluetooth

let addr = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "94-DB-56-E1-43-75"
guard let dev = IOBluetoothDevice(addressString: addr) else { print("no device"); exit(1) }
print("device:", dev.name ?? "?", "connected:", dev.isConnected())

func hex(_ d: [UInt8]) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

final class Probe: NSObject, IOBluetoothL2CAPChannelDelegate {
    var ch: IOBluetoothL2CAPChannel?
    var label: UInt8 = 0
    var seps: [UInt8] = []
    var idx = 0
    func send(_ sig: UInt8, _ payload: [UInt8]) {
        label = (label + 1) & 0x0f
        var p: [UInt8] = [(label << 4) | 0x00, sig] + payload   // single packet, command
        _ = ch?.writeSync(&p, length: UInt16(p.count))
    }
    func l2capChannelOpenComplete(_ c: IOBluetoothL2CAPChannel!, status: IOReturn) {
        print("open complete status=0x\(String(status, radix: 16)) outMTU=\(c.outgoingMTU)")
        if status == kIOReturnSuccess { send(0x01, []) } else { exit(2) }   // AVDTP_DISCOVER
    }
    func l2capChannelData(_ c: IOBluetoothL2CAPChannel!, data p: UnsafeMutableRawPointer!, length n: Int) {
        let b = Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: n))
        print("rx:", hex(b))
        guard b.count >= 2 else { return }
        let msgType = b[0] & 0x03, sig = b[1] & 0x3f
        if msgType != 0x02 { print("non-accept msgType=\(msgType)"); }
        if sig == 0x01 {
            var i = 2
            while i + 1 < b.count {
                let seid = b[i] >> 2, inUse = (b[i] >> 1) & 1, media = b[i+1] >> 4, tsep = (b[i+1] >> 3) & 1
                print("  SEP seid=\(seid) inUse=\(inUse) media=\(media) tsep=\(tsep == 1 ? "SNK" : "SRC")")
                seps.append(seid); i += 2
            }
            next()
        } else if sig == 0x02 || sig == 0x0c {
            var i = 2
            while i + 1 < b.count {
                let cat = b[i], len = Int(b[i+1]); let v = Array(b[min(i+2, b.count)..<min(i+2+len, b.count)])
                if cat == 7, v.count >= 2 {
                    let codec = v[1]
                    if codec == 0xff, v.count >= 8 {
                        let vendor = UInt32(v[2]) | UInt32(v[3]) << 8 | UInt32(v[4]) << 16 | UInt32(v[5]) << 24
                        let cid = UInt16(v[6]) | UInt16(v[7]) << 8
                        let isLDAC = vendor == 0x12d && cid == 0xaa
                        print("    CODEC vendor=0x\(String(vendor, radix: 16)) id=0x\(String(cid, radix: 16)) \(isLDAC ? "<== LDAC" : "") cfg=\(hex(Array(v.dropFirst(8))))")
                    } else {
                        print("    CODEC type=\(codec) (\(codec == 0 ? "SBC" : codec == 2 ? "AAC" : "?")) cfg=\(hex(Array(v.dropFirst(2))))")
                    }
                }
                i += 2 + len
            }
            next()
        }
    }
    func next() {
        if idx < seps.count { let s = seps[idx]; idx += 1; send(0x02, [s << 2]) }   // GET_CAPABILITIES
        else { print("done"); ch?.close(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) } }
    }
    func l2capChannelClosed(_ c: IOBluetoothL2CAPChannel!) { print("channel closed") }
}

let probe = Probe()
final class Watcher: NSObject {
    var fired = false
    @objc func connected(_ n: IOBluetoothUserNotification, device d: IOBluetoothDevice) {
        guard !fired, d.addressString?.lowercased().replacingOccurrences(of: ":", with: "-") == addr.lowercased() else { return }
        fired = true
        print("connected notification:", d.name ?? "?", Date())
        var c: IOBluetoothL2CAPChannel?
        let r = d.openL2CAPChannelAsync(&c, withPSM: 0x19, delegate: probe)
        print("openL2CAPChannelAsync ->", String(format: "0x%08x", r)); probe.ch = c
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout after connect"); exit(3) }
    }
}
let w = Watcher()
if dev.isConnected() { print("WARNING: already connected") }
IOBluetoothDevice.register(forConnectNotifications: w, selector: #selector(Watcher.connected(_:device:)))
print("waiting for headphones to connect... (180s)")
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("no connection in 180s"); exit(4) }
RunLoop.main.run()
