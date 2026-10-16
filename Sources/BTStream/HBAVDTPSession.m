#import "BTStream.h"
#include <os/log.h>
#include <unistd.h>

@interface HBAVDTPSession () <HBL2CAPChannelDelegate>
@end

NSErrorDomain const HBErrorDomain = @"HBErrorDomain";

// os_log rather than NSLog: visible in Console / `log stream --predicate 'subsystem == "HiResBuddy"'`, quiet in tests.
static os_log_t HBLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("HiResBuddy", "avdtp"); });
    return log;
}
#define HBLOG(fmt, ...) os_log(HBLog(), "%{public}@", [NSString stringWithFormat:fmt, ##__VA_ARGS__])

static const uint16_t kAVDTPPSM = 0x19;
static const uint8_t kIntSEID = 1;
static const uint8_t kLDACChannelModeStereo = 0x01;
static const uint8_t kMsgCommand = 0, kMsgAccept = 2;
static const int kOpenRetries = 8;
static const int64_t kTakeoverDelay = 1500 * NSEC_PER_MSEC;   // baseband drop before asking for the channel
static const int64_t kRetryDelay = 2 * NSEC_PER_SEC;          // the sink needs seconds to answer paging after a drop
static const int64_t kReconnectDelay = 1500 * NSEC_PER_MSEC;
static const int64_t kStopStepTimeout = NSEC_PER_SEC;

@implementation HBAVDTPSession {
    IOBluetoothDevice *_dev;                    // nil for the test init
    HBTransportHelperClient *_helper;
    void (^_transportProvider)(void (^)(int fd));
    HBL2CAPChannel *_sig;
    uint8_t _label;
    uint8_t _sfBit;
    NSMutableArray<HBAVDTPEndpoint *> *_sinks;  // free sink endpoints still to query
    uint8_t _acp;                               // the sink's LDAC seid
    HBAVDTPSignal _pending;                     // command we wait an accept for; 0 = none
    int _retries;
    NSUInteger _epoch;                          // bumped on stop/failure: stale timers and callbacks bail out
    BOOL _stopping;
}

- (instancetype)initWithDevice:(IOBluetoothDevice *)dev helper:(HBTransportHelperClient *)helper {
    if (!(self = [super init])) return nil;
    _dev = dev;
    _helper = helper;
    _transportFD = -1;
    NSString *addr = dev.addressString;
    _transportProvider = ^(void (^done)(int)) {
        [helper openTransportForAddress:addr psm:kAVDTPPSM completion:^(int fd, NSInteger code) {
            if (fd < 0) HBLOG(@"transport helper failed, code %ld", (long)code);
            done(fd);
        }];
    };
    _restoreHook = ^{
        // Dropping and re-paging the link makes bluetoothd set its own A2DP up again.
        [dev closeConnection];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kReconnectDelay), dispatch_get_main_queue(), ^{
            [dev openConnection:HBAVDTPSession.class];
        });
    };
    return self;
}

- (instancetype)initWithSignalingChannel:(HBL2CAPChannel *)sig transportProvider:(void (^)(void (^)(int)))provider {
    if (!(self = [super init])) return nil;
    _transportFD = -1;
    _transportProvider = [provider copy];
    [self adoptSignaling:sig];
    return self;
}

- (void)dealloc {
    _sig.delegate = nil;
    [_sig close];
    if (_transportFD >= 0) close(_transportFD);
}

// Target for the restore hook's asynchronous openConnection: (a class object outlives any session).
+ (void)connectionComplete:(IOBluetoothDevice *)dev status:(IOReturn)status {
    HBLOG(@"reconnect for system audio: status 0x%x", status);
}

#pragma mark - State

- (void)setState:(HBSessionState)state error:(NSError *)err {
    if (_state == state && !err) return;
    _state = state;
    void (^notify)(void) = ^{ [self.delegate session:self didChangeState:state error:err]; };
    if (NSThread.isMainThread) notify(); else dispatch_async(dispatch_get_main_queue(), notify);
}

- (void)failWithCode:(HBSessionError)code message:(NSString *)msg {
    HBLOG(@"failed: %@", msg);
    [self tearDown];
    [self setState:HBSessionFailed error:[NSError errorWithDomain:HBErrorDomain code:code
                                                         userInfo:@{ NSLocalizedDescriptionKey: msg }]];
}

- (void)tearDown {
    _epoch++;
    _pending = 0;
    _sig.delegate = nil;
    [_sig close];
    _sig = nil;
    if (_transportFD >= 0) close(_transportFD);
    _transportFD = -1;
    [_helper terminate];
}

- (BOOL)isFinished { return _state == HBSessionClosed || _state == HBSessionFailed; }

#pragma mark - Signaling

