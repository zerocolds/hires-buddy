// cbtest: open AVDTP signaling on PSM 0x19 directly through CoreBluetooth's classic peer, bypassing IOBluetoothL2CAPChannel.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <objc/runtime.h>
#include <sys/socket.h>
static NSString *const kAddr = @"00-00-00-00-00-00";   // set your headphone address
@interface IOBluetoothDevice (Priv) - (id)classicPeer; @end
@interface NSObject (CBPriv)
- (void)setConnectL2CAPCallback:(void (^)(id ch, long code))cb;
- (id)openL2CAPChannel:(unsigned long)psm;
- (NSInputStream *)inputStream; - (NSOutputStream *)outputStream;
@end
@interface S : NSObject <NSStreamDelegate> @property(strong) NSMutableArray *chans; @property int n; @end
@implementation S
- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e {
    if (e & NSStreamEventHasBytesAvailable) {
        uint8_t b[1024]; NSInteger n = [(NSInputStream *)s read:b maxLength:sizeof b];
        NSMutableString *h = [NSMutableString string]; for (NSInteger i = 0; i < n; i++) [h appendFormat:@"%02x ", b[i]];
        NSLog(@"RX(%ld): %@", (long)n, h);
    }
    if (e & NSStreamEventErrorOccurred) NSLog(@"stream error %@", s.streamError);
    if (e & NSStreamEventEndEncountered) NSLog(@"stream EOF");
}
@end
int main(int argc, const char *argv[]) { @autoreleasepool {
    S *s = [S new]; s.chans = [NSMutableArray array];
    (void)IOBluetoothDevice.pairedDevices;                        // warm up coordinator
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:kAddr];
        id peer = [d classicPeer];
        NSLog(@"peer: %@", peer);
        [peer setConnectL2CAPCallback:^(id ch, long code) {
            NSLog(@"callback: code=%ld channel=%@ class=%s", code, ch, class_getName([ch class]));
            if (!ch) return;
            [s.chans addObject:ch];
            unsigned cnt = 0; Ivar *iv = class_copyIvarList([ch class], &cnt);
            for (unsigned i = 0; i < cnt; i++) {
                const char *nm = ivar_getName(iv[i]), *ty = ivar_getTypeEncoding(iv[i]);
                if (ty[0] == 'i' || ty[0] == 'q' || ty[0] == 'I' || ty[0] == 'Q') {
                    long v = ty[0] == 'i' || ty[0] == 'I' ? *(int *)((char *)(__bridge void *)ch + ivar_getOffset(iv[i])) : *(long *)((char *)(__bridge void *)ch + ivar_getOffset(iv[i]));
                    NSLog(@"  ivar %s (%s) = %ld", nm, ty, v);
                    if (strcasestr(nm, "sock") || strcasestr(nm, "fd")) { int t = 0; socklen_t l = sizeof t; getsockopt((int)v, SOL_SOCKET, SO_TYPE, &t, &l); NSLog(@"  socket type = %d (STREAM=1 DGRAM=2 SEQPACKET=5)", t); }
                } else NSLog(@"  ivar %s (%s)", nm, ty);
            }
            NSInputStream *in = [ch inputStream]; NSOutputStream *out = [ch outputStream];
            NSLog(@"streams: in=%@ out=%@", in, out);
            in.delegate = s; [in scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode]; [in open];
            [out scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode]; [out open];
            static const uint8_t disc[2] = {0x10, 0x01};
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                NSInteger w = [out write:disc maxLength:2]; NSLog(@"wrote DISCOVER: %ld", (long)w);
            });
            if (++s.n == 1) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                NSLog(@"opening second channel..."); [peer openL2CAPChannel:0x19];
            });
        }];
        id r = [peer openL2CAPChannel:0x19];
        NSLog(@"openL2CAPChannel -> %@", r);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ NSLog(@"done"); exit(0); });
    [[NSRunLoop mainRunLoop] run]; } }
