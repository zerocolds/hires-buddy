import Foundation
import IOBluetooth
let dev = IOBluetoothDevice(addressString: ProcessInfo.processInfo.environment["LDAC_ADDR"] ?? "00-00-00-00-00-00")!
print("before:", dev.isConnected())
let r = dev.openConnection()
print("openConnection ->", String(format: "0x%08x", r), "after:", dev.isConnected())
