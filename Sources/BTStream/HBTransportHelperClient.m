#import "BTStream.h"
#include <poll.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static const int kAcceptTimeoutMs = 15000;

@implementation HBTransportHelperClient {
    NSURL *_helperURL;
    NSTask *_task;
    NSString *_sockPath;
    _Atomic(BOOL) _cancelled;
}

- (instancetype)init {
    NSURL *dir = [NSBundle.mainBundle.executableURL URLByDeletingLastPathComponent];
    return [self initWithHelperURL:[dir URLByAppendingPathComponent:@"hiresbuddy-transport"]];
}

- (instancetype)initWithHelperURL:(NSURL *)helper {
    if ((self = [super init])) _helperURL = helper;
    return self;
}

- (void)finish:(void (^)(int, NSInteger))completion fd:(int)fd code:(NSInteger)code {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(fd, code); });
}

- (void)openTransportForAddress:(NSString *)addr psm:(uint16_t)psm completion:(void (^)(int, NSInteger))completion {
    [self terminate];
    atomic_store(&_cancelled, NO);
    // The per-user temporary directory (0700) rather than the world-writable /tmp; the socket itself 0600.
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                 [NSString stringWithFormat:@"hiresbuddy-%d.sock", getpid()]];
    unlink(path.fileSystemRepresentation);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    if (strlcpy(a.sun_path, path.fileSystemRepresentation, sizeof a.sun_path) >= sizeof a.sun_path) {
        NSLog(@"transport helper: socket path too long: %@", path);
        [self finish:completion fd:-1 code:-1];
        return;
    }
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0 || bind(lfd, (struct sockaddr *)&a, sizeof a) || chmod(path.fileSystemRepresentation, 0600) ||
        listen(lfd, 1)) {
        NSLog(@"transport helper: bind %@ failed: %s", path, strerror(errno));
        if (lfd >= 0) close(lfd);
        unlink(path.fileSystemRepresentation);
        [self finish:completion fd:-1 code:-1];
        return;
    }
    _sockPath = path;

    NSTask *t = [NSTask new];
    t.executableURL = _helperURL;
    t.arguments = @[ path ];
    NSPipe *in = [NSPipe pipe];
    t.standardInput = in;
    NSError *err;
    if (![t launchAndReturnError:&err]) {
        NSLog(@"transport helper: spawn failed: %@", err);
        close(lfd);
        [self terminate];
        [self finish:completion fd:-1 code:-1];
        return;
    }
    _task = t;
    NSString *cmd = [NSString stringWithFormat:@"OPEN %@ %u\n", addr, psm];
    NSError *werr;
    if (![in.fileHandleForWriting writeData:[cmd dataUsingEncoding:NSUTF8StringEncoding] error:&werr])
        NSLog(@"transport helper: command write failed: %@", werr);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = -1;
        NSInteger code = -1;
        int waited = 0;
        int ready = 0;
        while (waited < kAcceptTimeoutMs && !atomic_load(&self->_cancelled)) {
            struct pollfd p = { .fd = lfd, .events = POLLIN };
            ready = poll(&p, 1, 100);
            waited += 100;
            if (ready > 0) break;
            if (ready < 0 && errno != EINTR) break;
            if (ready == 0 && !t.isRunning) {                 // helper is gone; one last look for a queued connection
                ready = poll(&p, 1, 0);
                break;
            }
        }
        int c = ready > 0 ? accept(lfd, NULL, NULL) : -1;
        if (c >= 0) {
            uint8_t msg[5];
            struct iovec iov = { msg, sizeof msg };
            char cm[CMSG_SPACE(sizeof(int))];
            struct msghdr m = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cm, .msg_controllen = sizeof cm };
            ssize_t n = recvmsg(c, &m, 0);
            if (n >= 1) {
                int32_t hcode = 0;
                if (n >= 5) memcpy(&hcode, msg + 1, sizeof hcode);
                struct cmsghdr *h = CMSG_FIRSTHDR(&m);
                int got = -1;
                if (h && h->cmsg_level == SOL_SOCKET && h->cmsg_type == SCM_RIGHTS) memcpy(&got, CMSG_DATA(h), sizeof got);
                if (msg[0] == 1 && got >= 0) { fd = got; code = 0; }
                else {
                    if (got >= 0) close(got);
                    code = msg[0] == 1 ? -1 : hcode;
                }
            }
            close(c);
        } else {
            NSLog(@"transport helper: no connection from helper (%s)", atomic_load(&self->_cancelled) ? "cancelled" : "timeout or helper died");
        }
        close(lfd);
        [self finish:completion fd:fd code:code];
    });
}

- (NSString *)socketPath { return _sockPath; }

- (void)terminate {
    atomic_store(&_cancelled, YES);
    NSTask *t = _task;
    _task = nil;
    if (t) {
        if (t.isRunning) [t terminate];
        id in = t.standardInput;
        if ([in isKindOfClass:NSPipe.class]) [[(NSPipe *)in fileHandleForWriting] closeFile];
    }
    if (_sockPath) { unlink(_sockPath.fileSystemRepresentation); _sockPath = nil; }
}

- (void)dealloc { [self terminate]; }
@end
