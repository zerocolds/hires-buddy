#import <XCTest/XCTest.h>
#include <fcntl.h>
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
@property(copy, nullable) void (^onState)(HBAVDTPSession *s, HBSessionState state);
@property int transportFDAtCallback;
@property BOOL transportFDOpenAtCallback;
@end

@implementation HBSessionRecorder
- (instancetype)init { if ((self = [super init])) _states = [NSMutableArray array]; return self; }
- (void)session:(HBAVDTPSession *)s didChangeState:(HBSessionState)state error:(NSError *)err {
    [self.states addObject:@(state)];
    if (err) self.lastError = err;
    self.transportFDAtCallback = s.transportFD;
    self.transportFDOpenAtCallback = s.transportFD >= 0 && fcntl(s.transportFD, F_GETFD) != -1;
    if (self.onState) self.onState(s, state);
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
    // still usable while the delegate hears about it, closed right after
    XCTAssertEqual(_recorder.transportFDAtCallback, _providedFD);
    XCTAssertTrue(_recorder.transportFDOpenAtCallback);
    XCTAssertEqual(_session.transportFD, -1);
    XCTAssertEqual(fcntl(_providedFD, F_GETFD), -1);
}

- (void)testSinkCloseWhileStreamingFails {
    [self driveToStreaming];
    [_fake reply:HEX(@"00 08 0c")];
    XCTAssertEqualObjects(_fake.sent.lastObject, HEX(@"02 08"));
    XCTAssertEqual(_session.state, HBSessionFailed);
    XCTAssertEqual(_recorder.lastError.code, HBErrorSinkDisconnected);
}

- (void)testSinkSuspendAndStartAreApplied {
    [self driveToStreaming];
    [_fake reply:HEX(@"00 09 0c")];
    XCTAssertEqual(_session.state, HBSessionSuspended);
    [_fake reply:HEX(@"10 07 0c")];
    XCTAssertEqual(_session.state, HBSessionStreaming);
    XCTAssertEqualObjects(_fake.sent.lastObject, HEX(@"12 07"));
}

- (void)testResponsesWithWrongLabelAreIgnored {
    [_session startWithSampleRateBit:0x10];               // DISCOVER goes out with label 1
    [_fake reply:HEX(@"52 01 04 08 08 08")];               // accept, label 5
    XCTAssertEqual(_fake.sent.count, 1);
    [_fake reply:HEX(@"53 01 31")];                        // reject, label 5
    XCTAssertEqual(_session.state, HBSessionConnecting);
    XCTAssertNil(_recorder.lastError);
    [_fake reply:HEX(@"12 01 04 08 08 08")];
    XCTAssertEqual(SignalOf(_fake.sent.lastObject), HBAVDTPGetCapabilities);
}

- (void)testStopInsideConnectingCallbackHaltsSetup {
    __block int restored = 0;
    _session.restoreHook = ^{ restored++; };
    _recorder.onState = ^(HBAVDTPSession *s, HBSessionState state) {
        if (state == HBSessionConnecting) [s stopAndRestoreSystemAudio];
    };
    [_session startWithSampleRateBit:0x10];
    XCTAssertEqual(_fake.sent.count, 0);
    XCTAssertEqual(_session.state, HBSessionClosed);
    XCTAssertEqual(restored, 1);
}

