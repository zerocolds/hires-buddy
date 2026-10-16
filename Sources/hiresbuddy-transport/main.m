// hiresbuddy-transport: opens the AVDTP transport L2CAP channel in its own bluetoothd client session and hands the
// socket to the parent over a unix socket (argv[1]). See HBTransportHelperClient for the wire format.
// stdin: "OPEN <addr> <psm>\n" (psm decimal or 0x-hex). Exits 0 when stdin reaches EOF, 2 if the open failed.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#import "BTStream.h"

static HBL2CAPChannel *gChannel;   // keeps the channel (and its peer) alive for the helper's whole life

static void sendResult(const char *sockPath, int fd, int32_t code) {
    int c = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    strlcpy(a.sun_path, sockPath, sizeof a.sun_path);
    if (c < 0 || connect(c, (struct sockaddr *)&a, sizeof a)) { perror("connect"); exit(6); }
    uint8_t msg[5] = { fd >= 0 ? 1 : 0 };
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
    if (sendmsg(c, &m, 0) < 0) perror("sendmsg");
    close(c);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: hiresbuddy-transport <unix-socket-path>\n"); return 64; }
        const char *sockPath = argv[1];
        (void)IOBluetoothDevice.pairedDevices;   // warms up the IOBluetooth/CoreBluetooth bridge
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            char line[128];
            if (!fgets(line, sizeof line, stdin)) exit(0);
            char addr[64]; char psmText[16];
            if (sscanf(line, "OPEN %63s %15s", addr, psmText) != 2) {
                NSLog(@"[helper] bad command: %s", line);
                sendResult(sockPath, -1, -2);
                exit(2);
            }
            uint16_t psm = (uint16_t)strtoul(psmText, NULL, 0);   // base 0: decimal or 0x-hex
            NSString *address = @(addr);
            dispatch_async(dispatch_get_main_queue(), ^{
                IOBluetoothDevice *dev = [IOBluetoothDevice deviceWithAddressString:address];
                if (!dev) { NSLog(@"[helper] no device %@", address); sendResult(sockPath, -1, -3); exit(2); }
                [HBL2CAPChannel openPSM:psm onDevice:dev completion:^(HBL2CAPChannel *ch, NSInteger code) {
                    if (!ch) {
                        NSLog(@"[helper] open PSM 0x%x failed, code %ld", psm, (long)code);
                        sendResult(sockPath, -1, (int32_t)code);
                        exit(2);
                    }
                    gChannel = ch;
                    sendResult(sockPath, ch.socketFD, 0);
                    NSLog(@"[helper] PSM 0x%x open, fd %d handed over", psm, ch.socketFD);
                }];
            });
            while (fgets(line, sizeof line, stdin)) {}
            exit(0);   // parent went away
        });
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
