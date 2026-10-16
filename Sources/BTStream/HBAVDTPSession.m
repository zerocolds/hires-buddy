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
/// Instance-side logging: os_log plus the session's logHandler.
#define SLOG(fmt, ...) [self log:[NSString stringWithFormat:fmt, ##__VA_ARGS__]]

static const uint16_t kAVDTPPSM = 0x19;
static const uint8_t kIntSEID = 1;
static const uint8_t kLDACChannelModeStereo = 0x01;
static const uint8_t kMsgCommand = 0, kMsgAccept = 2;
static const int64_t kTakeoverDelay = 1000 * NSEC_PER_MSEC;   // first signaling attempt after dropping the link
static const NSTimeInterval kConnectPollInterval = 0.2;        // while paging: how often isConnected is checked
static const NSTimeInterval kConnectTimeout = 10.0;            // paging deadline per attempt
static const int64_t kReconnectDelay = 1500 * NSEC_PER_MSEC;
static const NSTimeInterval kStopStepTimeout = 1.0;

static const int kLinkDownChecks = 75;                        // 15 s of 200 ms checks for the ACL to drop
static const int kReconnectPages = 3;                         // pages for system audio, including the first
static int sReconnectPagesLeft;                               // main thread only

/// Main queue: waits (up to `checksLeft` × 200 ms) for the baseband link to drop, then pages the device again
/// kReconnectDelay later. The class object is the async target: it outlives any session.
static void HBReconnectWhenDown(IOBluetoothDevice *dev, int checksLeft) {
    if (dev.isConnected && checksLeft > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            HBReconnectWhenDown(dev, checksLeft - 1);
        });
        return;
    }
    HBLOG(@"restore: link %@, reconnecting", dev.isConnected ? @"still up after 15 s" : @"down");
    sReconnectPagesLeft = kReconnectPages - 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kReconnectDelay), dispatch_get_main_queue(), ^{
        [dev openConnection:HBAVDTPSession.class];
    });
}

@implementation HBAVDTPSession {
    IOBluetoothDevice *_dev;                    // nil for the test init
    HBTransportHelperClient *_helper;
    void (^_transportProvider)(void (^)(int fd));
    void (^_signalingOpener)(void (^)(HBL2CAPChannel *ch, NSInteger code));   // openPSM stand-in (test init)
    HBL2CAPChannel *_sig;
    uint8_t _label;
    uint8_t _sfBit;
    NSMutableArray<HBAVDTPEndpoint *> *_sinks;  // free sink endpoints still to query
    uint8_t _acp;                               // the sink's LDAC seid
    HBAVDTPSignal _pending;                     // command we wait a response for; 0 = none
    uint8_t _pendingLabel;
    NSUInteger _txToken;                        // bumped per response/timeout: stale transaction deadlines bail out
    int _openAttempts;                          // signaling open attempts made so far
    NSUInteger _attemptToken;                   // bumped when an attempt ends: stale callbacks/deadlines bail out
    NSUInteger _pagingToken;                    // attempt waiting for the baseband connection; 0 = none
    NSUInteger _epoch;                          // bumped on stop/failure: stale timers and callbacks bail out
    BOOL _stopping;
    BOOL _tookOver;                             // we dropped macOS's link: failure must give A2DP back too
    BOOL _restored;                             // restoreHook runs at most once
}

- (instancetype)initWithDevice:(IOBluetoothDevice *)dev helper:(HBTransportHelperClient *)helper {
    if (!(self = [super init])) return nil;
    _dev = dev;
    _helper = helper;
    _transportFD = -1;
    _transactionTimeout = 5.0;
    _signalingOpenTimeout = 3.0;
    _openRetryInterval = 1.0;
    _maxOpenAttempts = 10;
    NSString *addr = dev.addressString;
    _transportProvider = ^(void (^done)(int)) {
        [helper openTransportForAddress:addr psm:kAVDTPPSM completion:^(int fd, NSInteger code) {
            if (fd < 0) HBLOG(@"transport helper failed, code %ld", (long)code);
            done(fd);
        }];
    };
    _restoreHook = ^{
        // Dropping and re-paging the link makes bluetoothd set its own A2DP up again. closeConnection blocks,
        // so it runs off the main queue. It can return seconds before the ACL is actually gone (6.5 s seen on the
        // XM4), and openConnection: on a link that is still up is a no-op — so page only once it is down.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [dev closeConnection];
            dispatch_async(dispatch_get_main_queue(), ^{ HBReconnectWhenDown(dev, kLinkDownChecks); });
        });
    };
    return self;
}

