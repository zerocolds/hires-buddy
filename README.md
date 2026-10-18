# HiRes Buddy

LDAC (and, planned, aptX HD) Bluetooth audio output for macOS.

macOS only sends audio to Bluetooth headphones as SBC or AAC. This project streams any app's audio
to LDAC headphones from a menu bar app — a thing macOS itself can't do.

**Status: stage 1 done — menu bar app.** `HiRes Buddy.app` lives in the menu bar: a "Hi-Res (LDAC)"
toggle sends everything the Mac plays to the selected headphones over LDAC 48 kHz, quality
990/660/330 kbps switches on the fly, the panel shows the stream stats (bitrate, packets, drops,
uptime, buffer). Switching off (or quitting) hands the headphones back to macOS (AAC/SBC) and puts the
previous output back. Tested on Sony WH-1000XM4, macOS 15 / Apple Silicon. Design:
[`docs/superpowers/specs/2026-10-16-hires-buddy-design.md`](docs/superpowers/specs/2026-10-16-hires-buddy-design.md).

## Build and run

Requires Xcode (Swift 6.1) and the BlackHole submodule (`git submodule update --init`).

```sh
driver/build.sh                 # the "HiRes Buddy" virtual audio device → driver/build/HiResBuddy.driver
scripts/bundle.sh               # swift build -c release → build/HiResBuddy.app (helper + driver inside)
open build/HiResBuddy.app
```

The driver can be installed from the app ("Установить драйвер…", asks for the administrator
password) or by hand: `sudo driver/install.sh` (root cannot read `~/Downloads`/`~/Desktop`/`~/Documents`
— if the checkout is there, copy `driver/install.sh` and `driver/build/` to `/tmp` first).
`driver/uninstall.sh` removes it.

First launch asks for Bluetooth access; the first switch-on asks for Microphone access — the app
reads system audio from the virtual device's input, which macOS counts as microphone use (without it
the stream is silence). Logs: `log show --predicate 'subsystem == "HiResBuddy"' --last 10m`.

Using it: pair and connect the headphones in macOS, open the panel, pick them, flip the toggle. The
headphones disconnect and reconnect once (the takeover), then the default output is "HiRes Buddy"
and any app plays through LDAC; the Mac's volume keys keep working.

If the sink rejects the setup, the session renegotiates by itself. After switching off, the headphones
take a few seconds to come back to macOS; the panel shows "Возвращаю наушники системе…" meanwhile, and
Quit waits for it (pressing «Выход» again quits at once). If the headphones go away by themselves
(switched off, out of range), the panel says «Наушники отключились», the output goes back at once and
nothing tries to page them.

## Known issues

