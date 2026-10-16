// ldacplay — minimal A2DP source that streams a WAV (16/24-bit, 44.1–96 kHz) to a sink over LDAC.
// Talks AVDTP over L2CAP channels opened directly through CoreBluetooth's classic peer: the public
// IOBluetoothL2CAPChannel wrapper drops channels opened on an already-connected device.
// Usage: ldacplay <wav> [seconds]
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <mach/mach_time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "ldacBT.h"

static NSString *const kAddr = @"94-db-56-e1-43-75";
static int kSF = 44100;
static int kWL = 2;             // bytes per sample
static uint8_t kSFBit = LDACBT_SAMPLING_FREQ_044100;

@interface IOBluetoothDevice (Priv) - (id)classicPeer; @end
@interface CBClassicPeerShim : NSObject            // CBClassicPeer, private: avoids clashing with CBPeripheral's openL2CAPChannel:
- (void)setConnectL2CAPCallback:(void (^)(CBL2CAPChannel *ch, long code))cb;
- (id)openL2CAPChannel:(unsigned long)psm;
@end

enum { SIG_DISCOVER = 1, SIG_GET_CAP = 2, SIG_SET_CONF = 3, SIG_OPEN = 6, SIG_START = 7,
       SIG_CLOSE = 8, SIG_SUSPEND = 9, SIG_ABORT = 10, SIG_GET_ALL_CAP = 12, SIG_DELAYREPORT = 13 };

