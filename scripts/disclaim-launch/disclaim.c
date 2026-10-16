// disclaim — runs a command as its own TCC-responsible process.
//
// macOS charges a child's privacy access (microphone, Bluetooth) to the app that started it. When that app is a
// hardened-runtime host without the audio-input entitlement (an IDE, an agent host), capture from the HiRes Buddy
// device silently yields zeros. Spawned through this launcher, hiresbuddy-cli asks for permission itself (its
// embedded Info.plist carries the usage strings).
//
// Build:  clang -O2 -o .build/disclaim scripts/disclaim-launch/disclaim.c
// Use:    .build/disclaim .build/debug/hiresbuddy-cli system --addr xx-xx-xx-xx-xx-xx --quality sq
//
// Ctrl-C reaches the child straight from the terminal (same process group), so the launcher ignores SIGINT
// rather than forwarding it — a forwarded copy would look like a second Ctrl-C and make the CLI skip its
// reconnect wait. SIGTERM is forwarded. The exit status is the child's.
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
// libSystem, private: the spawned process becomes responsible for itself.
int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);

static pid_t child;
static void forward(int sig) { if (child > 0) kill(child, sig); }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: disclaim <path> [args...]\n"); return 64; }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    int rc = responsibility_spawnattrs_setdisclaim(&attr, 1);
    if (rc != 0) { fprintf(stderr, "disclaim: responsibility_spawnattrs_setdisclaim: %s\n", strerror(rc)); return 70; }
    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, forward);
    rc = posix_spawn(&child, argv[1], NULL, &attr, argv + 1, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) { fprintf(stderr, "disclaim: %s: %s\n", argv[1], strerror(rc)); return 70; }
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) { perror("disclaim: waitpid"); return 70; }
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
