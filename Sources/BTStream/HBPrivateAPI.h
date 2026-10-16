// Private CoreBluetooth/IOBluetooth selectors. The public IOBluetoothL2CAPChannel API closes channels
// opened on an already-connected device; CBClassicPeer's openL2CAPChannel: does not.
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>

@interface IOBluetoothDevice (HBPriv)
- (id)classicPeer;
@end

// Stand-in for CBClassicPeer. A category on NSObject would clash with CBPeripheral's openL2CAPChannel:.
@interface HBClassicPeerShim : NSObject
- (void)setConnectL2CAPCallback:(void (^)(CBL2CAPChannel *ch, long code))cb;
- (id)openL2CAPChannel:(unsigned long)psm;   // raw PSM; returns it as NSNumber
@end