- (instancetype)initWithSignalingChannel:(nullable HBL2CAPChannel *)sig transportProvider:(void (^)(void (^)(int)))provider {
    if (!(self = [super init])) return nil;
    _transportFD = -1;
    _transactionTimeout = 5.0;
    _signalingOpenTimeout = 3.0;
    _openRetryInterval = 1.0;
    _maxOpenAttempts = 10;
    _transportProvider = [provider copy];
    [self adoptSignaling:sig];
    return self;
}

- (instancetype)initWithSignalingOpener:(void (^)(void (^)(HBL2CAPChannel *, NSInteger)))opener
                      transportProvider:(void (^)(void (^)(int)))provider {
    if (!(self = [self initWithSignalingChannel:nil transportProvider:provider])) return nil;
    _signalingOpener = [opener copy];
    return self;
}

- (void)log:(NSString *)msg {
    os_log(HBLog(), "%{public}@", msg);
    if (self.logHandler) self.logHandler(msg);
}

- (void)dealloc {
    _sig.delegate = nil;
    [_sig close];
    if (_transportFD >= 0) close(_transportFD);
    [_helper terminate];
}

// Target for the restore hook's asynchronous openConnection: (a class object outlives any session).
+ (void)connectionComplete:(IOBluetoothDevice *)dev status:(IOReturn)status {
    HBLOG(@"reconnect for system audio: status 0x%x", status);
    // Right after a stream the XM4 sometimes refuses the first page (status 0xa after ~15 s): page again.
    if (status != kIOReturnSuccess && sReconnectPagesLeft > 0) {
        sReconnectPagesLeft--;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kReconnectDelay), dispatch_get_main_queue(), ^{
            [dev openConnection:HBAVDTPSession.class];
        });
    }
}

#pragma mark - State

- (void)setState:(HBSessionState)state error:(NSError *)err {
    [self setState:state error:err then:nil];
}

/// Delegate first, then `after` — so the transport fd stays valid until the callback has returned.
- (void)setState:(HBSessionState)state error:(NSError *)err then:(void (^)(void))after {
    if (_state == state && !err) { if (after) after(); return; }
    _state = state;
    void (^notify)(void) = ^{
        [self.delegate session:self didChangeState:state error:err];
        if (after) after();
    };
    if (NSThread.isMainThread) notify(); else dispatch_async(dispatch_get_main_queue(), notify);
}

/// Stops all activity except the transport fd, which `finishWithState:` closes after notifying.
- (void)shutDown {
    _epoch++;
    _txToken++;
    _pending = 0;
    _sig.delegate = nil;
    [_sig close];
    _sig = nil;
    [_helper terminate];
}

- (void)runRestoreHookOnce {
    if (_restored) return;
    _restored = YES;
    if (self.restoreHook) self.restoreHook();
}

/// Closed or Failed: restore (when asked), tell the delegate, then close the transport fd.
- (void)finishWithState:(HBSessionState)state error:(NSError *)err restore:(BOOL)restore {
    [self shutDown];
    _stopping = NO;
    if (restore) [self runRestoreHookOnce];
    __weak HBAVDTPSession *weakSelf = self;
    [self setState:state error:err then:^{
        HBAVDTPSession *me = weakSelf;
        if (me && me->_transportFD >= 0) close(me->_transportFD);
        if (me) me->_transportFD = -1;
    }];
}

- (void)failWithCode:(HBSessionError)code message:(NSString *)msg {
    if (self.isFinished) return;
    SLOG(@"failed: %@", msg);
    [self finishWithState:HBSessionFailed
                    error:[NSError errorWithDomain:HBErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: msg }]
                  restore:_tookOver];
}

- (BOOL)isFinished { return _state == HBSessionClosed || _state == HBSessionFailed; }

#pragma mark - Signaling

