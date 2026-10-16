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
- (void)channel:(HBL2CAPChannel *)c didReceive:(NSData *)data;
- (void)channelDidClose:(HBL2CAPChannel *)c;
@end

/// One L2CAP channel backed by a SOCK_STREAM socket; delegate callbacks arrive on the main run loop.
@interface HBL2CAPChannel : NSObject
/// Opens a PSM on an already-connected device through CBClassicPeer (see HBPrivateAPI.h). Completion on the main queue.
+ (void)openPSM:(uint16_t)psm onDevice:(IOBluetoothDevice *)dev completion:(void (^)(HBL2CAPChannel * _Nullable ch, NSInteger code))completion;
/// Wraps a ready socket (fd handed over by the helper process). `close` closes the fd.
- (instancetype)initWithSocketFD:(int)fd name:(NSString *)name;
- (instancetype)init NS_UNAVAILABLE;
@property(weak, nullable) id<HBL2CAPChannelDelegate> delegate;
@property(readonly) int socketFD;
/// 0 when unknown (bare fd).
@property(readonly) uint16_t outgoingMTU;
@property(readonly, copy) NSString *name;
/// One write() = one SDU; NO on a short write or error.
- (BOOL)write:(NSData *)data;
- (void)close;
@end

NS_ASSUME_NONNULL_END
