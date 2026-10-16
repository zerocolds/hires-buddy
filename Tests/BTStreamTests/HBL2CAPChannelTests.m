#import <XCTest/XCTest.h>
#include <sys/socket.h>
#include <unistd.h>
#import "BTStream.h"

@interface HBChannelRecorder : NSObject <HBL2CAPChannelDelegate>
@property(strong) NSMutableData *received;
@property(strong) XCTestExpectation *dataExpectation;
@property(strong) XCTestExpectation *closeExpectation;
@property BOOL receivedOnMainThread;
@end

@implementation HBChannelRecorder
- (instancetype)init { if ((self = [super init])) _received = [NSMutableData data]; return self; }
- (void)channel:(HBL2CAPChannel *)c didReceive:(NSData *)data {
    self.receivedOnMainThread = NSThread.isMainThread;
    [self.received appendData:data];
    [self.dataExpectation fulfill];
    self.dataExpectation = nil;
}
- (void)channelDidClose:(HBL2CAPChannel *)c { [self.closeExpectation fulfill]; self.closeExpectation = nil; }
@end

@interface BTStreamTests_HBL2CAPChannelTests : XCTestCase
@end

@implementation BTStreamTests_HBL2CAPChannelTests {
    int _peer;
    HBL2CAPChannel *_channel;
    HBChannelRecorder *_recorder;
}

- (void)setUp {
    int sv[2];
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0);
    _peer = sv[1];
    _recorder = [HBChannelRecorder new];
    _channel = [[HBL2CAPChannel alloc] initWithSocketFD:sv[0] name:@"test"];
    _channel.delegate = _recorder;
}

- (void)tearDown {
    [_channel close];
    if (_peer >= 0) close(_peer);
}

- (void)testSocketFDAndUnknownMTU {
    XCTAssertGreaterThanOrEqual(_channel.socketFD, 0);
    XCTAssertEqual(_channel.outgoingMTU, 0);
}

- (void)testReceivesBytesWrittenByPeerOnMainThread {
    _recorder.dataExpectation = [self expectationWithDescription:@"data"];
    const uint8_t msg[] = { 0x12, 0x01, 0x04, 0x08 };
    XCTAssertEqual(write(_peer, msg, sizeof msg), (ssize_t)sizeof msg);
    [self waitForExpectationsWithTimeout:2 handler:nil];
    XCTAssertEqualObjects(_recorder.received, [NSData dataWithBytes:msg length:sizeof msg]);
    XCTAssertTrue(_recorder.receivedOnMainThread);
}

- (void)testWriteSendsOneMessageToPeer {
    NSData *sdu = [NSData dataWithBytes:(uint8_t[]){ 0x10, 0x01 } length:2];
    XCTAssertTrue([_channel write:sdu]);
    uint8_t buf[16];
    ssize_t n = read(_peer, buf, sizeof buf);
    XCTAssertEqualObjects([NSData dataWithBytes:buf length:MAX(n, 0)], sdu);
}

- (void)testPeerCloseNotifiesDelegate {
    _recorder.closeExpectation = [self expectationWithDescription:@"close"];
    close(_peer); _peer = -1;
    [self waitForExpectationsWithTimeout:2 handler:nil];
}

- (void)testWriteAfterCloseFails {
    [_channel close];
    XCTAssertFalse([_channel write:[NSData dataWithBytes:"x" length:1]]);
}

@end