/// Sends a command and arms its deadline (transactionTimeout; 1 s while stopping). NO if the write failed.
- (BOOL)send:(HBAVDTPSignal)sig payload:(NSData *)payload {
    _label = (_label + 1) & 0x0f;
    _pending = sig;
    _pendingLabel = _label;
    if (![_sig write:[HBAVDTP command:sig label:_label payload:payload]]) return NO;
    NSUInteger token = ++_txToken;
    NSTimeInterval timeout = _stopping ? kStopStepTimeout : self.transactionTimeout;
    __weak HBAVDTPSession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HBAVDTPSession *me = weakSelf;
        if (me && me->_txToken == token) [me transactionTimedOut:sig];
    });
    return YES;
}

/// Setup/suspend/resume send: a failed write means the link is gone.
- (void)sendOrFail:(HBAVDTPSignal)sig payload:(NSData *)payload {
    if (![self send:sig payload:payload])
        [self failWithCode:HBErrorSinkDisconnected message:[NSString stringWithFormat:@"cannot send signal %d", sig]];
}

- (void)transactionTimedOut:(HBAVDTPSignal)sig {
    SLOG(@"no answer to signal %d", sig);
    if (_stopping) { [self stopStepDone]; return; }
    [self failWithCode:HBErrorTimeout message:[NSString stringWithFormat:@"sink did not answer signal %d", sig]];
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
    if (_state != HBSessionIdle) { SLOG(@"start ignored in state %ld", (long)_state); return; }
    _sfBit = sfBit;
    NSUInteger epoch = _epoch;
    [self setState:HBSessionConnecting error:nil];
    if (_epoch != epoch) return;                                // the delegate stopped us
    if (_sig) { [self sendOrFail:HBAVDTPDiscover payload:nil]; return; }
    if (!_dev.isConnected) { [self openSignalingAttempt]; return; }
    // The sink holds one AVDTP session and macOS owns it: drop the baseband link and ask for the channel early,
    // after bluetoothd has torn down its A2DP channels but (ideally) before the ACL goes — our channel then keeps
    // the link up. If the ACL drops anyway, the attempt loop pages the device again.
    SLOG(@"taking over: dropping the baseband link");
    _tookOver = YES;
    [_dev closeConnection];
    [self after:kTakeoverDelay do:^(HBAVDTPSession *me) { [me openSignalingAttempt]; }];
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

- (int64_t)nanoseconds:(NSTimeInterval)t { return (int64_t)(t * NSEC_PER_SEC); }

/// One attempt: page the device if its baseband link is down, then open the signaling PSM. Every attempt ends in
/// exactly one of signalingOpened:, or attemptFailed: (open error, open deadline, paging failure/deadline).
- (void)openSignalingAttempt {
    if (self.isFinished) return;
    _openAttempts++;
    NSUInteger token = ++_attemptToken;
    if (_dev && !_dev.isConnected) {
        SLOG(@"signaling attempt %d/%ld: device not connected, paging", _openAttempts, (long)self.maxOpenAttempts);
        _pagingToken = token;
        IOReturn rc = [_dev openConnection:self];
        if (rc != kIOReturnSuccess) SLOG(@"openConnection returned 0x%x", rc);
        [self pollConnectedForAttempt:token deadline:[NSDate dateWithTimeIntervalSinceNow:kConnectTimeout]];
        return;
    }
    SLOG(@"signaling attempt %d/%ld: opening PSM 0x19", _openAttempts, (long)self.maxOpenAttempts);
    [self openPSMForAttempt:token];
}

- (void)pollConnectedForAttempt:(NSUInteger)token deadline:(NSDate *)deadline {
    [self after:[self nanoseconds:kConnectPollInterval] do:^(HBAVDTPSession *me) {
        if (me->_pagingToken != token || me->_attemptToken != token) return;   // connectionComplete got there first
        if (me->_dev.isConnected) {
            me->_pagingToken = 0;
            [me openPSMForAttempt:token];
        } else if (deadline.timeIntervalSinceNow <= 0) {
            me->_pagingToken = 0;
            [me attemptFailed:token reason:@"paging timed out"];
        } else {
            [me pollConnectedForAttempt:token deadline:deadline];
        }
    }];
}

/// IOBluetooth's openConnection: target. Main thread.
- (void)connectionComplete:(IOBluetoothDevice *)dev status:(IOReturn)status {
    SLOG(@"baseband connect: status 0x%x", status);
    NSUInteger token = _pagingToken;
    if (!token || token != _attemptToken || _stopping || self.isFinished) return;
    _pagingToken = 0;
    if (status == kIOReturnSuccess) [self openPSMForAttempt:token];
    else [self attemptFailed:token reason:[NSString stringWithFormat:@"paging failed (0x%x)", status]];
}

- (void)openPSMForAttempt:(NSUInteger)token {
    NSUInteger epoch = _epoch;
    __weak HBAVDTPSession *weakSelf = self;
    void (^done)(HBL2CAPChannel *, NSInteger) = ^(HBL2CAPChannel *ch, NSInteger code) {
        HBAVDTPSession *me = weakSelf;
        if (!me || me->_epoch != epoch || me->_attemptToken != token) {   // stopped, or this attempt timed out
            [ch close];
            return;
        }
        me->_attemptToken++;
        if (ch) [me signalingOpened:ch];
        else [me attemptFailed:0 reason:[NSString stringWithFormat:@"open failed (code %ld)", (long)code]];
    };
    if (_signalingOpener) _signalingOpener(done);
    else [HBL2CAPChannel openPSM:kAVDTPPSM onDevice:_dev completion:done];
    [self after:[self nanoseconds:self.signalingOpenTimeout] do:^(HBAVDTPSession *me) {
        if (me->_attemptToken == token) [me attemptFailed:token reason:@"open did not complete in time"];
    }];
}

/// `token` 0: the caller already ended the attempt.
- (void)attemptFailed:(NSUInteger)token reason:(NSString *)reason {
    if (token) {
        if (_attemptToken != token) return;
        _attemptToken++;
    }
    if (_openAttempts < self.maxOpenAttempts) {
        SLOG(@"signaling attempt %d: %@, retrying in %.1f s", _openAttempts, reason, self.openRetryInterval);
        [self after:[self nanoseconds:self.openRetryInterval] do:^(HBAVDTPSession *me) { [me openSignalingAttempt]; }];
    } else {
        [self failWithCode:HBErrorChannelOpenFailed
                   message:[NSString stringWithFormat:@"signaling channel open failed after %d attempts (%@)",
                                                      _openAttempts, reason]];
    }
}

- (void)signalingOpened:(HBL2CAPChannel *)ch {
    [self adoptSignaling:ch];
    [self sendOrFail:HBAVDTPDiscover payload:nil];
}

- (void)queryNextCapabilities {
    if (_sinks.count == 0) {
        [self failWithCode:HBErrorNoLDAC message:@"no sink endpoint supports LDAC at this rate in stereo"];
        return;
    }
    _acp = _sinks.firstObject.seid;
    [_sinks removeObjectAtIndex:0];
    [self sendOrFail:HBAVDTPGetCapabilities payload:self.acpPayload];
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
    [self sendOrFail:HBAVDTPStart payload:self.acpPayload];
}

#pragma mark - HBL2CAPChannelDelegate

- (void)channel:(HBL2CAPChannel *)c didReceive:(NSData *)msg {
    uint8_t type = 0, label = 0;
    HBAVDTPSignal sig = 0;
    // One socket read is taken as one message (as in the prototype); anything shorter than a header is dropped.
    if (![HBAVDTP parseHeader:msg label:&label messageType:&type signal:&sig]) return;
    if (type == kMsgCommand) { [self handleSinkCommand:msg signal:sig channel:c]; return; }
    if (!_pending || sig != _pending || label != _pendingLabel) {
        // not an answer to our open transaction: e.g. bluetoothd's own A2DP retries (~every 10 s) land here
        SLOG(@"ignoring response type %d to signal %d label %d", type, sig, label);
        return;
    }
    if (_stopping) { [self stopStepDone]; return; }   // accept or reject: either way the step is over
    _pending = 0;
    _txToken++;                                   // the deadline no longer applies
    if (type != kMsgAccept) {
        uint8_t errCode = msg.length > 2 ? ((const uint8_t *)msg.bytes)[msg.length - 1] : 0;
        if (_state == HBSessionConnecting || _state == HBSessionConfigured) {
            [self failWithCode:HBErrorSinkRejected
                       message:[NSString stringWithFormat:@"sink rejected signal %d (error 0x%02x)", sig, errCode]];
        } else {
            SLOG(@"sink refused signal %d (error 0x%02x), state unchanged", sig, errCode);
        }
        return;
    }
    [self handleAccept:sig message:msg];
}

- (void)handleSinkCommand:(NSData *)msg signal:(HBAVDTPSignal)sig channel:(HBL2CAPChannel *)c {
    [c write:[HBAVDTP acceptResponseForCommand:msg]];
    if (_stopping || self.isFinished) return;
    switch (sig) {
    case HBAVDTPSuspend:
        if (_state == HBSessionStreaming) [self setState:HBSessionSuspended error:nil];
        break;
    case HBAVDTPStart:
        if (_state == HBSessionSuspended) [self setState:HBSessionStreaming error:nil];
        break;
    case HBAVDTPClose:
    case HBAVDTPAbort:
        [self failWithCode:HBErrorSinkDisconnected
                   message:[NSString stringWithFormat:@"sink sent %@", sig == HBAVDTPClose ? @"CLOSE" : @"ABORT"]];
        break;
    default:                                      // e.g. Delay Report: acknowledged only
        break;
    }
}

- (BOOL)endpointFits:(HBAVDTPEndpoint *)ep {
    return ep.supportsLDAC && (ep.ldacSampleRates & _sfBit) && (ep.ldacChannelModes & kLDACChannelModeStereo);
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
        if (ep.supportsLDAC)
            SLOG(@"LDAC endpoint seid=%d rates=0x%02x modes=0x%02x", _acp, ep.ldacSampleRates, ep.ldacChannelModes);
        if (![self endpointFits:ep]) { [self queryNextCapabilities]; break; }
        [self sendOrFail:HBAVDTPSetConfiguration
                 payload:[HBAVDTP setConfigurationPayloadForSEID:_acp intSEID:kIntSEID ldacSampleRateBit:_sfBit
                                                  channelModeBit:kLDACChannelModeStereo]];
        break;
    }
    case HBAVDTPSetConfiguration: {
        _negotiatedSampleRateBit = _sfBit;
        NSUInteger epoch = _epoch;
        [self setState:HBSessionConfigured error:nil];
        if (_epoch != epoch) break;               // the delegate stopped us
        [self sendOrFail:HBAVDTPOpen payload:self.acpPayload];
        break;
    }
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
    [self failWithCode:HBErrorSinkDisconnected message:@"signaling channel closed"];
}

