import Foundation
import IOBluetooth
let dev = IOBluetoothDevice(addressString: "94-DB-56-E1-43-75")!
print("before:", dev.isConnected())
let r = dev.openConnection()
print("openConnection ->", String(format: "0x%08x", r), "after:", dev.isConnected())