static double nowSec(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static NSString *hex(const uint8_t *b, size_t n) {
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x ", b[i]];
    return s;
}

// One L2CAP channel = one CBL2CAPChannel with its socket streams.
@interface Chan : NSObject <NSStreamDelegate>
@property(strong) CBL2CAPChannel *cb;
@property(strong) NSInputStream *in;
@property(strong) NSOutputStream *out;
@property(copy) void (^onData)(const uint8_t *, size_t);
@property(copy) void (^onClose)(void);
@property(copy) NSString *name;
@end
@implementation Chan
- (instancetype)initWith:(CBL2CAPChannel *)cb name:(NSString *)name {
    self = [super init];
    _cb = cb; _name = name; _in = cb.inputStream; _out = cb.outputStream;
    _in.delegate = self; _out.delegate = self;
    [_in scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [_out scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [_in open]; [_out open];
    return self;
}
- (NSInteger)write:(const uint8_t *)p len:(size_t)n {
    NSInteger w = [_out write:p maxLength:n];
    if (w != (NSInteger)n) NSLog(@"[%@] short write %ld/%zu", _name, (long)w, n);
    return w;
}
- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e {
    if (e & NSStreamEventHasBytesAvailable) {
        uint8_t b[2048];
        NSInteger n = [_in read:b maxLength:sizeof b];
        if (n > 0 && _onData) _onData(b, n);
    }
    if (e & (NSStreamEventErrorOccurred | NSStreamEventEndEncountered)) {
        NSLog(@"[%@] stream %@", _name, (e & NSStreamEventErrorOccurred) ? s.streamError : @"closed");
        if (_onClose) { _onClose(); _onClose = nil; }
    }
}
- (void)close { [_in close]; [_out close]; _in.delegate = nil; _out.delegate = nil; }
@end

@interface Player : NSObject
@property(strong) IOBluetoothDevice *dev;
@property(strong) CBClassicPeerShim *peer;
@property(strong) Chan *sig;
@property int mediaFD;                          // transport channel socket, owned by the helper process
@property(strong) NSTask *helper;
@property int listenFD;
@property(copy) NSString *sockPath;
@property(strong) NSMutableArray<NSData *> *packets;   // LDAC payloads incl. 1-byte frame-count header
@property(strong) NSMutableArray<NSNumber *> *frames;
@property double samplesPerFrame, limitSec;
@end

@implementation Player {
    uint8_t _label;
    NSMutableArray<NSNumber *> *_sinks;
    NSUInteger _capIdx;
    uint8_t _acp;
    NSUInteger _next;
    uint64_t _sentFrames;
    uint16_t _seq;
    double _t0;
    dispatch_source_t _timer;
    int _retries;
}

- (BOOL)encodeWav:(NSString *)path {
    NSData *wav = [NSData dataWithContentsOfFile:path];
    if (!wav) { NSLog(@"cannot read %@", path); return NO; }
    const uint8_t *b = wav.bytes;
    NSUInteger off = 12, dataOff = 0, dataLen = 0;
    int ch = 0, bits = 0;
    while (off + 8 <= wav.length) {               // walk RIFF chunks to "fmt " and "data"
        uint32_t len = *(uint32_t *)(b + off + 4);
        if (!memcmp(b + off, "fmt ", 4)) {
            ch = *(uint16_t *)(b + off + 10); kSF = *(uint32_t *)(b + off + 12); bits = *(uint16_t *)(b + off + 22);
        }
        if (!memcmp(b + off, "data", 4)) { dataOff = off + 8; dataLen = MIN(len, wav.length - dataOff); break; }
        off += 8 + len + (len & 1);
    }
    if (!dataOff) { NSLog(@"no data chunk"); return NO; }
    switch (kSF) {
    case 44100: kSFBit = LDACBT_SAMPLING_FREQ_044100; break;
    case 48000: kSFBit = LDACBT_SAMPLING_FREQ_048000; break;
    case 88200: kSFBit = LDACBT_SAMPLING_FREQ_088200; break;
    case 96000: kSFBit = LDACBT_SAMPLING_FREQ_096000; break;
    default: NSLog(@"unsupported rate %d (use play.sh to convert)", kSF); return NO;
    }
    if (ch != 2 || (bits != 16 && bits != 24 && bits != 32)) { NSLog(@"need stereo 16/24/32-bit PCM, got %d ch %d bit", ch, bits); return NO; }
    kWL = bits / 8;
    LDACBT_SMPL_FMT_T fmt = bits == 16 ? LDACBT_SMPL_FMT_S16 : bits == 24 ? LDACBT_SMPL_FMT_S24 : LDACBT_SMPL_FMT_S32;
    NSLog(@"input: %d Hz, %d-bit stereo", kSF, bits);

    HANDLE_LDAC_BT h = ldacBT_get_handle();
    const char *q = getenv("LDAC_Q");                 // hq (990/909 kbps) | sq (660/606) | mq (330/303)
    int eqmid = q && !strcmp(q, "sq") ? LDACBT_EQMID_SQ : q && !strcmp(q, "mq") ? LDACBT_EQMID_MQ : LDACBT_EQMID_HQ;
    NSLog(@"LDAC quality: %s", eqmid == LDACBT_EQMID_HQ ? "HQ" : eqmid == LDACBT_EQMID_SQ ? "SQ" : "MQ");
    if (ldacBT_init_handle_encode(h, 679, eqmid, LDACBT_CHANNEL_MODE_STEREO,
                                  fmt, kSF) != 0) {
        NSLog(@"ldac init failed: %d", ldacBT_get_error_code(h)); return NO;
    }
    self.packets = [NSMutableArray array];
    self.frames = [NSMutableArray array];
    const int blk = LDACBT_ENC_LSU * 2 * kWL;    // 128 samples * 2 ch
    uint8_t pcm[LDACBT_ENC_LSU * 2 * 4], out[1024];
    uint64_t totalFrames = 0, consumed = 0;
    NSUInteger pos = 0;
    double t = nowSec();
    for (;;) {
        BOOL eof = pos >= dataLen;
        if (!eof) {
            NSUInteger n = MIN((NSUInteger)blk, dataLen - pos);
            memcpy(pcm, b + dataOff + pos, n);
            if (n < blk) memset(pcm + n, 0, blk - n);
        }
        int used = 0, wrote = 0, fn = 0;
        if (ldacBT_encode(h, eof ? NULL : pcm, &used, out, &wrote, &fn) != 0) {
            NSLog(@"ldac encode error %d", ldacBT_get_error_code(h)); break;
        }
        pos += used; consumed += used / (2 * kWL);
        if (wrote > 0) {
            NSMutableData *p = [NSMutableData dataWithCapacity:wrote + 1];
            uint8_t hdr = fn & 0x0f;
            [p appendBytes:&hdr length:1];
            [p appendBytes:out length:wrote];
            [self.packets addObject:p];
            [self.frames addObject:@(fn)];
            totalFrames += fn;
        }
        if (eof && wrote <= 0) break;
    }
    ldacBT_free_handle(h);
    self.samplesPerFrame = totalFrames ? (double)consumed / totalFrames : 256;
    NSLog(@"encoded %lu packets, %llu frames, %.1f samples/frame, %.1fs audio in %.2fs (%.0f kbps)",
          (unsigned long)self.packets.count, totalFrames, self.samplesPerFrame,
          consumed / (double)kSF, nowSec() - t,
          [[self.packets valueForKeyPath:@"@sum.length"] doubleValue] * 8 / (consumed / (double)kSF) / 1000);
    return self.packets.count > 0;
}

- (void)sendSig:(uint8_t)sig payload:(const uint8_t *)p len:(size_t)n {
    _label = (_label + 1) & 0x0f;
    uint8_t buf[64] = { (uint8_t)(_label << 4), sig };
    memcpy(buf + 2, p, n);
    [self.sig write:buf len:n + 2];
    NSLog(@"tx sig %d: %@", sig, hex(buf, n + 2));
}

- (void)openSignalingOn:(IOBluetoothDevice *)d {
    self.dev = d;
    self.peer = (CBClassicPeerShim *)[d classicPeer];
    __weak Player *weakSelf = self;
    [self.peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
        Player *me = weakSelf;
        dispatch_async(dispatch_get_main_queue(), ^{ [me channelOpened:ch code:code]; });
    }];
    [self.peer openL2CAPChannel:0x19];
    NSLog(@"opening signaling channel...");
}

// The sink holds one AVDTP session. If macOS already owns it (A2DP up), drop the baseband link and
// reconnect: our open fires from the connect notification, ~250 ms before bluetoothd retries A2DP.
- (void)start {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:kAddr];
    BOOL systemA2DP = NO;
    for (IOBluetoothSDPServiceRecord *r in d.services)
        if ([r hasServiceFromArray:@[ [IOBluetoothSDPUUID uuid16:0x110B] ]] && d.isConnected) systemA2DP = YES;
    if (d.isConnected && !systemA2DP) { [self openSignalingOn:d]; return; }
    NSLog(@"%@ — taking over: reconnecting baseband", d.isConnected ? @"macOS owns A2DP" : @"not connected");
    if (d.isConnected) [d closeConnection];
    // Ask for the L2CAP channel while the link is down: bluetoothd brings the ACL up and sends our
    // connect request first, before its own A2DP logic kicks in.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSLog(@"link down: %d — requesting AVDTP channel", !d.isConnected);
        [self openSignalingOn:d];
    });
}