- (BOOL)send:(HBAVDTPSignal)sig payload:(NSData *)payload {
    _label = (_label + 1) & 0x0f;
    _pending = sig;
    return [_sig write:[HBAVDTP command:sig label:_label payload:payload]];
}

- (NSData *)acpPayload {
    uint8_t p = (uint8_t)(_acp << 2);
    return [NSData dataWithBytes:&p length:1];
}

- (void)adoptSignaling:(HBL2CAPChannel *)ch {
    _sig = ch;
    _sig.delegate = self;
}

#pragma mark - Start

- (void)startWithSampleRateBit:(uint8_t)sfBit {
    if (_state != HBSessionIdle) { HBLOG(@"start ignored in state %ld", (long)_state); return; }
    _sfBit = sfBit;
    [self setState:HBSessionConnecting error:nil];
    if (_sig) { [self send:HBAVDTPDiscover payload:nil]; return; }
    if (!_dev.isConnected) { [self openSignaling]; return; }   // bluetoothd brings the ACL up for our request
    // The sink holds one AVDTP session and macOS owns it: drop the baseband link and ask for the channel while
    // it is down, so our connect request goes out before bluetoothd's own A2DP logic.
    HBLOG(@"taking over: dropping the baseband link");
    [_dev closeConnection];
    [self after:kTakeoverDelay do:^(HBAVDTPSession *me) { [me openSignaling]; }];
}

/// Runs `block` on the main queue after `delay` unless the session was stopped/failed or released meanwhile.
- (void)after:(int64_t)delay do:(void (^)(HBAVDTPSession *me))block {
    NSUInteger epoch = _epoch;
    __weak HBAVDTPSession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
        HBAVDTPSession *me = weakSelf;
        if (me && me->_epoch == epoch) block(me);
    });
}

- (void)openSignaling {
    NSUInteger epoch = _epoch;
    __weak HBAVDTPSession *weakSelf = self;
    [HBL2CAPChannel openPSM:kAVDTPPSM onDevice:_dev completion:^(HBL2CAPChannel *ch, NSInteger code) {
        HBAVDTPSession *me = weakSelf;
        if (!me || me->_epoch != epoch) { [ch close]; return; }
        [me signalingOpened:ch code:code];
    }];
}

- (void)signalingOpened:(HBL2CAPChannel *)ch code:(NSInteger)code {
    if (!ch) {
        if (++_retries <= kOpenRetries) {
            HBLOG(@"signaling open failed (code %ld), retry %d in 2 s", (long)code, _retries);
            [self after:kRetryDelay do:^(HBAVDTPSession *me) { [me openSignaling]; }];
        } else {
            [self failWithCode:HBErrorChannelOpenFailed
                       message:[NSString stringWithFormat:@"signaling channel open failed (code %ld)", (long)code]];
        }
        return;
    }
    [self adoptSignaling:ch];
    [self send:HBAVDTPDiscover payload:nil];
}

- (void)queryNextCapabilities {
    if (_sinks.count == 0) { [self failWithCode:HBErrorNoLDAC message:@"no sink endpoint supports LDAC"]; return; }
    uint8_t p = (uint8_t)(_sinks.firstObject.seid << 2);
    _acp = _sinks.firstObject.seid;
    [_sinks removeObjectAtIndex:0];
    [self send:HBAVDTPGetCapabilities payload:[NSData dataWithBytes:&p length:1]];
}

- (void)requestTransport {
    NSUInteger epoch = _epoch;
    __weak HBAVDTPSession *weakSelf = self;
    _transportProvider(^(int fd) {
        HBAVDTPSession *me = weakSelf;
        if (!me || me->_epoch != epoch) { if (fd >= 0) close(fd); return; }
        [me transportOpened:fd];
    });
}

- (void)transportOpened:(int)fd {
    if (fd < 0) { [self failWithCode:HBErrorTransportFailed message:@"transport channel could not be opened"]; return; }
    _transportFD = fd;
    [self send:HBAVDTPStart payload:self.acpPayload];
}

#pragma mark - HBL2CAPChannelDelegate

- (void)channel:(HBL2CAPChannel *)c didReceive:(NSData *)msg {
    uint8_t type = 0;
    HBAVDTPSignal sig = 0;
    // One socket read is taken as one message (as in the prototype); anything shorter than a header is dropped.
    if (![HBAVDTP parseHeader:msg label:NULL messageType:&type signal:&sig]) return;
    if (type == kMsgCommand) {                    // e.g. Delay Report from the sink
        [c write:[HBAVDTP acceptResponseForCommand:msg]];
        return;
    }
    if (_stopping) {                              // accept or reject: either way the step is over
        if (sig == _pending) [self stopStepDone];
        return;
    }
    if (type != kMsgAccept) {
        uint8_t errCode = msg.length > 2 ? ((const uint8_t *)msg.bytes)[msg.length - 1] : 0;
        if (_state == HBSessionConnecting || _state == HBSessionConfigured) {
            [self failWithCode:HBErrorSinkRejected
                       message:[NSString stringWithFormat:@"sink rejected signal %d (error 0x%02x)", sig, errCode]];
        } else {
            // bluetoothd retries its own A2DP every ~10 s and the stray reject lands on our channel
            HBLOG(@"ignoring reject of signal %d (error 0x%02x)", sig, errCode);
            if (sig == _pending) _pending = 0;    // our SUSPEND/START was refused: allow another try
        }
        return;
    }
    if (sig != _pending) { HBLOG(@"ignoring unexpected accept of signal %d", sig); return; }
    _pending = 0;
    [self handleAccept:sig message:msg];
}

