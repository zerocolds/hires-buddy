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
// SIGINT/SIGTERM are forwarded to the child; the exit status is the child's.
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
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
    responsibility_spawnattrs_setdisclaim(&attr, 1);
    if (posix_spawn(&child, argv[1], NULL, &attr, argv + 1, environ) != 0) { perror("posix_spawn"); return 70; }
    signal(SIGINT, forward);
    signal(SIGTERM, forward);
    int status;
    while (waitpid(child, &status, 0) < 0) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
