// BTStream — AVDTP signaling codec and L2CAP channels opened straight through CoreBluetooth's classic peer.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, HBAVDTPSignal) {
    HBAVDTPDiscover = 1,
    HBAVDTPGetCapabilities = 2,
    HBAVDTPSetConfiguration = 3,
    HBAVDTPOpen = 6,
    HBAVDTPStart = 7,
    HBAVDTPClose = 8,
    HBAVDTPSuspend = 9,
    HBAVDTPAbort = 10,
};

@interface HBAVDTPEndpoint : NSObject
@property uint8_t seid;
@property BOOL inUse;
@property BOOL isSink;
// filled by +[HBAVDTP parseCapabilities:into:]
@property BOOL supportsLDAC;
@property uint8_t ldacSampleRates;
@property uint8_t ldacChannelModes;
@end

/// Byte-level AVDTP single-packet framing; no Bluetooth dependency.
@interface HBAVDTP : NSObject
/// [label<<4 | command, signal, payload...]
+ (NSData *)command:(HBAVDTPSignal)sig label:(uint8_t)label payload:(nullable NSData *)payload;
/// [hdr&0xf0 | accept, signal] for a command received from the sink.
+ (NSData *)acceptResponseForCommand:(NSData *)cmd;
/// messageType: 0 command, 2 accept, 3 reject. NO if the message is shorter than two bytes.
+ (BOOL)parseHeader:(NSData *)msg label:(nullable uint8_t *)label messageType:(nullable uint8_t *)type signal:(nullable HBAVDTPSignal *)sig;
/// All endpoints listed in a DISCOVER response (in use or not, any role).
+ (NSArray<HBAVDTPEndpoint *> *)parseDiscover:(NSData *)rsp;
/// Looks for media codec category 7 with vendor 0x0000012D (Sony) codec 0x00AA (LDAC).
+ (void)parseCapabilities:(NSData *)rsp into:(HBAVDTPEndpoint *)ep;
/// SET_CONFIGURATION payload: media transport + LDAC codec with one sample-rate bit and one channel-mode bit.
+ (NSData *)setConfigurationPayloadForSEID:(uint8_t)acp intSEID:(uint8_t)intSeid ldacSampleRateBit:(uint8_t)sfBit channelModeBit:(uint8_t)cmBit;
@end

@class HBL2CAPChannel;

@protocol HBL2CAPChannelDelegate <NSObject>
/// `data` is whatever one socket read returned (up to 2048 bytes) — not guaranteed to be exactly one AVDTP message.
- (void)channel:(HBL2CAPChannel *)c didReceive:(NSData *)data;
- (void)channelDidClose:(HBL2CAPChannel *)c;
@end

/// One L2CAP channel backed by a SOCK_STREAM socket; delegate callbacks arrive on the main run loop.
@interface HBL2CAPChannel : NSObject
/// Opens a PSM on an already-connected device through CBClassicPeer (see HBPrivateAPI.h). Completion on the main queue.
/// Only one open may be pending per device at a time: the peer has a single connect callback, and a second
/// call overwrites the first one's completion. The channel keeps the peer alive until `close`.
+ (void)openPSM:(uint16_t)psm onDevice:(IOBluetoothDevice *)dev completion:(void (^)(HBL2CAPChannel * _Nullable ch, NSInteger code))completion;
/// Wraps a ready socket (fd handed over by the helper process). `close` closes the fd. nil if streams cannot be created.
- (nullable instancetype)initWithSocketFD:(int)fd name:(NSString *)name;
- (instancetype)init NS_UNAVAILABLE;
@property(weak, nullable) id<HBL2CAPChannelDelegate> delegate;
/// -1 after `close`.
@property(readonly) int socketFD;
/// 0 when unknown (bare fd).
@property(readonly) uint16_t outgoingMTU;
@property(readonly, copy) NSString *name;
/// One write() = one SDU; NO on a short write or error (logged with errno). Never raises SIGPIPE.
- (BOOL)write:(NSData *)data;
- (void)close;
@end

/// Opens the AVDTP transport channel in a separate helper process (bluetoothd allows one channel per PSM per
/// client session) and receives its socket over a unix socket with SCM_RIGHTS.
/// Wire format on the unix socket, one message: [status: 1 = ok, 0 = fail][int32 code, host order], plus the fd as
/// SCM_RIGHTS when ok. Helper stdin: "OPEN <addr> <psm>\n"; it lives until stdin reaches EOF.
@interface HBTransportHelperClient : NSObject
/// Default helper: `hiresbuddy-transport` next to the main bundle's executable.
- (instancetype)init;
- (instancetype)initWithHelperURL:(NSURL *)helper NS_DESIGNATED_INITIALIZER;
/// Completion on the main queue: fd >= 0 and code 0 on success; fd -1 and the helper's code on failure
/// (-1 when the helper died, timed out after 15 s, was terminated, or could not be started).
- (void)openTransportForAddress:(NSString *)addr psm:(uint16_t)psm completion:(void (^)(int fd, NSInteger code))completion;
/// Kills the helper (closing its channel) and removes the socket path. Safe to call repeatedly.
- (void)terminate;
@end