- (void)handleAccept:(HBAVDTPSignal)sig message:(NSData *)msg {
    switch (sig) {
    case HBAVDTPDiscover:
        _sinks = [NSMutableArray array];
        for (HBAVDTPEndpoint *ep in [HBAVDTP parseDiscover:msg])
            if (ep.isSink && !ep.inUse) [_sinks addObject:ep];
        [self queryNextCapabilities];
        break;
    case HBAVDTPGetCapabilities: {
        HBAVDTPEndpoint *ep = [HBAVDTPEndpoint new];
        [HBAVDTP parseCapabilities:msg into:ep];
        if (!ep.supportsLDAC) { [self queryNextCapabilities]; break; }
        HBLOG(@"LDAC endpoint seid=%d rates=0x%02x modes=0x%02x", _acp, ep.ldacSampleRates, ep.ldacChannelModes);
        [self send:HBAVDTPSetConfiguration
           payload:[HBAVDTP setConfigurationPayloadForSEID:_acp intSEID:kIntSEID ldacSampleRateBit:_sfBit
                                            channelModeBit:kLDACChannelModeStereo]];
        break;
    }
    case HBAVDTPSetConfiguration:
        _negotiatedSampleRateBit = _sfBit;
        [self setState:HBSessionConfigured error:nil];
        [self send:HBAVDTPOpen payload:self.acpPayload];
        break;
    case HBAVDTPOpen:
        [self requestTransport];
        break;
    case HBAVDTPStart:
        [self setState:HBSessionStreaming error:nil];
        break;
    case HBAVDTPSuspend:
        [self setState:HBSessionSuspended error:nil];
        break;
    default:
        break;
    }
}

- (void)channelDidClose:(HBL2CAPChannel *)c {
    if (c != _sig) return;
    _sig.delegate = nil;
    _sig = nil;
    if (_stopping) { [self stopStepDone]; return; }
    if (self.isFinished) return;
    [self failWithCode:HBErrorSinkDisconnected message:@"signaling channel closed"];
}

#pragma mark - Suspend / resume

- (void)suspend {
    if (_state != HBSessionStreaming || _stopping || _pending) return;
    [self send:HBAVDTPSuspend payload:self.acpPayload];
}

- (void)resume {
    if (_state != HBSessionSuspended || _stopping || _pending) return;
    [self send:HBAVDTPStart payload:self.acpPayload];
}

#pragma mark - Stop

- (void)stopAndRestoreSystemAudio {
    if (_stopping || _state == HBSessionIdle || _state == HBSessionClosed) return;
    BOOL streamOpen = _state == HBSessionStreaming || _state == HBSessionSuspended || _state == HBSessionConfigured;
    BOOL wasStreaming = _state == HBSessionStreaming;
    _stopping = YES;
    _epoch++;                                     // cancels pending retries and transport callbacks
    _pending = 0;
    if (!_sig || !streamOpen) [self finishStop];
    else [self stopStep:wasStreaming ? HBAVDTPSuspend : HBAVDTPClose];
}

/// Sends SUSPEND or CLOSE and waits at most kStopStepTimeout for the answer.
- (void)stopStep:(HBAVDTPSignal)sig {
    if (!_sig || ![self send:sig payload:self.acpPayload]) { _pending = sig; [self stopStepDone]; return; }
    NSUInteger epoch = ++_epoch;
    __weak HBAVDTPSession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kStopStepTimeout), dispatch_get_main_queue(), ^{
        HBAVDTPSession *me = weakSelf;
        if (me && me->_epoch == epoch) { HBLOG(@"no answer to signal %d, going on", sig); [me stopStepDone]; }
    });
}

- (void)stopStepDone {
    HBAVDTPSignal done = _pending;
    _pending = 0;
    _epoch++;                                     // the step's timeout no longer applies
    if (done == HBAVDTPSuspend) [self stopStep:HBAVDTPClose];
    else [self finishStop];
}

- (void)finishStop {
    [self tearDown];
    _stopping = NO;
    [self setState:HBSessionClosed error:nil];
    if (self.restoreHook) self.restoreHook();
}

@end