- (void)connected:(IOBluetoothUserNotification *)n device:(IOBluetoothDevice *)d {
    NSString *addr = [[d.addressString lowercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    if (self.sig || ![addr isEqualToString:kAddr]) return;
    if (self.peer) return;
    NSLog(@"headphones connected — grabbing AVDTP");
    [self openSignalingOn:d];
}

- (void)connectionComplete:(IOBluetoothDevice *)d status:(IOReturn)st {
    NSLog(@"baseband connect status 0x%x", st);
    if (st == kIOReturnSuccess && !self.peer) { NSLog(@"grabbing AVDTP from connectionComplete"); [self openSignalingOn:d]; }
}

- (void)channelOpened:(CBL2CAPChannel *)ch code:(long)code {
    if (!ch) {
        // after a baseband drop the sink needs a few seconds before it answers paging again
        if (!self.sig && ++_retries <= 8) {
            NSLog(@"channel open failed (code %ld) — retry %d in 2 s", code, _retries);
            self.peer = nil;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self openSignalingOn:[IOBluetoothDevice deviceWithAddressString:kAddr]];
            });
            return;
        }
        NSLog(@"channel open failed, code %ld", code); exit(2);
    }
    __weak Player *weakSelf = self;
    if (!self.sig) {
        self.sig = [[Chan alloc] initWith:ch name:@"sig"];
        self.sig.onData = ^(const uint8_t *b, size_t n) { [weakSelf handleSig:b len:n]; };
        self.sig.onClose = ^{ NSLog(@"signaling closed"); exit(1); };
        NSLog(@"signaling open, outMTU=%@", [ch valueForKey:@"outgoingMTU"]);
        [self sendSig:SIG_DISCOVER payload:NULL len:0];
    }
}

// bluetoothd allows one channel per PSM per client session, so the transport channel is opened by a
// helper process (second session) which hands us its socket over a unix socket with SCM_RIGHTS.
- (void)spawnHelper {
    self.sockPath = [NSString stringWithFormat:@"/tmp/ldacplay-%d.sock", getpid()];
    unlink(self.sockPath.fileSystemRepresentation);
    self.listenFD = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    strlcpy(a.sun_path, self.sockPath.fileSystemRepresentation, sizeof a.sun_path);
    if (bind(self.listenFD, (struct sockaddr *)&a, sizeof a) || listen(self.listenFD, 1)) { perror("bind"); exit(6); }
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
    t.arguments = @[ @"--transport", self.sockPath ];
    t.standardInput = [NSPipe pipe];
    t.terminationHandler = ^(NSTask *task) { NSLog(@"helper exited (%d)", task.terminationStatus); };
    NSError *err;
    if (![t launchAndReturnError:&err]) { NSLog(@"spawn failed: %@", err); exit(6); }
    self.helper = t;
}