- **About 0.5 s of added latency.** The streamer pre-rolls 0.5 s of audio before the first packet
  (0.25 s is sent at once as the headphones' cushion, 0.25 s stays queued to absorb jitter). Fine for
  music, noticeable for video and games.
- **Any SCO on the headphones kills the stream.** A call, Siri, or any app opening the headphones'
  microphone switches them to the hands-free profile; A2DP (and with it the LDAC stream) ends.
- **Radio stutter at 990 kbps.** HQ needs a clean 2.4 GHz channel and short range; with Wi-Fi traffic or
  a body in the way, 660 kbps (the default) is the stable choice.
- **One glitch 10–20 s into a stream.** `bluetoothd` retries its own A2DP connection and the headphones
  reject it; there may be one short dropout when that happens.
- **Microphone permission is asked again after each rebuild.** The bundle is ad-hoc signed, so TCC sees
  a new code hash (cdhash) every build; grant it again (or reset with `tccutil reset Microphone`).
- **No driver uninstall in the app.** Use `sudo driver/uninstall.sh`.
- **Recovery after a crash.** If the app dies mid-stream, the default output stays "HiRes Buddy"
  (silence) and the headphones stay away from macOS. Relaunch the app: it puts the previous output back
  (it is remembered in the app's defaults). If A2DP does not come back to the headphones, power-cycle
  them (or disconnect/reconnect them in the Bluetooth menu).

- **LDAC support is learned, not probed.** The app never queries headphones it is not streaming to; the
  list shows «LDAC не проверено» until the first stream. A stream that negotiates LDAC remembers the
  headphones' LDAC rates; one that finds no LDAC endpoint says «Наушники не поддерживают LDAC» and the
  toggle stays off for them from then on.

`hiresbuddy-cli` (`swift run hiresbuddy-cli probe | play <wav> | system`) is the command-line
equivalent, used for hardware testing. **Do not run `probe` while macOS is playing to (owns A2DP on) the
headphones:** opening the AVDTP signaling channel next to macOS's own makes the headphones drop the
Bluetooth link about 5 s later, and they do not reconnect by themselves.

## The original prototype

`player/ldacplay` streams a WAV/FLAC file to the headphones over LDAC at 44.1–96 kHz:

```sh
cd player
L=../third_party/libldac
clang -O2 -fobjc-arc -I$L/inc -I$L/src ldacplay.m $L/src/ldaclib.c $L/src/ldacBT.c \
  -framework Foundation -framework IOBluetooth -framework CoreBluetooth \
  -Wl,-sectcreate,__TEXT,__info_plist,../spike/Info.plist -o ldacplay

# headphone address: System Information → Bluetooth
LDAC_ADDR=00-11-22-33-44-55 LDAC_Q=sq ./play.sh "/path/to/track.flac"
```

`LDAC_Q` is `hq` (990/909 kbps), `sq` (660/606) or `mq` (330/303).

## How it works (the non-obvious parts)

- **AVDTP from user space.** The player opens L2CAP PSM 0x19 to the headphones, does
  DISCOVER / GET_CAPABILITIES / SET_CONFIGURATION (Sony vendor codec `0x012D:0x00AA`) / OPEN /
  START, and writes RTP packets with `libldac` frames. `bluetoothd` neither blocks nor helps.
- **The public `IOBluetoothL2CAPChannel` is broken for this.** On an already-connected device it
  opens the channel and immediately closes it (`CBClassicPeer` keeps channels in a weak hash table
  and has no connect callback set, so the `CBL2CAPChannel` is deallocated on arrival). The working
  path is the private CoreBluetooth API: `[[device classicPeer] setConnectL2CAPCallback:]` then
  `[peer openL2CAPChannel:0x19]`. The resulting `CBL2CAPChannel` exposes a `SOCK_STREAM` socket;
  one `write()` per L2CAP SDU is what the sink expects.
- **One channel per PSM per process.** `bluetoothd` refuses a second channel on the same PSM from the
  same XPC session, so the AVDTP transport channel is opened by a helper process and handed over
  with `SCM_RIGHTS`.
- **Taking A2DP from macOS.** Drop the baseband link, then request the L2CAP channel while the link
  is down: `bluetoothd` brings the ACL up and sends our connect request before its own A2DP logic
  runs. It retries its A2DP every ~10 s; the sink rejects it, and the stray reject on our signaling
  channel is ignored.

Tested only on WH-1000XM4. Other LDAC headphones should negotiate the same way — reports welcome.

## Layout

- `Sources/HiResBuddy/` — the menu bar app (SwiftUI `MenuBarExtra`); `Sources/HiResBuddyCore/` — session
  controller, streamer, capture, device switching, headphone discovery; `Sources/BTStream/` — AVDTP
  session and L2CAP (Objective-C); `Sources/hiresbuddy-transport/` — the transport-channel helper;
  `Sources/LDACEncoder/` — Swift wrapper over libldac; `Sources/hiresbuddy-cli/` — the CLI.
- `driver/` — the "HiRes Buddy" virtual audio device (BlackHole fork) build/install scripts.
- `scripts/bundle.sh` — assembles `build/HiResBuddy.app`.
- `player/`, `spike/` — the original prototype and probes.
- `third_party/libldac/` — Sony's LDAC encoder from AOSP, Apache 2.0, vendored unchanged.
- `docs/superpowers/specs/` — design.

## License

GPL-3.0 (see `LICENSE`). The virtual audio device is a fork of
[BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0); `third_party/libldac` is
Apache-2.0 and keeps its own `LICENSE`/`NOTICE`.

This project uses private CoreBluetooth API and may break with any macOS update.
