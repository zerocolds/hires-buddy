# HiRes Buddy

LDAC (and, planned, aptX HD) Bluetooth audio output for macOS.

macOS only sends audio to Bluetooth headphones as SBC or AAC. This project streams any app's audio
to LDAC headphones from a menu bar app — a thing macOS itself can't do.

**Status: working prototype.** A command-line player (`player/ldacplay`) streams a WAV/FLAC file to
Sony WH-1000XM4 over LDAC at 44.1–96 kHz, 330/660/990 kbps, on macOS 15.7 / Apple Silicon.
The goal — a menu bar app with a virtual audio device, a quality switch and stream stats — is
described in [`docs/superpowers/specs/2026-10-16-hires-buddy-design.md`](docs/superpowers/specs/2026-10-16-hires-buddy-design.md).

## Try the prototype

```sh
cd player
L=../third_party/libldac
clang -O2 -fobjc-arc -I$L/inc -I$L/src ldacplay.m $L/src/ldaclib.c $L/src/ldacBT.c \
  -framework Foundation -framework IOBluetooth -framework CoreBluetooth \
  -Wl,-sectcreate,__TEXT,__info_plist,../spike/Info.plist -o ldacplay

# headphone address: System Information → Bluetooth
LDAC_ADDR=94-db-56-e1-43-75 LDAC_Q=sq ./play.sh "/path/to/track.flac"
```

`LDAC_Q` is `hq` (990/909 kbps), `sq` (660/606) or `mq` (330/303). Headphones must be paired and
connected. If macOS currently owns the A2DP link (you hear AAC), the player drops the baseband link
and reconnects first; the headphones briefly disconnect, then the stream starts. Anything playing on
the Mac will fall back to the speakers during the takeover — pause it first.

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

- `player/` — the prototype streamer (`ldacplay.m`, `play.sh`) and two throwaway probes used to find
  the CoreBluetooth path (`l2test.m`, `cbtest.m`).
- `spike/` — the first Swift probes (AVDTP capability dump, connect/disconnect helpers).
- `third_party/libldac/` — Sony's LDAC encoder from AOSP, Apache 2.0, vendored unchanged.
- `docs/superpowers/specs/` — design.

## License

GPL-3.0 (see `LICENSE`). The planned virtual audio device is a fork of
[BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0); `third_party/libldac` is
Apache-2.0 and keeps its own `LICENSE`/`NOTICE`.

This project uses private CoreBluetooth API and may break with any macOS update.
