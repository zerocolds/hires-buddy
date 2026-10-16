// l2test <mode>: probe which way of opening PSM 0x19 survives on an already-connected device.
// modes: cb (open inside connect callback), delay (2s after callback), sync (openL2CAPChannelSync), paired (device from pairedDevices)
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
static NSString *const kAddr = @"94-db-56-e1-43-75";
static const char *mode;
@interface T : NSObject <IOBluetoothL2CAPChannelDelegate>
@property(strong) IOBluetoothDevice *dev; @property(strong) IOBluetoothL2CAPChannel *ch; @property BOOL fired;
@end
@implementation T
- (void)open {
    IOBluetoothL2CAPChannel *c = nil; IOReturn r;
    if (!strcmp(mode, "sync")) r = [self.dev openL2CAPChannelSync:&c withPSM:0x19 delegate:self];
    else r = [self.dev openL2CAPChannelAsync:&c withPSM:0x19 delegate:self];
    self.ch = c; NSLog(@"[%s] open -> 0x%x channel=%p dev=%p connected=%d", mode, r, c, self.dev, self.dev.isConnected);
}
- (void)connected:(IOBluetoothUserNotification *)n device:(IOBluetoothDevice *)d {
    if (self.fired || ![[[d.addressString lowercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"] isEqualToString:kAddr]) return;
    self.fired = YES; self.dev = d; NSLog(@"[%s] notification", mode);
    if (!strcmp(mode, "delay")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self open]; });
    else [self open];
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)c status:(IOReturn)st {
    NSLog(@"[%s] open complete 0x%x mtu %u", mode, st, c.outgoingMTU);
    if (st) exit(2);
    uint8_t d[2] = {0x10, 0x01}; [c writeSync:d length:2];
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)c data:(void *)p length:(size_t)n { NSLog(@"[%s] RX %zu bytes — ALIVE", mode, n); [c closeChannel]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/2), dispatch_get_main_queue(), ^{ exit(0); }); }
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)c { NSLog(@"[%s] CLOSED", mode); exit(1); }
@end
int main(int argc, const char *argv[]) { @autoreleasepool {
    mode = argv[1]; T *t = [T new];
    if (!strncmp(mode, "late", 4)) {                 // warm up the coordinator first, fetch the device much later
        (void)IOBluetoothDevice.pairedDevices;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!strcmp(mode, "late-addr")) t.dev = [IOBluetoothDevice deviceWithAddressString:kAddr];
            else for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices)
                if ([[[d.addressString lowercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"] isEqualToString:kAddr]) t.dev = d;
            [t open];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ NSLog(@"[%s] timeout", mode); exit(3); });
        [[NSRunLoop mainRunLoop] run];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{   // let IOBluetooth settle
        if (!strcmp(mode, "paired")) {
            for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices)
                if ([[[d.addressString lowercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"] isEqualToString:kAddr]) { t.dev = d; [t open]; }
        } else [IOBluetoothDevice registerForConnectNotifications:t selector:@selector(connected:device:)];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ NSLog(@"[%s] timeout", mode); exit(3); });
    [[NSRunLoop mainRunLoop] run]; } }
