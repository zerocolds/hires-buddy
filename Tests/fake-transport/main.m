// Test stand-in for hiresbuddy-transport: no Bluetooth. Reads "OPEN <addr> <psm>", connects to argv[1], sends
// [status][int32 code] (+ an fd of /dev/null via SCM_RIGHTS when ok). FAKE_FAIL=<n> reports failure code n.
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) return 64;
        char line[128];
        if (!fgets(line, sizeof line, stdin)) return 0;
        const char *fail = getenv("FAKE_FAIL");
        int fd = fail ? -1 : open("/dev/null", O_RDONLY);
        int c = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a = { .sun_family = AF_UNIX };
        strlcpy(a.sun_path, argv[1], sizeof a.sun_path);
        if (connect(c, (struct sockaddr *)&a, sizeof a)) return 6;
        uint8_t msg[5] = { fd >= 0 ? 1 : 0 };
        int32_t code = fail ? atoi(fail) : 0;
        memcpy(msg + 1, &code, sizeof code);
        struct iovec iov = { msg, sizeof msg };
        char cm[CMSG_SPACE(sizeof(int))] = {0};
        struct msghdr m = { .msg_iov = &iov, .msg_iovlen = 1 };
        if (fd >= 0) {
            m.msg_control = cm; m.msg_controllen = sizeof cm;
            struct cmsghdr *h = CMSG_FIRSTHDR(&m);
            h->cmsg_level = SOL_SOCKET; h->cmsg_type = SCM_RIGHTS; h->cmsg_len = CMSG_LEN(sizeof(int));
            memcpy(CMSG_DATA(h), &fd, sizeof fd);
        }
        if (sendmsg(c, &m, 0) < 0) return 7;
        close(c);
        if (fd < 0) return 2;
        while (fgets(line, sizeof line, stdin)) {}
        return 0;
    }
}