- (void)requestTransport {
    [((NSPipe *)self.helper.standardInput).fileHandleForWriting writeData:[@"OPEN\n" dataUsingEncoding:NSUTF8StringEncoding]];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        int c = accept(self.listenFD, NULL, NULL);
        char buf[16]; struct iovec iov = { buf, sizeof buf };
        char cmsgbuf[CMSG_SPACE(sizeof(int))];
        struct msghdr m = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cmsgbuf, .msg_controllen = sizeof cmsgbuf };
        int fd = -1;
        if (recvmsg(c, &m, 0) > 0) {
            struct cmsghdr *h = CMSG_FIRSTHDR(&m);
            if (h && h->cmsg_type == SCM_RIGHTS) memcpy(&fd, CMSG_DATA(h), sizeof fd);
        }
        close(c);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (fd < 0) { NSLog(@"helper failed to open transport channel"); exit(2); }
            self.mediaFD = fd;
            NSLog(@"transport open (fd %d from helper)", fd);
            uint8_t p = self->_acp << 2;
            [self sendSig:SIG_START payload:&p len:1];
        });
    });
}

// helper role: open PSM 0x19 on the already-connected device and ship the socket to the parent
+ (void)runTransportHelper:(NSString *)sockPath {
    (void)IOBluetoothDevice.pairedDevices;
    IOBluetoothDevice *dev = [IOBluetoothDevice deviceWithAddressString:kAddr];
    __block CBL2CAPChannel *keep = nil;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        char line[64];
        if (!fgets(line, sizeof line, stdin)) exit(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            CBClassicPeerShim *peer = (CBClassicPeerShim *)[dev classicPeer];
            [peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
                int fd = ch ? [[ch valueForKey:@"socketFD"] intValue] : -1;
                keep = ch;
                int c = socket(AF_UNIX, SOCK_STREAM, 0);
                struct sockaddr_un a = { .sun_family = AF_UNIX };
                strlcpy(a.sun_path, sockPath.fileSystemRepresentation, sizeof a.sun_path);
                if (connect(c, (struct sockaddr *)&a, sizeof a)) { perror("connect"); exit(6); }
                char byte = fd >= 0 ? 1 : 0; struct iovec iov = { &byte, 1 };
                char cmsgbuf[CMSG_SPACE(sizeof(int))] = {0};
                struct msghdr m = { .msg_iov = &iov, .msg_iovlen = 1 };
                if (fd >= 0) {
                    m.msg_control = cmsgbuf; m.msg_controllen = sizeof cmsgbuf;
                    struct cmsghdr *h = CMSG_FIRSTHDR(&m);
                    h->cmsg_level = SOL_SOCKET; h->cmsg_type = SCM_RIGHTS; h->cmsg_len = CMSG_LEN(sizeof(int));
                    memcpy(CMSG_DATA(h), &fd, sizeof fd);
                }
                if (sendmsg(c, &m, 0) < 0) perror("sendmsg");
                close(c);
                if (fd < 0) { NSLog(@"[helper] open failed, code %ld", code); exit(2); }
                NSLog(@"[helper] transport channel open, fd %d handed over", fd);
            }];
            [peer openL2CAPChannel:0x19];
        });
        while (fgets(line, sizeof line, stdin)) {}
        exit(0);                                   // parent went away
    });
    [[NSRunLoop mainRunLoop] run];
}

