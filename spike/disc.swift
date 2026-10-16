import Foundation
import IOBluetooth
let dev = IOBluetoothDevice(addressString: "94-DB-56-E1-43-75")!
print("before:", dev.isConnected())
print("closeConnection ->", String(format: "0x%08x", dev.closeConnection()))
sleep(2)
print("after:", dev.isConnected())
