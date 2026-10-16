#import <XCTest/XCTest.h>
#include <sys/socket.h>
#include <unistd.h>
#import "BTStream.h"

static NSData *HEX(NSString *s) {
    NSMutableData *d = [NSMutableData data];
    for (NSString *tok in [s componentsSeparatedByString:@" "]) {
        if (tok.length == 0) continue;
        uint8_t b = (uint8_t)strtoul(tok.UTF8String, NULL, 16);
        [d appendBytes:&b length:1];
    }
    return d;
}

static uint8_t SignalOf(NSData *msg) { return msg.length > 1 ? ((const uint8_t *)msg.bytes)[1] & 0x3f : 0; }

/// Signaling channel stand-in: records writes, lets the test play the sink.
@interface HBFakeSignalingChannel : HBL2CAPChannel
@property(readonly) NSMutableArray<NSData *> *sent;
- (void)reply:(NSData *)msg;
- (void)simulateClose;
@end

@implementation HBFakeSignalingChannel {
    NSMutableArray<NSData *> *_sent;
}
- (NSMutableArray<NSData *> *)sent { if (!_sent) _sent = [NSMutableArray array]; return _sent; }
- (BOOL)write:(NSData *)data { [self.sent addObject:[data copy]]; return YES; }
- (void)reply:(NSData *)msg { [self.delegate channel:self didReceive:msg]; }
- (void)simulateClose { [self close]; [self.delegate channelDidClose:self]; }
@end

@interface HBSessionRecorder : NSObject <HBAVDTPSessionDelegate>
@property(strong) NSMutableArray<NSNumber *> *states;
@property(strong, nullable) NSError *lastError;
@end

@implementation HBSessionRecorder
- (instancetype)init { if ((self = [super init])) _states = [NSMutableArray array]; return self; }
- (void)session:(HBAVDTPSession *)s didChangeState:(HBSessionState)state error:(NSError *)err {
    [self.states addObject:@(state)];
    if (err) self.lastError = err;
}
@end

@interface BTStreamTests_HBAVDTPSessionTests : XCTestCase
@end

@implementation BTStreamTests_HBAVDTPSessionTests {
    int _sigPeer, _transportPeer;
    HBFakeSignalingChannel *_fake;
    HBAVDTPSession *_session;
    HBSessionRecorder *_recorder;
    int _providedFD;
    BOOL _handedOver;               // after the provider runs, the session owns _providedFD
}

- (void)setUp {
    int sv[2], tv[2];
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0);
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, tv), 0);
    _sigPeer = sv[1];
    _transportPeer = tv[1];
    _providedFD = tv[0];
    _fake = [[HBFakeSignalingChannel alloc] initWithSocketFD:sv[0] name:@"fake-sig"];
    __weak typeof(self) weakSelf = self;
    _session = [[HBAVDTPSession alloc] initWithSignalingChannel:_fake transportProvider:^(void (^done)(int)) {
        typeof(self) me = weakSelf;
        me->_handedOver = YES;
        done(me->_providedFD);
    }];
    _recorder = [HBSessionRecorder new];
    _session.delegate = _recorder;
}

- (void)tearDown {
    _session = nil;                 // dealloc closes the transport fd it owns
    [_fake close];
    close(_sigPeer);
    close(_transportPeer);
    if (!_handedOver) close(_providedFD);
    [super tearDown];
}

// SBC, AAC and LDAC capability responses (XM4 captures, labels 2..4 as the session sends them).
- (void)replyDiscoverAndCaps:(BOOL)withLDAC {
    [_fake reply:HEX(@"12 01 04 08 08 08 0c 08 10 08 14 08 18 08")];
    XCTAssertEqual(SignalOf(_fake.sent.lastObject), HBAVDTPGetCapabilities);
    [_fake reply:HEX(@"22 02 01 00 07 06 00 00 ff ff 02 35")];
    [_fake reply:HEX(@"32 02 01 00 07 08 00 02 c0 01 8c 84 e2 00 04 02 02 00")];
    if (withLDAC) {
        [_fake reply:HEX(@"42 02 01 00 07 0a 00 ff 2d 01 00 00 aa 00 3c 07 04 02 02 00")];
    } else {
        for (NSString *label in @[ @"4", @"5", @"6", @"7" ])   // endpoints 3..6: SBC only
            [_fake reply:HEX([label stringByAppendingString:@"2 02 01 00 07 06 00 00 ff ff 02 35"])];
    }
}

