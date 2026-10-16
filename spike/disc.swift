import Foundation
import IOBluetooth
let dev = IOBluetoothDevice(addressString: ProcessInfo.processInfo.environment["LDAC_ADDR"] ?? "00-00-00-00-00-00")!
print("before:", dev.isConnected())
print("closeConnection ->", String(format: "0x%08x", dev.closeConnection()))
sleep(2)
print("after:", dev.isConnected())
