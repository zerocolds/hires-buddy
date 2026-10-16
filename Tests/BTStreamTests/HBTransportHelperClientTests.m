#import <XCTest/XCTest.h>
#include <sys/stat.h>
#include <unistd.h>
#import "BTStream.h"

@interface BTStreamTests_HBTransportHelperClientTests : XCTestCase
@end

@implementation BTStreamTests_HBTransportHelperClientTests {
    HBTransportHelperClient *_client;
}

- (NSURL *)fakeURL {
    // SwiftPM puts executables next to the test bundle: .build/<config>/fake-transport
    NSURL *bundle = [NSBundle bundleForClass:self.class].bundleURL;
    return [[bundle URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"fake-transport"];
}

- (void)tearDown {
    [_client terminate];
    unsetenv("FAKE_FAIL");
    [super tearDown];
}

- (void)testReceivesFileDescriptorFromHelper {
    _client = [[HBTransportHelperClient alloc] initWithHelperURL:self.fakeURL];
    XCTestExpectation *e = [self expectationWithDescription:@"fd"];
    [_client openTransportForAddress:@"00-00-00-00-00-00" psm:0x19 completion:^(int fd, NSInteger code) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertGreaterThan(fd, 0);
        XCTAssertEqual(code, 0);
        struct stat st;
        XCTAssertEqual(fstat(fd, &st), 0);
        if (fd >= 0) close(fd);
        [e fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testHelperFailureReportsCode {
    setenv("FAKE_FAIL", "24", 1);
    _client = [[HBTransportHelperClient alloc] initWithHelperURL:self.fakeURL];
    XCTestExpectation *e = [self expectationWithDescription:@"fail"];
    [_client openTransportForAddress:@"00-00-00-00-00-00" psm:0x19 completion:^(int fd, NSInteger code) {
        XCTAssertEqual(fd, -1);
        XCTAssertEqual(code, 24);
        [e fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testMissingHelperReportsFailure {
    _client = [[HBTransportHelperClient alloc] initWithHelperURL:[NSURL fileURLWithPath:@"/nonexistent/helper"]];
    XCTestExpectation *e = [self expectationWithDescription:@"fail"];
    [_client openTransportForAddress:@"00-00-00-00-00-00" psm:0x19 completion:^(int fd, NSInteger code) {
        XCTAssertEqual(fd, -1);
        XCTAssertEqual(code, -1);
        [e fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testTerminateRemovesSocketPath {
    _client = [[HBTransportHelperClient alloc] initWithHelperURL:self.fakeURL];
    XCTestExpectation *e = [self expectationWithDescription:@"fd"];
    [_client openTransportForAddress:@"00-00-00-00-00-00" psm:0x19 completion:^(int fd, NSInteger code) {
        if (fd >= 0) close(fd);
        [e fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    NSString *path = [NSString stringWithFormat:@"/tmp/hiresbuddy-%d.sock", getpid()];
    [_client terminate];
    XCTAssertNotEqual(access(path.fileSystemRepresentation, F_OK), 0);
}
@end