- (void)testSilentSinkTimesOut {
    _session.transactionTimeout = 0.05;
    [_session startWithSampleRateBit:0x10];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (_session.state == HBSessionConnecting && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    XCTAssertEqual(_session.state, HBSessionFailed);
    XCTAssertEqual(_recorder.lastError.code, HBErrorTimeout);
}

- (void)testLDACEndpointWithoutRequestedRateIsSkipped {
    [_session startWithSampleRateBit:0x02];               // 176.4 kHz: the XM4's LDAC caps (0x3c) lack it
    [self replyDiscoverAndCaps:YES];
    for (NSString *label in @[ @"5", @"6", @"7" ])         // endpoints 4..6: SBC only
        [_fake reply:HEX([label stringByAppendingString:@"2 02 01 00 07 06 00 00 ff ff 02 35"])];
    XCTAssertEqual(_session.state, HBSessionFailed);
    XCTAssertEqual(_recorder.lastError.code, HBErrorNoLDAC);
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

#pragma mark - Signaling open attempts (test opener; paging/takeover need hardware)

/// A fake signaling channel on a fresh socketpair; the peer end goes into `peers` for tearDown-free cleanup.
- (HBFakeSignalingChannel *)newFakeChannelKeepingPeerIn:(NSMutableArray<NSNumber *> *)peers {
    int sv[2];
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0);
    [peers addObject:@(sv[1])];
    return [[HBFakeSignalingChannel alloc] initWithSocketFD:sv[0] name:@"fake-sig-2"];
}

- (void)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

- (void)testSignalingOpenTimesOutAndRetries {
    NSMutableArray<NSNumber *> *peers = [NSMutableArray array];
    HBFakeSignalingChannel *second = [self newFakeChannelKeepingPeerIn:peers];
    HBFakeSignalingChannel *late = [self newFakeChannelKeepingPeerIn:peers];
    NSMutableArray *completions = [NSMutableArray array];
    HBAVDTPSession *s = [[HBAVDTPSession alloc] initWithSignalingOpener:^(void (^done)(HBL2CAPChannel *, NSInteger)) {
        [completions addObject:[done copy]];
        if (completions.count == 2) done(second, 0);       // the first attempt never calls back
    } transportProvider:^(void (^done)(int)) { done(-1); }];
    s.signalingOpenTimeout = 0.1;
    s.openRetryInterval = 0.05;
    HBSessionRecorder *rec = [HBSessionRecorder new];
    s.delegate = rec;

    [s startWithSampleRateBit:0x10];
    XCTAssertEqual(completions.count, 1u);
    [self spinUntil:^BOOL { return second.sent.count > 0; } timeout:2];
    XCTAssertEqual(completions.count, 2u, @"a second attempt follows the first one's deadline");
    XCTAssertEqual(SignalOf(second.sent.lastObject), HBAVDTPDiscover);

    // the first attempt's channel shows up after its deadline: closed and ignored
    ((void (^)(HBL2CAPChannel *, NSInteger))completions[0])(late, 0);
    XCTAssertEqual(late.socketFD, -1);
    XCTAssertEqual(late.sent.count, 0u);
    XCTAssertEqualObjects(rec.states, @[ @(HBSessionConnecting) ]);

    s = nil;
    for (NSNumber *fd in peers) close(fd.intValue);
}

- (void)testOpenAttemptsExhaustedFails {
    __block int calls = 0;
    HBAVDTPSession *s = [[HBAVDTPSession alloc] initWithSignalingOpener:^(void (^done)(HBL2CAPChannel *, NSInteger)) {
        if (++calls == 2) done(nil, 5);                    // one explicit failure, the others never call back
    } transportProvider:^(void (^done)(int)) { done(-1); }];
    s.signalingOpenTimeout = 0.05;
    s.openRetryInterval = 0.02;
    s.maxOpenAttempts = 3;
    HBSessionRecorder *rec = [HBSessionRecorder new];
    s.delegate = rec;
    NSMutableArray<NSString *> *logged = [NSMutableArray array];
    s.logHandler = ^(NSString *m) { [logged addObject:m]; };

    [s startWithSampleRateBit:0x10];
    [self spinUntil:^BOOL { return s.state == HBSessionFailed; } timeout:2];
    XCTAssertEqual(calls, 3);
    XCTAssertEqualObjects(rec.states, (@[ @(HBSessionConnecting), @(HBSessionFailed) ]));
    XCTAssertEqualObjects(rec.lastError.domain, HBErrorDomain);
    XCTAssertEqual(rec.lastError.code, HBErrorChannelOpenFailed);
    XCTAssertGreaterThanOrEqual(logged.count, 3u, @"each attempt is reported through logHandler");
}

#pragma mark - Negotiation retry after a setup reject

/// Answers the channel's last command (same label) with `type` (2 accept, 3 reject) and `rest` hex bytes.
static void Answer(HBFakeSignalingChannel *ch, uint8_t type, NSString *rest) {
    const uint8_t *last = ch.sent.lastObject.bytes;
    NSMutableData *msg = [NSMutableData dataWithBytes:(uint8_t[]){ (uint8_t)((last[0] & 0xf0) | type), last[1] } length:2];
    [msg appendData:HEX(rest)];
    [ch reply:msg];
}

/// DISCOVER → GET_CAPABILITIES (LDAC on the first queried endpoint) → SET_CONFIGURATION accepted; OPEN is sent.
- (void)negotiateUpToOpenOn:(HBFakeSignalingChannel *)ch {
    XCTAssertEqual(SignalOf(ch.sent.lastObject), HBAVDTPDiscover);
    Answer(ch, 2, @"0c 08");                                         // one free sink, seid 3
    XCTAssertEqual(SignalOf(ch.sent.lastObject), HBAVDTPGetCapabilities);
    Answer(ch, 2, @"01 00 07 0a 00 ff 2d 01 00 00 aa 00 3c 07 04 02 02 00");
    XCTAssertEqual(SignalOf(ch.sent.lastObject), HBAVDTPSetConfiguration);
    Answer(ch, 2, @"");
    XCTAssertEqualObjects(ch.sent.lastObject.length ? [ch.sent.lastObject subdataWithRange:NSMakeRange(1, 2)] : nil,
                          HEX(@"06 0c"));
}

- (HBAVDTPSession *)sessionOpeningChannels:(NSArray<HBFakeSignalingChannel *> *)channels opens:(int *)opens {
    __block int n = 0;
    int *counter = opens;
    HBAVDTPSession *s = [[HBAVDTPSession alloc] initWithSignalingOpener:^(void (^done)(HBL2CAPChannel *, NSInteger)) {
        HBFakeSignalingChannel *ch = n < (int)channels.count ? channels[n] : nil;
        n++;
        if (counter) *counter = n;
        done(ch, ch ? 0 : 5);
    } transportProvider:^(void (^done)(int)) {
        int tv[2];
        socketpair(AF_UNIX, SOCK_STREAM, 0, tv);
        close(tv[1]);
        done(tv[0]);
    }];
    s.negotiationRetryInterval = 0.05;
    return s;
}

- (void)testOpenRejectedWithBadStateRetriesNegotiation {
    NSMutableArray<NSNumber *> *peers = [NSMutableArray array];
    HBFakeSignalingChannel *first = [self newFakeChannelKeepingPeerIn:peers];
    HBFakeSignalingChannel *second = [self newFakeChannelKeepingPeerIn:peers];
    int opens = 0;
    HBAVDTPSession *s = [self sessionOpeningChannels:@[ first, second ] opens:&opens];
    HBSessionRecorder *rec = [HBSessionRecorder new];
    s.delegate = rec;

    [s startWithSampleRateBit:0x10];
    [self negotiateUpToOpenOn:first];
    Answer(first, 3, @"31");                                          // OPEN rejected: BAD_STATE
    XCTAssertEqual(SignalOf(first.sent.lastObject), HBAVDTPAbort, @"the configured stream is aborted");
    XCTAssertEqualObjects([first.sent.lastObject subdataWithRange:NSMakeRange(2, 1)], HEX(@"0c"));
    XCTAssertEqual(first.socketFD, -1, @"the signaling channel is closed");
    XCTAssertNotEqual(s.state, HBSessionFailed);
    XCTAssertEqual(opens, 1, @"the reopen waits for the retry delay");

    [self spinUntil:^BOOL { return second.sent.count > 0; } timeout:2];
    XCTAssertEqual(opens, 2);
    [self negotiateUpToOpenOn:second];
    Answer(second, 2, @"");                                           // OPEN accepted → transport → START
    XCTAssertEqual(SignalOf(second.sent.lastObject), HBAVDTPStart);
    Answer(second, 2, @"");
    XCTAssertEqual(s.state, HBSessionStreaming);
    XCTAssertNil(rec.lastError);
    XCTAssertEqualObjects(rec.states, (@[ @(HBSessionConnecting), @(HBSessionConfigured), @(HBSessionConnecting),
                                          @(HBSessionConfigured), @(HBSessionStreaming) ]));
    s = nil;
    for (NSNumber *fd in peers) close(fd.intValue);
}

- (void)testSetupRejectsBeyondRetryLimitFail {
    NSMutableArray<NSNumber *> *peers = [NSMutableArray array];
    HBFakeSignalingChannel *first = [self newFakeChannelKeepingPeerIn:peers];
    HBFakeSignalingChannel *second = [self newFakeChannelKeepingPeerIn:peers];
    HBAVDTPSession *s = [self sessionOpeningChannels:@[ first, second ] opens:NULL];
    s.maxNegotiationRetries = 1;
    HBSessionRecorder *rec = [HBSessionRecorder new];
    s.delegate = rec;

    [s startWithSampleRateBit:0x10];
    [self negotiateUpToOpenOn:first];
    Answer(first, 3, @"31");
    [self spinUntil:^BOOL { return second.sent.count > 0; } timeout:2];
    [self negotiateUpToOpenOn:second];
    Answer(second, 3, @"31");
    XCTAssertEqual(s.state, HBSessionFailed);
    XCTAssertEqual(rec.lastError.code, HBErrorSinkRejected);
    s = nil;
    for (NSNumber *fd in peers) close(fd.intValue);
}

- (void)testSetupRejectWithoutWayToReopenFails {
    [_session startWithSampleRateBit:0x10];
    [self replyDiscoverAndCaps:YES];
    [_fake reply:HEX(@"53 03 31")];                                   // SET_CONFIGURATION rejected
    XCTAssertEqual(_session.state, HBSessionFailed);
    XCTAssertEqual(_recorder.lastError.code, HBErrorSinkRejected);
}

@end
