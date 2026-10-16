#import "BTStream.h"

static const uint8_t kMsgCommand = 0, kMsgAccept = 2;
static const uint8_t kCatMediaTransport = 1, kCatMediaCodec = 7;
static const uint8_t kCodecVendor = 0xff;
static const uint8_t kLDACCodecInfo[] = { 0x2d, 0x01, 0x00, 0x00, 0xaa, 0x00 };   // vendor 0x0000012D LE32, codec 0x00AA LE16

@implementation HBAVDTPEndpoint
@end

@implementation HBAVDTP

+ (NSData *)command:(HBAVDTPSignal)sig label:(uint8_t)label payload:(NSData *)payload {
    uint8_t hdr[2] = { (uint8_t)(((label & 0x0f) << 4) | kMsgCommand), sig };
    NSMutableData *d = [NSMutableData dataWithBytes:hdr length:2];
    if (payload) [d appendData:payload];
    return d;
}

+ (NSData *)acceptResponseForCommand:(NSData *)cmd {
    const uint8_t *b = cmd.bytes;
    uint8_t rsp[2] = { (uint8_t)((cmd.length > 0 ? b[0] & 0xf0 : 0) | kMsgAccept), cmd.length > 1 ? (uint8_t)(b[1] & 0x3f) : 0 };
    return [NSData dataWithBytes:rsp length:2];
}

+ (BOOL)parseHeader:(NSData *)msg label:(uint8_t *)label messageType:(uint8_t *)type signal:(HBAVDTPSignal *)sig {
    if (msg.length < 2) return NO;
    const uint8_t *b = msg.bytes;
    if (label) *label = b[0] >> 4;
    if (type) *type = b[0] & 0x03;
    if (sig) *sig = b[1] & 0x3f;
    return YES;
}

+ (NSArray<HBAVDTPEndpoint *> *)parseDiscover:(NSData *)rsp {
    NSMutableArray *eps = [NSMutableArray array];
    const uint8_t *b = rsp.bytes;
    for (NSUInteger i = 2; i + 1 < rsp.length; i += 2) {
        HBAVDTPEndpoint *ep = [HBAVDTPEndpoint new];
        ep.seid = b[i] >> 2;
        ep.inUse = (b[i] >> 1) & 1;
        ep.isSink = (b[i + 1] >> 3) & 1;
        [eps addObject:ep];
    }
    return eps;
}

+ (void)parseCapabilities:(NSData *)rsp into:(HBAVDTPEndpoint *)ep {
    const uint8_t *b = rsp.bytes;
    NSUInteger n = rsp.length;
    for (NSUInteger i = 2; i + 1 < n;) {
        uint8_t cat = b[i], len = b[i + 1];
        const uint8_t *v = b + i + 2;
        if (i + 2 + len > n) return;                     // truncated TLV
        // value: [mediaType<<4, codecType, vendor LE32, codec LE16, sampleRates, channelModes]
        if (cat == kCatMediaCodec && len >= 2 + sizeof kLDACCodecInfo + 2 && v[1] == kCodecVendor &&
            !memcmp(v + 2, kLDACCodecInfo, sizeof kLDACCodecInfo)) {
            ep.supportsLDAC = YES;
            ep.ldacSampleRates = v[2 + sizeof kLDACCodecInfo];
            ep.ldacChannelModes = v[3 + sizeof kLDACCodecInfo];
            return;
        }
        i += 2 + len;
    }
}

+ (NSData *)setConfigurationPayloadForSEID:(uint8_t)acp intSEID:(uint8_t)intSeid ldacSampleRateBit:(uint8_t)sfBit channelModeBit:(uint8_t)cmBit {
    NSMutableData *d = [NSMutableData data];
    uint8_t head[] = { (uint8_t)(acp << 2), (uint8_t)(intSeid << 2),
                       kCatMediaTransport, 0x00,
                       kCatMediaCodec, 2 + sizeof kLDACCodecInfo + 2, 0x00 /* audio */, kCodecVendor };
    [d appendBytes:head length:sizeof head];
    [d appendBytes:kLDACCodecInfo length:sizeof kLDACCodecInfo];
    uint8_t tail[] = { sfBit, cmBit };
    [d appendBytes:tail length:sizeof tail];
    return d;
}

@end