- (void)driveToStreaming {
    [_session startWithSampleRateBit:0x10];
    XCTAssertEqual(SignalOf(_fake.sent.lastObject), HBAVDTPDiscover);
    [self replyDiscoverAndCaps:YES];
    NSData *conf = _fake.sent.lastObject;
    XCTAssertEqual(SignalOf(conf), HBAVDTPSetConfiguration);
    NSData *payload = [conf subdataWithRange:NSMakeRange(2, conf.length - 2)];
    XCTAssertEqualObjects(payload, [HBAVDTP setConfigurationPayloadForSEID:3 intSEID:1 ldacSampleRateBit:0x10 channelModeBit:0x01]);
    [_fake reply:HEX(@"52 03")];
    XCTAssertEqual(_session.state, HBSessionConfigured);
    XCTAssertEqualObjects(_fake.sent.lastObject, HEX(@"60 06 0c"));
    [_fake reply:HEX(@"62 06")];
    XCTAssertEqualObjects(_fake.sent.lastObject, HEX(@"70 07 0c"));
    [_fake reply:HEX(@"72 07")];
}

- (void)testHappyPathReachesStreaming {
    [self driveToStreaming];
    XCTAssertEqual(_session.state, HBSessionStreaming);
    XCTAssertEqual(((const uint8_t *)_fake.sent.lastObject.bytes)[1], HBAVDTPStart);
    XCTAssertEqual(_session.transportFD, _providedFD);
    XCTAssertEqual(_session.negotiatedSampleRateBit, 0x10);
    XCTAssertEqualObjects(_recorder.states, (@[ @(HBSessionConnecting), @(HBSessionConfigured), @(HBSessionStreaming) ]));
}

- (void)testStrayRejectWhileStreamingIsIgnored {
    [self driveToStreaming];
    NSUInteger sentBefore = _fake.sent.count;
    [_fake reply:HEX(@"73 01 31")];
    XCTAssertEqual(_session.state, HBSessionStreaming);
    XCTAssertEqual(_fake.sent.count, sentBefore);
    XCTAssertNil(_recorder.lastError);
}

- (void)testSinkCommandIsAccepted {
    [self driveToStreaming];
    [_fake reply:HEX(@"00 0d 04 00 64")];
    XCTAssertEqualObjects(_fake.sent.lastObject, HEX(@"02 0d"));
    XCTAssertEqual(_session.state, HBSessionStreaming);
}

- (void)testSinkDisconnectStopsStreamAndReports {
    [self driveToStreaming];
    [_fake simulateClose];
    XCTAssertEqual(_session.state, HBSessionFailed);
    XCTAssertEqualObjects(_recorder.lastError.domain, HBErrorDomain);
    XCTAssertEqual(_recorder.lastError.code, HBErrorSinkDisconnected);
    XCTAssertEqual(_session.transportFD, -1);
}

- (void)testStopSendsSuspendCloseAndReconnects {
    [self driveToStreaming];
    __block int restored = 0;
    _session.restoreHook = ^{ restored++; };
    [_session stopAndRestoreSystemAudio];
    XCTAssertEqual(SignalOf(_fake.sent.lastObject), HBAVDTPSuspend);
    XCTAssertEqual(restored, 0);
    [_fake reply:HEX(@"82 09")];
    XCTAssertEqual(SignalOf(_fake.sent.lastObject), HBAVDTPClose);
    [_fake reply:HEX(@"92 08")];
    XCTAssertEqual(restored, 1);
    XCTAssertEqual(_session.state, HBSessionClosed);
    XCTAssertEqual(_session.transportFD, -1);
    [_session stopAndRestoreSystemAudio];
    XCTAssertEqual(restored, 1, @"a second stop must not restore again");
}

- (void)testSuspendAndResume {
    [self driveToStreaming];
    [_session suspend];
    XCTAssertEqual(SignalOf(_fake.sent.lastObject), HBAVDTPSuspend);
    [_fake reply:HEX(@"83 09 0c 31")];                  // refused: still streaming, and a retry is allowed
    XCTAssertEqual(_session.state, HBSessionStreaming);
    [_session suspend];
    [_fake reply:HEX(@"92 09")];
    XCTAssertEqual(_session.state, HBSessionSuspended);
    [_session resume];
    XCTAssertEqual(SignalOf(_fake.sent.lastObject), HBAVDTPStart);
    [_fake reply:HEX(@"a2 07")];
    XCTAssertEqual(_session.state, HBSessionStreaming);
}

- (void)testNoLDACEndpointFails {
    [_session startWithSampleRateBit:0x10];
    [self replyDiscoverAndCaps:NO];
    XCTAssertEqual(_session.state, HBSessionFailed);
    XCTAssertEqualObjects(_recorder.lastError.domain, HBErrorDomain);
    XCTAssertEqual(_recorder.lastError.code, HBErrorNoLDAC);
}

@end