- (void)handleSig:(const uint8_t *)b len:(size_t)n {
    NSLog(@"rx sig: %@", hex(b, n));
    if (n < 2) return;
    uint8_t msgType = b[0] & 3, sig = b[1] & 0x3f;
    if (msgType == 0) {                            // command from sink: accept it
        uint8_t rsp[2] = { (uint8_t)((b[0] & 0xf0) | 2), sig };
        [self.sig write:rsp len:2];
        return;
    }
    if (msgType != 2) {                            // stray rejects show up when bluetoothd retries its own A2DP; ignore
        NSLog(@"sink rejected signal %d (error 0x%02x)%@", sig, n > 2 ? b[n - 1] : 0, _timer ? @" — ignoring, still streaming" : @"");
        if (!_timer) exit(5);
        return;
    }

    switch (sig) {
    case SIG_DISCOVER:
        _sinks = [NSMutableArray array];
        for (size_t i = 2; i + 1 < n; i += 2)
            if (!((b[i] >> 1) & 1) && ((b[i + 1] >> 3) & 1)) [_sinks addObject:@(b[i] >> 2)];
        _capIdx = 0;
        [self queryNextCap];
        break;
    case SIG_GET_CAP:
        for (size_t i = 2; i + 1 < n;) {
            uint8_t cat = b[i], len = b[i + 1];
            if (cat == 7 && len >= 8 && b[i + 3] == 0xff && b[i + 4] == 0x2d && b[i + 5] == 0x01 &&
                b[i + 8] == 0xaa && b[i + 9] == 0x00) {
                _acp = [_sinks[_capIdx - 1] unsignedCharValue];
                NSLog(@"LDAC endpoint seid=%d caps sf=0x%02x cm=0x%02x", _acp, b[i + 10], b[i + 11]);
                uint8_t conf[] = { (uint8_t)(_acp << 2), 1 << 2,
                                   0x01, 0x00,                                  // media transport
                                   0x07, 0x0a, 0x00, 0xff, 0x2d, 0x01, 0x00, 0x00, 0xaa, 0x00,
                                   kSFBit, LDACBT_CHANNEL_MODE_STEREO };
                [self sendSig:SIG_SET_CONF payload:conf len:sizeof conf];
                return;
            }
            i += 2 + len;
        }
        [self queryNextCap];
        break;
    case SIG_SET_CONF: {
        uint8_t p = _acp << 2;
        [self sendSig:SIG_OPEN payload:&p len:1];
        break;
    }
    case SIG_OPEN:
        NSLog(@"opening transport channel via helper...");
        [self requestTransport];
        break;
    case SIG_START:
        NSLog(@"STREAMING — LDAC %d Hz stereo, EQMID HQ", kSF);
        [self startStreaming];
        break;
    case SIG_CLOSE:
        NSLog(@"closed cleanly");
        close(self.mediaFD); [self.helper terminate]; [self.sig close]; unlink(self.sockPath.fileSystemRepresentation);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ exit(0); });
        break;
    }
}

- (void)queryNextCap {
    if (_capIdx >= _sinks.count) { NSLog(@"no LDAC endpoint found"); exit(4); }
    uint8_t p = [_sinks[_capIdx++] unsignedCharValue] << 2;
    [self sendSig:SIG_GET_CAP payload:&p len:1];
}

- (void)startStreaming {
    _t0 = nowSec();
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 4 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    __weak Player *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf pump]; });
    dispatch_resume(_timer);
}

- (void)pump {
    const double lead = 0.25;                      // keep ~250 ms of audio in flight
    double elapsed = nowSec() - _t0;
    BOOL done = _next >= self.packets.count || (self.limitSec > 0 && elapsed > self.limitSec);
    if (done) {
        dispatch_source_cancel(_timer);
        uint8_t p = _acp << 2;
        [self sendSig:SIG_CLOSE payload:&p len:1];
        return;
    }
    while (_next < self.packets.count && _sentFrames * self.samplesPerFrame / kSF < elapsed + lead) {
        NSData *payload = self.packets[_next];
        uint32_t ts = (uint32_t)(_sentFrames * self.samplesPerFrame);
        uint8_t pkt[1100] = { 0x80, 0x60, (uint8_t)(_seq >> 8), (uint8_t)_seq,
                              (uint8_t)(ts >> 24), (uint8_t)(ts >> 16), (uint8_t)(ts >> 8), (uint8_t)ts,
                              0, 0, 0, 1 };
        memcpy(pkt + 12, payload.bytes, payload.length);
        ssize_t w = write(self.mediaFD, pkt, 12 + payload.length);
        if (w != (ssize_t)(12 + payload.length)) { NSLog(@"media write %zd/%zu (errno %d)", w, 12 + payload.length, errno); if (w < 0) return; }
        _seq++;
        _sentFrames += [self.frames[_next] unsignedLongLongValue];
        _next++;
        if (_next % 500 == 0) NSLog(@"played %.1fs (packet %lu, %.1fs wall)",
                                    _sentFrames * self.samplesPerFrame / kSF, (unsigned long)_next, elapsed);
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: ldacplay <wav> [seconds]\n"); return 1; }
        setvbuf(stdout, NULL, _IONBF, 0);
        if (!strcmp(argv[1], "--transport")) { [Player runTransportHelper:@(argv[2])]; return 0; }
        Player *p = [Player new];
        [p spawnHelper];
        p.limitSec = argc > 2 ? atof(argv[2]) : 0;
        if (![p encodeWav:@(argv[1])]) return 1;
        (void)IOBluetoothDevice.pairedDevices;                       // warm up the IOBluetooth/CoreBluetooth bridge
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [p start]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(3); });
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