extern NSErrorDomain const HBErrorDomain;
/// Named HBSessionError (not HBError) so it does not clash with a Swift-side HBError in HiResBuddyCore.
typedef NS_ERROR_ENUM(HBErrorDomain, HBSessionError) {
    HBErrorSinkRejected = 1,        // sink answered a setup command with a reject
    HBErrorNoLDAC = 2,              // no free sink endpoint offers LDAC at the requested rate in stereo
    HBErrorSinkDisconnected = 3,    // signaling channel closed or unwritable, or the sink sent CLOSE/ABORT
    HBErrorChannelOpenFailed = 4,   // signaling channel could not be opened (after retries)
    HBErrorTransportFailed = 5,     // helper could not hand over the transport channel
    HBErrorTimeout = 6,             // sink did not answer a command within transactionTimeout
};

typedef NS_ENUM(NSInteger, HBSessionState) {
    HBSessionIdle,
    HBSessionConnecting,            // takeover, signaling channel, DISCOVER/GET_CAPABILITIES
    HBSessionConfigured,            // SET_CONFIGURATION accepted; OPEN, transport, START in progress
    HBSessionStreaming,
    HBSessionSuspended,
    HBSessionClosed,
    HBSessionFailed,
};

@class HBAVDTPSession;

@protocol HBAVDTPSessionDelegate <NSObject>
/// Main queue. `err` is set only for HBSessionFailed. For Failed/Closed the restore hook (if due) has already run.
- (void)session:(HBAVDTPSession *)s didChangeState:(HBSessionState)state error:(nullable NSError *)err;
@end

/// AVDTP source session for one LDAC stream (a state machine over the prototype's player/ldacplay.m flow).
/// Not thread-safe: call it and receive callbacks on the main queue.
@interface HBAVDTPSession : NSObject
- (instancetype)initWithDevice:(IOBluetoothDevice *)dev helper:(HBTransportHelperClient *)helper;
/// For tests: the signaling channel is already open (no takeover, no device), and `provider` stands in for the
/// helper — it is called after OPEN is accepted and must call its argument (on the main queue) with an fd, or -1.
- (instancetype)initWithSignalingChannel:(HBL2CAPChannel *)sig transportProvider:(void (^)(void (^)(int fd)))provider;
- (instancetype)init NS_UNAVAILABLE;
@property(weak, nullable) id<HBAVDTPSessionDelegate> delegate;
@property(readonly) HBSessionState state;
/// Valid in Streaming/Suspended, -1 otherwise. Owned by the session: on Failed/Closed it stays open until the
/// delegate callback returns and is closed right after — stop writing to it inside that callback.
@property(readonly) int transportFD;
/// 0 when unknown (the helper hands over a bare fd).
@property(readonly) uint16_t transportMTU;
/// The LDAC sample-rate bit accepted by the sink; 0 before SET_CONFIGURATION is accepted.
@property(readonly) uint8_t negotiatedSampleRateBit;
/// Gives A2DP back to macOS; runs at most once, before the Closed/Failed callback: on stopAndRestoreSystemAudio,
/// and on any failure after a takeover. Default (device init): closeConnection (off the main queue), then
/// openConnection 1.5 s later; nil for the test init.
@property(copy, nullable) void (^restoreHook)(void);
/// Deadline for each sink answer during setup/suspend/resume (default 5 s) -> Failed HBErrorTimeout.
@property NSTimeInterval transactionTimeout;
/// Full path to Streaming: takeover if the device is connected (closeConnection, then the signaling channel with
/// up to 8 retries 2 s apart), DISCOVER, GET_CAPABILITIES until a sink offers LDAC at sfBit in
/// stereo, SET_CONFIGURATION, OPEN, transport, START.
/// Only from Idle.
- (void)startWithSampleRateBit:(uint8_t)sfBit;
/// Streaming -> Suspended (SUSPEND) and back (START).
- (void)suspend;
- (void)resume;
/// SUSPEND + CLOSE (each waited for at most 1 s), closes the channels, terminates the helper, runs restoreHook
/// (unless a failure already did), then Closed.
/// No-op when Idle or Closed.
- (void)stopAndRestoreSystemAudio;
@end

NS_ASSUME_NONNULL_END
