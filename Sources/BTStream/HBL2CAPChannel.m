#import "BTStream.h"
#import "HBPrivateAPI.h"
#include <unistd.h>

@interface HBL2CAPChannel () <NSStreamDelegate>
@end

@implementation HBL2CAPChannel {
    CBL2CAPChannel *_cbChannel;     // strong: deallocating it closes the channel
    NSInputStream *_in;
    NSOutputStream *_out;           // opened only so the socket stays alive; writes go through write(fd)
    BOOL _closed;
}

+ (void)openPSM:(uint16_t)psm onDevice:(IOBluetoothDevice *)dev completion:(void (^)(HBL2CAPChannel *, NSInteger))completion {
    HBClassicPeerShim *peer = (HBClassicPeerShim *)[dev classicPeer];
    if (!peer) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, -1); });
        return;
    }
    __block HBClassicPeerShim *keepPeer = peer;   // alive until the callback fires, like the prototype's self.peer
    [peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
        keepPeer = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            HBL2CAPChannel *c = ch ? [[HBL2CAPChannel alloc] initWithCBChannel:ch psm:psm] : nil;
            completion(c, code);
        });
    }];
    [peer openL2CAPChannel:psm];
}

- (instancetype)initWithCBChannel:(CBL2CAPChannel *)ch psm:(uint16_t)psm {
    if (!(self = [super init])) return nil;
    _cbChannel = ch;
    _name = [NSString stringWithFormat:@"psm 0x%02x", psm];
    _socketFD = [[ch valueForKey:@"socketFD"] intValue];
    _outgoingMTU = [[ch valueForKey:@"outgoingMTU"] unsignedShortValue];
    [self attachInput:ch.inputStream output:ch.outputStream];
    return self;
}

- (instancetype)initWithSocketFD:(int)fd name:(NSString *)name {
    if (!(self = [super init])) return nil;
    _name = [name copy];
    _socketFD = fd;
    CFReadStreamRef rs = NULL;
    CFWriteStreamRef ws = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &rs, &ws);
    NSInputStream *in = CFBridgingRelease(rs);
    NSOutputStream *out = CFBridgingRelease(ws);
    [in setProperty:@YES forKey:(__bridge NSString *)kCFStreamPropertyShouldCloseNativeSocket];
    [out setProperty:@YES forKey:(__bridge NSString *)kCFStreamPropertyShouldCloseNativeSocket];
    [self attachInput:in output:out];
    return self;
}

- (void)attachInput:(NSInputStream *)in output:(NSOutputStream *)out {
    _in = in; _out = out;
    _in.delegate = self;
    [_in scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [_out scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [_in open]; [_out open];
}

- (BOOL)write:(NSData *)data {
    if (_closed || _socketFD < 0) return NO;
    ssize_t w = write(_socketFD, data.bytes, data.length);
    return w == (ssize_t)data.length;
}

- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e {
    if (e & NSStreamEventHasBytesAvailable) {
        uint8_t b[2048];
        NSInteger n = [_in read:b maxLength:sizeof b];
        if (n > 0) [self.delegate channel:self didReceive:[NSData dataWithBytes:b length:n]];
    }
    if (e & (NSStreamEventErrorOccurred | NSStreamEventEndEncountered)) {
        if (_closed) return;
        [self close];
        [self.delegate channelDidClose:self];
    }
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    _in.delegate = nil;
    [_in close]; [_out close];
    [_in removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [_out removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    _cbChannel = nil;
}

- (void)dealloc { [self close]; }

@end