#pragma mark - Suspend / resume

- (void)suspend {
    if (_state != HBSessionStreaming || _stopping || _pending) return;
    [self sendOrFail:HBAVDTPSuspend payload:self.acpPayload];
}

- (void)resume {
    if (_state != HBSessionSuspended || _stopping || _pending) return;
    [self sendOrFail:HBAVDTPStart payload:self.acpPayload];
}

#pragma mark - Stop

- (void)stopAndRestoreSystemAudio {
    if (_stopping || _state == HBSessionIdle || _state == HBSessionClosed) return;
    BOOL streamOpen = _state == HBSessionStreaming || _state == HBSessionSuspended || _state == HBSessionConfigured;
    BOOL wasStreaming = _state == HBSessionStreaming;
    _stopping = YES;
    _epoch++;                                     // cancels pending retries and transport callbacks
    _txToken++;
    _pending = 0;
    if (!_sig || !streamOpen) [self finishStop];
    else [self stopStep:wasStreaming ? HBAVDTPSuspend : HBAVDTPClose];
}

/// Sends SUSPEND or CLOSE; the answer, its 1 s deadline or a failed write all lead to stopStepDone.
- (void)stopStep:(HBAVDTPSignal)sig {
    if (!_sig || ![self send:sig payload:self.acpPayload]) { _pending = sig; [self stopStepDone]; }
}

- (void)stopStepDone {
    HBAVDTPSignal done = _pending;
    _pending = 0;
    _txToken++;
    if (done == HBAVDTPSuspend) [self stopStep:HBAVDTPClose];
    else [self finishStop];
}

- (void)finishStop {
    [self finishWithState:HBSessionClosed error:nil restore:YES];
}

@end
