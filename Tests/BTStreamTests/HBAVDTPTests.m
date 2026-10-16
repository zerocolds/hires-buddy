#import <XCTest/XCTest.h>
#import "BTStream.h"

// "12 01 04" -> NSData with bytes 0x12 0x01 0x04
static NSData *HEX(NSString *s) {
    NSMutableData *d = [NSMutableData data];
    for (NSString *tok in [s componentsSeparatedByString:@" "]) {
        if (tok.length == 0) continue;
        uint8_t b = (uint8_t)strtoul(tok.UTF8String, NULL, 16);
        [d appendBytes:&b length:1];
    }
    return d;
}

// ObjC test names carry no module prefix; the BTStreamTests_ prefix makes `swift test --filter BTStreamTests` select them.
@interface BTStreamTests_HBAVDTPTests : XCTestCase
@end

@implementation BTStreamTests_HBAVDTPTests

- (void)testParseDiscoverFromXM4 {
    NSArray<HBAVDTPEndpoint *> *eps = [HBAVDTP parseDiscover:HEX(@"12 01 04 08 08 08 0c 08 10 08 14 08 18 08")];
    XCTAssertEqual(eps.count, 6);
    XCTAssertEqual(eps[2].seid, 3);
    XCTAssertTrue(eps[2].isSink);
    XCTAssertFalse(eps[2].inUse);
}

- (void)testParseDiscoverReadsInUseAndSourceFlags {
    // seid 1 in use (0x06), source tsep (0x00); seid 2 free sink
    NSArray<HBAVDTPEndpoint *> *eps = [HBAVDTP parseDiscover:HEX(@"12 01 06 00 08 08")];
    XCTAssertEqual(eps.count, 2);
    XCTAssertEqual(eps[0].seid, 1);
    XCTAssertTrue(eps[0].inUse);
    XCTAssertFalse(eps[0].isSink);
    XCTAssertFalse(eps[1].inUse);
    XCTAssertTrue(eps[1].isSink);
}

- (void)testParseLDACCapabilities {
    HBAVDTPEndpoint *ep = [HBAVDTPEndpoint new];
    [HBAVDTP parseCapabilities:HEX(@"42 02 01 00 07 0a 00 ff 2d 01 00 00 aa 00 3c 07 04 02 02 00") into:ep];
    XCTAssertTrue(ep.supportsLDAC);
    XCTAssertEqual(ep.ldacSampleRates, 0x3c);
    XCTAssertEqual(ep.ldacChannelModes, 0x07);
}

- (void)testParseAACCapabilitiesIsNotLDAC {
    HBAVDTPEndpoint *ep = [HBAVDTPEndpoint new];
    [HBAVDTP parseCapabilities:HEX(@"32 02 01 00 07 08 00 02 c0 01 8c 84 e2 00 04 02 02 00") into:ep];
    XCTAssertFalse(ep.supportsLDAC);
    XCTAssertEqual(ep.ldacSampleRates, 0);
    XCTAssertEqual(ep.ldacChannelModes, 0);
}

- (void)testParseTruncatedCapabilitiesDoesNotCrash {
    HBAVDTPEndpoint *ep = [HBAVDTPEndpoint new];
    [HBAVDTP parseCapabilities:HEX(@"42 02 01 00 07 0a 00 ff 2d 01") into:ep];
    XCTAssertFalse(ep.supportsLDAC);
}

- (void)testSetConfigurationPayloadMatchesPrototype {
    XCTAssertEqualObjects([HBAVDTP setConfigurationPayloadForSEID:3 intSEID:1 ldacSampleRateBit:0x04 channelModeBit:0x01],
                          HEX(@"0c 04 01 00 07 0a 00 ff 2d 01 00 00 aa 00 04 01"));
}

- (void)testCommandAndAcceptFraming {
    XCTAssertEqualObjects([HBAVDTP command:HBAVDTPDiscover label:1 payload:nil], HEX(@"10 01"));
    XCTAssertEqualObjects([HBAVDTP command:HBAVDTPOpen label:2 payload:HEX(@"0c")], HEX(@"20 06 0c"));
    XCTAssertEqualObjects([HBAVDTP acceptResponseForCommand:HEX(@"00 0d")], HEX(@"02 0d"));
}

- (void)testParseHeaderRejectIs0x03 {
    uint8_t label = 0xff, type = 0xff;
    HBAVDTPSignal sig = 0;
    XCTAssertTrue([HBAVDTP parseHeader:HEX(@"73 01 31") label:&label messageType:&type signal:&sig]);
    XCTAssertEqual(label, 7);
    XCTAssertEqual(type, 3);
    XCTAssertEqual(sig, HBAVDTPDiscover);
}

- (void)testParseHeaderRejectsShortMessage {
    uint8_t label, type;
    HBAVDTPSignal sig;
    XCTAssertFalse([HBAVDTP parseHeader:HEX(@"73") label:&label messageType:&type signal:&sig]);
}

@end
